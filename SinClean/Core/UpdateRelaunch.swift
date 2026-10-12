import AppKit
import Darwin
import Foundation

enum UpdateRelaunchFailure: String, Error, Sendable {
    case busy, unsupportedTarget, launchFailed, preparationTimedOut, invalidChild
    case childExited, terminationBlocked, evidenceIO
}

struct UpdateRelaunchChild: Codable, Equatable, Sendable {
    let token: String
    let pid: Int32
    let bundlePath: String
    let build: Int
}

struct UpdateRelaunchTicket: Codable, Sendable {
    let token: String
    let parentPID: Int32
    let bundlePath: String
    let build: Int
    let createdAt: TimeInterval
}

struct UpdateRelaunchRequest: Sendable {
    let ticket: UpdateRelaunchTicket
}

/// Injectable OS boundary. The coordinator and the early child gate are shared by production/tests.
@MainActor
protocol UpdateRelaunchHost {
    var now: TimeInterval { get }
    func prepare(build: Int) throws -> UpdateRelaunchRequest
    func launch(_ request: UpdateRelaunchRequest,
                completion: @escaping @MainActor @Sendable (Result<Int32, UpdateRelaunchFailure>) -> Void)
    func ready(_ request: UpdateRelaunchRequest) throws -> UpdateRelaunchChild?
    func isLive(_ child: UpdateRelaunchChild) -> Bool
    func commit(_ request: UpdateRelaunchRequest) throws
    func cancel(_ request: UpdateRelaunchRequest)
    func terminateCurrent()
    func pause() async
}

@MainActor
protocol UpdateRelaunching {
    func run(build: Int) async -> UpdateRelaunchFailure
}

/// Success terminates this process. Every returned result therefore represents failure.
@MainActor
final class UpdateRelaunchCoordinator: UpdateRelaunching {
    private let host: any UpdateRelaunchHost
    private let preparationTimeout: TimeInterval
    private let terminationTimeout: TimeInterval
    private var running = false

    init(host: any UpdateRelaunchHost = SystemUpdateRelaunchHost(),
         preparationTimeout: TimeInterval = 20, terminationTimeout: TimeInterval = 5) {
        self.host = host
        self.preparationTimeout = preparationTimeout
        self.terminationTimeout = terminationTimeout
    }

    func run(build: Int) async -> UpdateRelaunchFailure {
        guard !running else { return .busy }
        running = true
        defer { running = false }
        let request: UpdateRelaunchRequest
        do { request = try host.prepare(build: build) }
        catch let failure as UpdateRelaunchFailure { return failure }
        catch { return .evidenceIO }
        // Cancel removes the in-memory grant authority before closing any pipe handles.
        defer { host.cancel(request) }
        let reply = LaunchReply()
        host.launch(request) { reply.result = $0 }
        let deadline = host.now + preparationTimeout
        do {
            while host.now < deadline && !Task.isCancelled {
                if case .failure(let failure) = reply.result { return failure }
                if case .success(let pid) = reply.result, pid == request.ticket.parentPID {
                    return .invalidChild
                }
                if let child = try host.ready(request) {
                    guard child.token == request.ticket.token,
                          child.pid > 0, child.pid != request.ticket.parentPID,
                          child.bundlePath == request.ticket.bundlePath,
                          child.build == request.ticket.build else { return .invalidChild }
                    if case .success(let pid) = reply.result, pid != child.pid { return .invalidChild }
                    guard host.isLive(child) else { return .childExited }
                    // The child may not finish AppKit launch until the gate opens. Its authenticated
                    // ready message + actual executable identity are the preparation acknowledgement;
                    // a process launch alone is never sufficient.
                    try host.commit(request)
                    guard host.isLive(child) else { return .childExited }
                    host.terminateCurrent()
                    let quitDeadline = host.now + terminationTimeout
                    while host.now < quitDeadline && !Task.isCancelled {
                        if !host.isLive(child) { return .childExited }
                        await host.pause()
                    }
                    // Quit was refused/delayed. Revoke the child; keep this instance usable.
                    return .terminationBlocked
                }
                await host.pause()
            }
            return .preparationTimedOut
        } catch let failure as UpdateRelaunchFailure { return failure }
        catch { return .evidenceIO }
    }

