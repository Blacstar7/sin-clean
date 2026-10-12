import Darwin
import Foundation

protocol DiskScanning: Sendable {
    func scan(
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> CleanupScanReport
}

actor DiskScanner: DiskScanning {
    private static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW
    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "prefpane", "qlgenerator"
    ]

    private let locations: [ScanLocation]
    private let progressBatchSize: Int
    private let directoryOpenTimeout: TimeInterval
    private var lastProgressReportAt: ContinuousClock.Instant?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        progressBatchSize: Int = 200,
        directoryOpenTimeout: TimeInterval = 1
    ) {
        locations = Self.defaultLocations(homeDirectory: homeDirectory)
        self.progressBatchSize = progressBatchSize
        self.directoryOpenTimeout = directoryOpenTimeout
    }

    init(
        locations: [ScanLocation],
        progressBatchSize: Int = 200,
        directoryOpenTimeout: TimeInterval = 1
    ) {
        self.locations = locations
        self.progressBatchSize = progressBatchSize
        self.directoryOpenTimeout = directoryOpenTimeout
    }

    func scan(
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> CleanupScanReport {
        lastProgressReportAt = nil
        let context = ScanContext()
        let startedAt = context.startedAt
        var results: [CleanupScanResult] = []
        var inspectedFileCount = 0
        var candidateBytes: Int64 = 0

        for (index, location) in locations.enumerated() {
            await progress(
                CleanupScanProgress(
                    currentLocation: location.name,
                    completedLocations: index,
                    totalLocations: locations.count,
                    inspectedFileCount: inspectedFileCount,
                    candidateBytes: candidateBytes
                )
            )

            let outcome = try await scanLocation(
                location,
                context: context,
                initialInspectedCount: inspectedFileCount,
                initialCandidateBytes: candidateBytes,
                completedLocations: index,
                totalLocations: locations.count,
                progress: progress
            )

            inspectedFileCount += outcome.inspectedFileCount
            candidateBytes += outcome.scanResult.totalBytes
            results.append(outcome.scanResult)
        }

        await progress(
            CleanupScanProgress(
                currentLocation: String(localized: "扫描完成"),
                completedLocations: locations.count,
                totalLocations: locations.count,
                inspectedFileCount: inspectedFileCount,
                candidateBytes: candidateBytes
            )
        )

        return CleanupScanReport(
            results: results,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    private func scanLocation(
        _ location: ScanLocation,
        context: ScanContext,
        initialInspectedCount: Int,
        initialCandidateBytes: Int64,
        completedLocations: Int,
        totalLocations: Int,
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> LocationScanOutcome {
        let extensions: [String]
        switch location.matchRule {
        case .allRegularFiles: extensions = []
        case .fileExtensions(let values): extensions = values.sorted()
        }
        let scope = ScanScope(id: location.id, scanner: .disk, phase: .discover,
            rootPath: location.url.path,
            policy: ScanPolicy(recursive: true, acceptedTypes: ["regularFile"], extensions: extensions,
                excludedPackageExtensions: Array(Self.packageExtensions), matching: location.evidenceRule.rawValue,
                directoryOpenTimeout: directoryOpenTimeout))
        var accumulator = ScanAccumulator(observation: ScanObservation(context: context, scope: scope))
        if Task.isCancelled {
            accumulator.observation.finish(.cancelled)
            return LocationScanOutcome(scanResult: makeResult(for: location, accumulator: accumulator), inspectedFileCount: 0)
        }
        accumulator.observation.begin()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // Keep the original fileExists/type predicate; lstat only explains its failure.
            var info = stat()
            if location.url.path.withCString({ Darwin.lstat($0, &info) }) != 0 {
                accumulator.observation.recordPOSIX(path: location.url.path, code: errno, atRoot: true,
                    projectsToLegacyAccessIssues: true)
            } else if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                accumulator.observation.record(path: location.url.path, kind: .readFailure,
                    message: String(localized: "范围入口未通过 fileExists 目录检查；该调用未提供底层错误码"),
                    projectsToLegacyAccessIssues: true)
                accumulator.observation.finish(.inaccessible)
            } else {
                accumulator.observation.skip(path: location.url.path,
                    reason: info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) ? .symbolicLink : .unsupportedType,
                    message: String(localized: "范围入口不是可扫描目录"), atRoot: true,
                    projectsToLegacyAccessIssues: false)
            }
            return LocationScanOutcome(
                scanResult: makeResult(for: location, accumulator: accumulator),
                inspectedFileCount: 0
            )
        }

        let rootOpenResult = await Self.openDirectory(
            parentDescriptor: AT_FDCWD,
            name: location.url.path,
            timeout: directoryOpenTimeout
        )
        let rootDescriptor = rootOpenResult.descriptor

        guard rootDescriptor >= 0 else {
            accumulator.observation.recordPOSIX(path: location.url.path, code: rootOpenResult.errorCode,
                atRoot: true, projectsToLegacyAccessIssues: true)
            return LocationScanOutcome(
                scanResult: makeResult(for: location, accumulator: accumulator),
                inspectedFileCount: 0
            )
        }

        do {
            try await scanDirectory(
                descriptor: rootDescriptor,
                directoryURL: location.url,
                location: location,
                accumulator: &accumulator,
                initialInspectedCount: initialInspectedCount,
                initialCandidateBytes: initialCandidateBytes,
                completedLocations: completedLocations,
                totalLocations: totalLocations,
                progress: progress
            )
        } catch is CancellationError {
            accumulator.observation.finish(.cancelled)
        }
        return LocationScanOutcome(
            scanResult: makeResult(for: location, accumulator: accumulator),
            inspectedFileCount: accumulator.inspectedFileCount
        )
    }

    private func scanDirectory(
        descriptor: Int32,
        directoryURL: URL,
        location: ScanLocation,
        accumulator: inout ScanAccumulator,
        initialInspectedCount: Int,
        initialCandidateBytes: Int64,
        completedLocations: Int,
        totalLocations: Int,
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws {
        guard let directory = fdopendir(descriptor) else {
            let errorCode = errno
            Darwin.close(descriptor)
            accumulator.observation.recordPOSIX(path: directoryURL.path, code: errorCode,
                atRoot: directoryURL.path == accumulator.observation.scope.rootPath,
                projectsToLegacyAccessIssues: true)
            return
        }
        defer { closedir(directory) }

        let directoryDescriptor = dirfd(directory)

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let code = errno
                if code != 0 { accumulator.recordAccessIssue(path: directoryURL.path, errorCode: code) }
                break
            }
            try Task.checkCancellation()

            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }

            guard name != ".", name != ".." else { continue }

            var fileInfo = stat()
            let statResult = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &fileInfo, AT_SYMLINK_NOFOLLOW)
            }

            guard statResult == 0 else {
                accumulator.recordAccessIssue(
                    path: directoryURL.appendingPathComponent(name).path,
                    errorCode: errno
                )
                continue
            }

            let fileType = fileInfo.st_mode & mode_t(S_IFMT)
            let isDirectory = fileType == mode_t(S_IFDIR)
            let childURL = directoryURL.appendingPathComponent(name, isDirectory: isDirectory)

            if isDirectory {
                if Self.packageExtensions.contains(childURL.pathExtension.lowercased()) {
                    accumulator.observation.skip(path: childURL.path, reason: .packageBoundary,
                        message: String(localized: "按固定包目录边界停止下探"), policy: true,
                        projectsToLegacyAccessIssues: false)
                    continue
                }

                let childOpenResult = await Self.openDirectory(
                    parentDescriptor: directoryDescriptor,
                    name: name,
                    timeout: directoryOpenTimeout
                )
                let childDescriptor = childOpenResult.descriptor

                guard childDescriptor >= 0 else {
                    accumulator.recordAccessIssue(
                        path: childURL.path,
                        errorCode: childOpenResult.errorCode
                    )
                    continue
                }

                try await scanDirectory(
                    descriptor: childDescriptor,
                    directoryURL: childURL,
                    location: location,
                    accumulator: &accumulator,
                    initialInspectedCount: initialInspectedCount,
                    initialCandidateBytes: initialCandidateBytes,
                    completedLocations: completedLocations,
                    totalLocations: totalLocations,
                    progress: progress
                )
                continue
            }

            guard fileType == mode_t(S_IFREG) else {
                accumulator.observation.skip(path: childURL.path,
                    reason: fileType == mode_t(S_IFLNK) ? .symbolicLink : .unsupportedType,
                    message: String(localized: "不是普通文件，按现有类型规则跳过"),
                    projectsToLegacyAccessIssues: false)
                continue
            }
            accumulator.inspectedFileCount += 1

            guard location.matchRule.matches(childURL) else {
                await reportProgressIfNeeded(
                    accumulator: accumulator,
                    initialInspectedCount: initialInspectedCount,
                    initialCandidateBytes: initialCandidateBytes,
                    location: location,
                    completedLocations: completedLocations,
                    totalLocations: totalLocations,
                    progress: progress
                )
                continue
            }

            let allocatedByBlocks = Int64(fileInfo.st_blocks) * 512
            let allocatedBytes = max(
                0,
                allocatedByBlocks > 0 ? allocatedByBlocks : Int64(fileInfo.st_size)
            )
            let modifiedAt = Date(timeIntervalSince1970: TimeInterval(fileInfo.st_mtimespec.tv_sec))

            accumulator.candidateFileCount += 1
            accumulator.candidateBytes += allocatedBytes
            accumulator.candidates.append(
                CleanupFileCandidate(
                    id: "\(location.id)|\(fileInfo.st_dev)|\(fileInfo.st_ino)|\(childURL.path)",
                    locationID: location.id,
                    rootPath: location.url.path,
                    path: childURL.path,
                    allocatedBytes: allocatedBytes,
                    logicalBytes: Int64(fileInfo.st_size),
                    modifiedAt: modifiedAt,
                    modifiedSeconds: Int64(fileInfo.st_mtimespec.tv_sec),
                    modifiedNanoseconds: Int64(fileInfo.st_mtimespec.tv_nsec),
                    deviceID: UInt64(fileInfo.st_dev),
                    inode: UInt64(fileInfo.st_ino),
                    risk: location.risk,
                    evidenceOrigin: CandidateEvidenceOrigin(context: accumulator.observation.context,
                        scopeID: accumulator.observation.scope.id, reasonCode: location.evidenceRule)
                )
            )

            await reportProgressIfNeeded(
                accumulator: accumulator,
                initialInspectedCount: initialInspectedCount,
                initialCandidateBytes: initialCandidateBytes,
                location: location,
                completedLocations: completedLocations,
                totalLocations: totalLocations,
                progress: progress
            )
        }
    }

    private func reportProgressIfNeeded(
        accumulator: ScanAccumulator,
        initialInspectedCount: Int,
        initialCandidateBytes: Int64,
        location: ScanLocation,
        completedLocations: Int,
        totalLocations: Int,
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async {
        guard accumulator.inspectedFileCount.isMultiple(of: progressBatchSize) else { return }

        let now = ContinuousClock.now
        if let lastProgressReportAt,
           lastProgressReportAt.duration(to: now) < .milliseconds(100) {
            return
        }
        lastProgressReportAt = now

        await progress(
            CleanupScanProgress(
                currentLocation: location.name,
                completedLocations: completedLocations,
                totalLocations: totalLocations,
                inspectedFileCount: initialInspectedCount + accumulator.inspectedFileCount,
                candidateBytes: initialCandidateBytes + accumulator.candidateBytes
            )
        )
    }

    private func makeResult(
        for location: ScanLocation,
        accumulator: ScanAccumulator
    ) -> CleanupScanResult {
        let candidates = accumulator.candidates.sorted {
            $0.allocatedBytes > $1.allocatedBytes
        }
        var observation = accumulator.observation
        observation.finish()
        return CleanupScanResult(
            id: location.id,
            name: location.name,
            description: location.description,
            sourcePath: location.url.path,
            risk: location.risk,
            totalBytes: accumulator.candidateBytes,
            fileCount: accumulator.candidateFileCount,
            candidates: candidates,
            coverage: [observation.snapshot]
        )
    }

    private static func defaultLocations(homeDirectory: URL) -> [ScanLocation] {
        [
            ScanLocation(
                id: "user-caches",
                name: String(localized: "用户与应用缓存"),
                description: String(localized: "应用可重新生成的缓存文件"),
                url: homeDirectory.appending(path: "Library/Caches", directoryHint: .isDirectory),
                risk: .safe,
                matchRule: .allRegularFiles
            ),
            ScanLocation(
                id: "user-logs",
                name: String(localized: "用户日志"),
                description: String(localized: "应用运行日志与诊断记录"),
                url: homeDirectory.appending(path: "Library/Logs", directoryHint: .isDirectory),
                risk: .safe,
                matchRule: .allRegularFiles
            ),
            ScanLocation(
                id: "crash-reports",
                name: String(localized: "崩溃报告"),
                description: String(localized: "系统为当前用户保存的应用崩溃记录"),
                url: homeDirectory.appending(path: "Library/Application Support/CrashReporter", directoryHint: .isDirectory),
                risk: .safe,
                matchRule: .allRegularFiles
            ),
            ScanLocation(
                id: "downloaded-installers",
                name: String(localized: "下载的安装包"),
                description: String(localized: "DMG、PKG、ZIP、XIP 与 ISO 文件，默认不勾选"),
                url: homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory),
                risk: .review,
                matchRule: .fileExtensions(["dmg", "pkg", "zip", "xip", "iso"])
            )
        ]
    }

    private static func openDirectory(
        parentDescriptor: Int32,
        name: String,
        timeout: TimeInterval
    ) async -> DirectoryOpenResult {
        let retainedParentDescriptor: Int32
        if parentDescriptor == AT_FDCWD {
            retainedParentDescriptor = AT_FDCWD
        } else {
            retainedParentDescriptor = Darwin.dup(parentDescriptor)
            guard retainedParentDescriptor >= 0 else {
                return DirectoryOpenResult(descriptor: -1, errorCode: errno)
            }
        }

        return await withCheckedContinuation { continuation in
            let gate = DirectoryOpenGate(continuation: continuation)

            let timeoutWorkItem = DispatchWorkItem {
                gate.resolve(descriptor: -1, errorCode: ETIMEDOUT)
            }
            gate.setTimeoutWorkItem(timeoutWorkItem)

            DispatchQueue.global(qos: .utility).async {
                let descriptor = name.withCString {
                    Darwin.openat(retainedParentDescriptor, $0, Self.directoryOpenFlags)
                }
                let errorCode = descriptor >= 0 ? 0 : errno
                if retainedParentDescriptor != AT_FDCWD {
                    Darwin.close(retainedParentDescriptor)
                }
                gate.resolve(descriptor: descriptor, errorCode: errorCode)
            }

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWorkItem
            )
        }
    }
}

private struct DirectoryOpenResult: Sendable {
    let descriptor: Int32
    let errorCode: Int32
}

private final class DirectoryOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResolved = false
    private var timeoutWorkItem: DispatchWorkItem?
    private let continuation: CheckedContinuation<DirectoryOpenResult, Never>

    init(continuation: CheckedContinuation<DirectoryOpenResult, Never>) {
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
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
            return
        }
        hasResolved = true
        let pendingTimeout = timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()
        pendingTimeout?.cancel()
        continuation.resume(returning: DirectoryOpenResult(
            descriptor: descriptor,
            errorCode: errorCode
        ))
    }
}

private struct ScanAccumulator {
    var inspectedFileCount = 0
    var candidateFileCount = 0
    var candidateBytes: Int64 = 0
    var candidates: [CleanupFileCandidate] = []
    var observation: ScanObservation

    mutating func recordAccessIssue(path: String, errorCode: Int32) {
        observation.recordPOSIX(path: path, code: errorCode,
            projectsToLegacyAccessIssues: true)
    }
}

private struct LocationScanOutcome {
    let scanResult: CleanupScanResult
    let inspectedFileCount: Int
}
