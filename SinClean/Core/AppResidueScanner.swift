import Darwin
import Foundation

protocol AppResidueScanning: Sendable {
    func scan(for application: InstalledApplication) async -> ResidueScanReport
}

actor AppResidueScanner: AppResidueScanning {
    private static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW

    private let homeDirectory: URL
    private let directoryOpenTimeout: TimeInterval

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        directoryOpenTimeout: TimeInterval = 1
    ) {
        self.homeDirectory = homeDirectory
        self.directoryOpenTimeout = directoryOpenTimeout
    }

    func scan(for application: InstalledApplication) async -> ResidueScanReport {
        let context = ScanContext()
        guard let bundleIdentifier = application.bundleIdentifier,
              Self.isSafeBundleIdentifier(bundleIdentifier) else {
            var observation = ScanObservation(context: context, scope: ScanScope(id: "residue|\(application.id)",
                scanner: .residue, phase: .discover, rootPath: homeDirectory.appending(path: "Library").path,
                applicationID: application.id, bundleIdentifier: application.bundleIdentifier,
                policy: ScanPolicy(recursive: false, matching: "nine exact Bundle Identifier paths")))
            observation.skip(path: application.path,
                reason: application.bundleIdentifier == nil ? .missingBundleIdentifier : .invalidBundleIdentifier,
                message: String(localized: "应用没有可安全使用的 Bundle Identifier，未扫描关联残留。"),
                atRoot: true, projectsToLegacyAccessIssues: true)
            return ResidueScanReport(candidates: [], coverage: [observation.snapshot])
        }
        var candidates: [AppResidueCandidate] = []
        var coverage: [ScanCoverage] = []
        for specification in Self.specifications(homeDirectory: homeDirectory, bundleIdentifier: bundleIdentifier) {
            let url = specification.rootURL.appending(path: specification.relativePath)
            let scopeID = specification.kind.evidenceRule.rawValue
            var observation = ScanObservation(context: context, scope: ScanScope(id: scopeID,
                scanner: .residue, phase: .discover, rootPath: specification.rootURL.path, targetPath: url.path,
                applicationID: application.id, bundleIdentifier: bundleIdentifier,
                policy: ScanPolicy(recursive: false, matching: specification.kind.evidenceRule.rawValue)))
            if Task.isCancelled {
                observation.finish(.cancelled); coverage.append(observation.snapshot); continue
            }
            observation.begin()
            var info = stat()
            let status = url.path.withCString { Darwin.lstat($0, &info) }
            guard status == 0 else {
                observation.recordPOSIX(path: url.path, code: errno, atRoot: true,
                    projectsToLegacyAccessIssues: true)
                coverage.append(observation.snapshot); continue
            }
            let type = info.st_mode & mode_t(S_IFMT)
            guard type != mode_t(S_IFLNK) else {
                observation.skip(path: url.path, reason: .symbolicLink,
                    message: String(localized: "检测到符号链接，已跳过"), atRoot: true,
                    projectsToLegacyAccessIssues: false)
                coverage.append(observation.snapshot); continue
            }
            guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) else {
                observation.skip(path: url.path, reason: .unsupportedType,
                    message: String(localized: "目标不是普通文件或目录"), atRoot: true,
                    projectsToLegacyAccessIssues: false)
                coverage.append(observation.snapshot); continue
            }
            let isDirectory = type == mode_t(S_IFDIR)
            let allocatedBytes: Int64
            if isDirectory {
                var measurement = ScanObservation(context: context, scope: ScanScope(id: "measure|\(scopeID)",
                    scanner: .residue, phase: .measure, rootPath: url.path, targetPath: url.path,
                    applicationID: application.id, bundleIdentifier: bundleIdentifier,
                    policy: ScanPolicy(recursive: true, matching: "sum regular file blocks; no symbolic links",
                        directoryOpenTimeout: directoryOpenTimeout)))
                measurement.begin()
                allocatedBytes = await measureDirectoryTree(at: url, observation: &measurement)
                measurement.finish(Task.isCancelled ? .cancelled : nil)
                coverage.append(measurement.snapshot)
            } else {
                let blockBytes = Int64(info.st_blocks) * 512
                allocatedBytes = max(0, blockBytes > 0 ? blockBytes : Int64(info.st_size))
            }
            candidates.append(AppResidueCandidate(
                id: "\(bundleIdentifier)|\(info.st_dev)|\(info.st_ino)|\(url.path)",
                bundleIdentifier: bundleIdentifier, kind: specification.kind, path: url.path,
                rootPath: specification.rootURL.standardizedFileURL.path,
                allocatedBytes: allocatedBytes, logicalBytes: Int64(info.st_size),
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                deviceID: UInt64(info.st_dev), inode: UInt64(info.st_ino), isDirectory: isDirectory,
                matchReason: String(localized: "路径与 Bundle Identifier 完全一致"),
                evidenceOrigin: CandidateEvidenceOrigin(context: context, scopeID: scopeID,
                    reasonCode: specification.kind.evidenceRule)))
            observation.finish()
            coverage.append(observation.snapshot)
        }
        candidates.sort { $0.allocatedBytes > $1.allocatedBytes }
        return ResidueScanReport(candidates: candidates, coverage: coverage.boundedIssueSamples(20))
    }

    private func measureDirectoryTree(at url: URL, observation: inout ScanObservation) async -> Int64 {
        let openResult = await Self.openDirectory(
            parentDescriptor: AT_FDCWD,
            name: url.path,
            timeout: directoryOpenTimeout
        )
        guard openResult.descriptor >= 0 else {
            observation.recordPOSIX(path: url.path, code: openResult.errorCode, atRoot: true,
                projectsToLegacyAccessIssues: true)
            return 0
        }

        var bytes: Int64 = 0
        await measureDirectory(
            descriptor: openResult.descriptor,
            directoryURL: url,
            bytes: &bytes,
            observation: &observation
        )
        return bytes
    }

    private func measureDirectory(
        descriptor: Int32,
        directoryURL: URL,
        bytes: inout Int64,
        observation: inout ScanObservation
    ) async {
        guard let directory = fdopendir(descriptor) else {
            let errorCode = errno
            Darwin.close(descriptor)
            observation.recordPOSIX(path: directoryURL.path, code: errorCode,
                atRoot: directoryURL.path == observation.scope.rootPath,
                projectsToLegacyAccessIssues: true)
            return
        }
        defer { closedir(directory) }

        let directoryDescriptor = dirfd(directory)
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let code = errno
                if code != 0 {
                    observation.recordPOSIX(path: directoryURL.path, code: code,
                        projectsToLegacyAccessIssues: true)
                }
                break
            }
            if Task.isCancelled { return }
            let name = Self.entryName(entry)
            guard name != ".", name != ".." else { continue }

            var info = stat()
            let status = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                observation.recordPOSIX(path: directoryURL.appendingPathComponent(name).path, code: errno,
                    projectsToLegacyAccessIssues: true)
                continue
            }

            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFREG) {
                let blockBytes = Int64(info.st_blocks) * 512
                bytes += max(0, blockBytes > 0 ? blockBytes : Int64(info.st_size))
            } else if type == mode_t(S_IFDIR) {
                let childOpen = await Self.openDirectory(
                    parentDescriptor: directoryDescriptor,
                    name: name,
                    timeout: directoryOpenTimeout
                )
                guard childOpen.descriptor >= 0 else {
                    observation.recordPOSIX(path: directoryURL.appendingPathComponent(name).path,
                        code: childOpen.errorCode, projectsToLegacyAccessIssues: true)
                    continue
                }
                await measureDirectory(
                    descriptor: childOpen.descriptor,
                    directoryURL: directoryURL.appendingPathComponent(name, isDirectory: true),
                    bytes: &bytes,
                    observation: &observation
                )
            } else {
                observation.skip(path: directoryURL.appendingPathComponent(name).path,
                    reason: type == mode_t(S_IFLNK) ? .symbolicLink : .unsupportedType,
                    message: String(localized: "容量测量仅累计普通文件并下探目录"),
                    projectsToLegacyAccessIssues: false)
            }
        }
    }

    private static func specifications(
        homeDirectory: URL,
        bundleIdentifier: String
    ) -> [ResidueSpecification] {
        let library = homeDirectory.appending(path: "Library", directoryHint: .isDirectory)
        return [
            ResidueSpecification(rootURL: library.appending(path: "Caches", directoryHint: .isDirectory), relativePath: bundleIdentifier, kind: .cache),
            ResidueSpecification(rootURL: library.appending(path: "Logs", directoryHint: .isDirectory), relativePath: bundleIdentifier, kind: .logs),
            ResidueSpecification(rootURL: library.appending(path: "Preferences", directoryHint: .isDirectory), relativePath: "\(bundleIdentifier).plist", kind: .preferences),
            ResidueSpecification(rootURL: library.appending(path: "Saved Application State", directoryHint: .isDirectory), relativePath: "\(bundleIdentifier).savedState", kind: .savedState),
            ResidueSpecification(rootURL: library.appending(path: "Application Support", directoryHint: .isDirectory), relativePath: bundleIdentifier, kind: .applicationSupport),
            ResidueSpecification(rootURL: library.appending(path: "Containers", directoryHint: .isDirectory), relativePath: bundleIdentifier, kind: .container),
            ResidueSpecification(rootURL: library.appending(path: "HTTPStorages", directoryHint: .isDirectory), relativePath: bundleIdentifier, kind: .httpStorage),
            ResidueSpecification(rootURL: library.appending(path: "WebKit", directoryHint: .isDirectory), relativePath: bundleIdentifier, kind: .webKit),
            ResidueSpecification(rootURL: library.appending(path: "Application Scripts", directoryHint: .isDirectory), relativePath: bundleIdentifier, kind: .applicationScripts)
        ]
    }

    private static func isSafeBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains("..") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func openDirectory(
        parentDescriptor: Int32,
        name: String,
        timeout: TimeInterval
    ) async -> ResidueDirectoryOpenResult {
        let retainedParent: Int32
        if parentDescriptor == AT_FDCWD {
            retainedParent = AT_FDCWD
        } else {
            retainedParent = Darwin.dup(parentDescriptor)
            guard retainedParent >= 0 else {
                return ResidueDirectoryOpenResult(descriptor: -1, errorCode: errno)
            }
        }

        return await withCheckedContinuation { continuation in
            let gate = ResidueDirectoryOpenGate(continuation: continuation)
            let timeoutWorkItem = DispatchWorkItem {
                gate.resolve(descriptor: -1, errorCode: ETIMEDOUT)
            }
            gate.setTimeoutWorkItem(timeoutWorkItem)

            DispatchQueue.global(qos: .utility).async {
                let descriptor = name.withCString {
                    Darwin.openat(retainedParent, $0, Self.directoryOpenFlags)
                }
                let errorCode = descriptor >= 0 ? 0 : errno
                if retainedParent != AT_FDCWD { Darwin.close(retainedParent) }
                gate.resolve(descriptor: descriptor, errorCode: errorCode)
            }

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWorkItem
            )
        }
    }
}

private struct ResidueSpecification {
    let rootURL: URL
    let relativePath: String
    let kind: AppResidueKind
}

private struct ResidueDirectoryOpenResult: Sendable {
    let descriptor: Int32
    let errorCode: Int32
}

private final class ResidueDirectoryOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResolved = false
    private var timeoutWorkItem: DispatchWorkItem?
    private let continuation: CheckedContinuation<ResidueDirectoryOpenResult, Never>

    init(continuation: CheckedContinuation<ResidueDirectoryOpenResult, Never>) {
        self.continuation = continuation
    }

    func setTimeoutWorkItem(_ workItem: DispatchWorkItem) {
        lock.lock()
        if hasResolved {
            lock.unlock()
            workItem.cancel()
            return
        }
        timeoutWorkItem = workItem
        lock.unlock()
    }

    func resolve(descriptor: Int32, errorCode: Int32) {
        lock.lock()
        guard !hasResolved else {
            lock.unlock()
            if descriptor >= 0 { Darwin.close(descriptor) }
            return
        }
        hasResolved = true
        let pendingTimeout = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()
        pendingTimeout?.cancel()
        continuation.resume(returning: ResidueDirectoryOpenResult(
            descriptor: descriptor,
            errorCode: errorCode
        ))
    }
}