    private final class LaunchReply {
        var result: Result<Int32, UpdateRelaunchFailure>?
    }
}

/// Protocol v2 uses only anonymous pipes. No path-based control records or deletion.
enum UpdateRelaunchGate {
    static let argument = "--sinclean-update-relaunch"
    static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    static func processExecutable(_ pid: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        guard length > 0 else { return nil }
        let data = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return canonical(URL(fileURLWithPath: String(decoding: data, as: UTF8.self)))
    }

    static func configurePipe(_ fd: Int32, writing: Bool) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
              !writing || fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            throw UpdateRelaunchFailure.evidenceIO
        }
    }

    /// Small messages fit within PIPE_BUF: either the entire frame is sent or no grant is sent.
    static func send(_ data: Data, fd: Int32) throws {
        guard data.count <= 512 else { throw UpdateRelaunchFailure.evidenceIO }
        let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard sent == data.count else { throw UpdateRelaunchFailure.evidenceIO }
    }

    /// nil means no data yet; EOF is a rejection, never an implicit grant.
    static func receive(fd: Int32) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 { return Data(bytes.prefix(count)) }
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return nil }
        throw UpdateRelaunchFailure.childExited
    }

    /// Called before SinCleanApp and all its data objects exist. Legacy path arguments fail closed.
    static func enter(arguments: [String] = ProcessInfo.processInfo.arguments,
                      bundle: Bundle = .main) -> Bool {
        guard let index = arguments.firstIndex(of: argument) else { return true }
        guard arguments.filter({ $0 == argument }).count == 1, arguments.count == index + 5,
              arguments[index + 1] == "2", UUID(uuidString: arguments[index + 2]) != nil,
              let parent = Int32(arguments[index + 3]), parent > 1, parent == getppid(),
              let build = Int(arguments[index + 4]),
              build == Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
              bundle.object(forInfoDictionaryKey: "SinCleanRelaunchProtocol") as? Int == 2 else { return false }
        let token = arguments[index + 2]
        // These descriptors belong only to this launch, not to any directory name or PID lookup.
        do {
            try configurePipe(STDIN_FILENO, writing: false)
            try configurePipe(STDOUT_FILENO, writing: true)
            let child = UpdateRelaunchChild(token: token, pid: getpid(),
                                           bundlePath: canonical(bundle.bundleURL), build: build)
            var ready = try JSONEncoder().encode(child)
            ready.append(10)
            try send(ready, fd: STDOUT_FILENO)
            let expected = Data((token + "\n").utf8)
            var received = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let bytes = try receive(fd: STDIN_FILENO) {
                    received.append(bytes)
                    guard received.count <= expected.count, expected.starts(with: received) else { return false }
                    if received == expected {
                        // Only willTerminate can send this frame; still wait for actual parent exit.
                        while ProcessInfo.processInfo.systemUptime < deadline {
                            if kill(parent, 0) != 0 && errno == ESRCH {
                                // Business code must not inherit the protocol output pipe.
                                let null = open("/dev/null", O_RDWR | O_CLOEXEC)
                                guard null >= 0 else { return false }
                                defer { close(null) }
                                return dup2(null, STDIN_FILENO) >= 0 && dup2(null, STDOUT_FILENO) >= 0
                            }
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                        return false
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } catch { return false }
        return false
    }
}

@MainActor
final class SystemUpdateRelaunchHost: NSObject, UpdateRelaunchHost {
    /// Main-actor isolation makes cancel and willTerminate mutually exclusive.
    private final class Session {
        let request: UpdateRelaunchRequest
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        var buffer = Data()
        var launched = false
        var armed = false
        var readyChild: UpdateRelaunchChild?
        init(_ request: UpdateRelaunchRequest) { self.request = request }
        func closeHandles() {
            for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                           output.fileHandleForReading, output.fileHandleForWriting] {
                try? handle.close()
            }
        }
    }

    private var sessions: [String: Session] = [:]
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate(_:)),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func prepare(build: Int) throws -> UpdateRelaunchRequest {
        guard sessions.isEmpty else { throw UpdateRelaunchFailure.busy }
        let bundleURL = Bundle.main.bundleURL
        // Bundle.main can cache the old build; validate the installed metadata on disk.
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Int(info["CFBundleVersion"] as? String ?? "") == build,
              info["SinCleanRelaunchProtocol"] as? Int == 2,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".." else {
            throw UpdateRelaunchFailure.unsupportedTarget
        }
        let ticket = UpdateRelaunchTicket(token: UUID().uuidString, parentPID: getpid(),
            bundlePath: UpdateRelaunchGate.canonical(bundleURL), build: build, createdAt: Date().timeIntervalSince1970)
        let request = UpdateRelaunchRequest(ticket: ticket)
        let session = Session(request)
        do {
            try UpdateRelaunchGate.configurePipe(session.input.fileHandleForWriting.fileDescriptor, writing: true)
            try UpdateRelaunchGate.configurePipe(session.output.fileHandleForReading.fileDescriptor, writing: false)
        } catch { session.closeHandles(); throw error }
        session.process.executableURL = bundleURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        session.process.arguments = [UpdateRelaunchGate.argument, "2", ticket.token, String(getpid()), String(build)]
        session.process.standardInput = session.input
        session.process.standardOutput = session.output
        session.process.standardError = FileHandle.standardError
        sessions[ticket.token] = session
        return request
    }

    func launch(_ request: UpdateRelaunchRequest,
                completion: @escaping @MainActor @Sendable (Result<Int32, UpdateRelaunchFailure>) -> Void) {
        guard let session = sessions[request.ticket.token], !session.launched else {
            completion(.failure(.launchFailed)); return
        }
        session.launched = true
        do {
            // Launch the bundle executable as a new process, with private inherited pipe ends.
            // The child runs AppKit normally only after its early gate succeeds.
            try session.process.run()
            completion(.success(session.process.processIdentifier))
        } catch { completion(.failure(.launchFailed)) }
    }

    func ready(_ request: UpdateRelaunchRequest) throws -> UpdateRelaunchChild? {
        guard let session = sessions[request.ticket.token] else { throw UpdateRelaunchFailure.invalidChild }
        if let child = session.readyChild { return child }
        if let bytes = try UpdateRelaunchGate.receive(fd: session.output.fileHandleForReading.fileDescriptor) {
            session.buffer.append(bytes)
            guard session.buffer.count <= 512 else { throw UpdateRelaunchFailure.invalidChild }
            if session.buffer.last == 10 {
                let child = try JSONDecoder().decode(UpdateRelaunchChild.self, from: session.buffer.dropLast())
                guard child.pid == session.process.processIdentifier else { throw UpdateRelaunchFailure.invalidChild }
                session.readyChild = child
                return child
            }
        }
        return nil
    }

    func isLive(_ child: UpdateRelaunchChild) -> Bool {
        guard let session = sessions[child.token], session.process.isRunning,
              session.process.processIdentifier == child.pid,
              let executable = session.process.executableURL else { return false }
        return UpdateRelaunchGate.processExecutable(child.pid) == UpdateRelaunchGate.canonical(executable)
    }

    func commit(_ request: UpdateRelaunchRequest) throws {
        guard let session = sessions[request.ticket.token], session.readyChild != nil else {
            throw UpdateRelaunchFailure.invalidChild
        }
        // Arming is not a grant. A refused quit or a crash cannot release the child.
        session.armed = true
    }

    @objc private func willTerminate(_ notification: Notification) {
        guard let app = notification.object as? NSApplication, app === NSApp else { return }
        let finishing = sessions.values.filter { $0.armed }
        sessions.removeAll()
        for session in finishing {
            if let child = session.readyChild, session.process.isRunning,
               session.process.processIdentifier == child.pid {
                do {
                    try UpdateRelaunchGate.send(Data((session.request.ticket.token + "\n").utf8),
                                               fd: session.input.fileHandleForWriting.fileDescriptor)
                } catch { NSLog("Sin Clean relaunch exit grant failed; child remains barred.") }
            }
            session.closeHandles()
        }
    }

    func cancel(_ request: UpdateRelaunchRequest) {
        // Revocation happens before fallible handle cleanup. Late launches/notifications cannot grant.
        guard let session = sessions.removeValue(forKey: request.ticket.token) else { return }
        session.armed = false
        session.closeHandles()
    }

    func terminateCurrent() { NSApp.terminate(nil) }
    func pause() async { try? await Task.sleep(for: .milliseconds(50)) }
}
