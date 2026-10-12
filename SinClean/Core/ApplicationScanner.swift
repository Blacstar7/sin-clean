import Darwin
import Foundation
import Security

protocol ApplicationScanning: Sendable {
    func scan(
        progress: @escaping @Sendable (ApplicationScanProgress) async -> Void
    ) async throws -> ApplicationScanReport
}

actor ApplicationScanner: ApplicationScanning {
    private static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW

    private let applicationRoots: [URL]
    private let notSelectedRoots: [URL]
    private let maximumDiscoveryDepth: Int
    private let directoryOpenTimeout: TimeInterval
    private let measurementConcurrency: Int

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        maximumDiscoveryDepth: Int = 3,
        directoryOpenTimeout: TimeInterval = 1,
        measurementConcurrency: Int = 4
    ) {
        applicationRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)
        ]
        notSelectedRoots = []
        self.maximumDiscoveryDepth = maximumDiscoveryDepth
        self.directoryOpenTimeout = directoryOpenTimeout
        self.measurementConcurrency = min(max(measurementConcurrency, 1), 8)
    }

    init(
        applicationRoots: [URL],
        notSelectedRoots: [URL] = [],
        maximumDiscoveryDepth: Int = 3,
        directoryOpenTimeout: TimeInterval = 1,
        measurementConcurrency: Int = 4
    ) {
        self.applicationRoots = applicationRoots
        self.notSelectedRoots = notSelectedRoots.filter { !applicationRoots.contains($0) }
        self.maximumDiscoveryDepth = maximumDiscoveryDepth
        self.directoryOpenTimeout = directoryOpenTimeout
        self.measurementConcurrency = min(max(measurementConcurrency, 1), 8)
    }

    func scan(
        progress: @escaping @Sendable (ApplicationScanProgress) async -> Void
    ) async throws -> ApplicationScanReport {
        let context = ScanContext()
        var discovered: [DiscoveredApplication] = []
        var coverage: [ScanCoverage] = []
        let policy = ScanPolicy(recursive: true, maximumDepth: maximumDiscoveryDepth,
            skipsHiddenFiles: true, acceptedTypes: ["directory"], extensions: ["app"],
            matching: "app directory; app boundary stops discovery; depth starts at zero",
            directoryOpenTimeout: directoryOpenTimeout, measurementConcurrency: measurementConcurrency)
        for root in notSelectedRoots {
            var observation = ScanObservation(context: context, scope: ScanScope(id: root.path,
                scanner: .application, phase: .discover, rootPath: root.path, policy: policy), issueLimit: 30)
            observation.finish(.notSelected)
            coverage.append(observation.snapshot)
        }
        for root in applicationRoots {
            var observation = ScanObservation(context: context, scope: ScanScope(id: root.path,
                scanner: .application, phase: .discover, rootPath: root.path, policy: policy), issueLimit: 30)
            if Task.isCancelled {
                observation.finish(.cancelled); coverage.append(observation.snapshot); continue
            }
            observation.begin()
            await progress(ApplicationScanProgress(currentPath: root.path,
                discoveredCount: discovered.count, measuredCount: 0))
            let openResult = await Self.openDirectory(parentDescriptor: AT_FDCWD,
                name: root.path, timeout: directoryOpenTimeout)
            guard openResult.descriptor >= 0 else {
                observation.recordPOSIX(path: root.path, code: openResult.errorCode, atRoot: true,
                    projectsToLegacyAccessIssues: true)
                coverage.append(observation.snapshot); continue
            }
            do {
                try await discoverApplications(descriptor: openResult.descriptor, directoryURL: root,
                    rootURL: root, depth: 0, discovered: &discovered,
                    observation: &observation, progress: progress)
                observation.finish()
            } catch is CancellationError {
                observation.finish(.cancelled)
            }
            coverage.append(observation.snapshot)
        }

        var applications: [InstalledApplication] = []
        let openTimeout = directoryOpenTimeout
        for batchStart in stride(from: 0, to: discovered.count, by: measurementConcurrency) {
            let batchEnd = min(batchStart + measurementConcurrency, discovered.count)
            let batch = Array(discovered[batchStart..<batchEnd])
            if Task.isCancelled {
                for item in batch {
                    var observation = Self.measurementObservation(for: item.url, context: context, timeout: openTimeout)
                    observation.finish(.cancelled); coverage.append(observation.snapshot)
                }
                continue
            }
            await withTaskGroup(of: ApplicationInspection.self) { group in
                for item in batch {
                    group.addTask {
                        await Self.inspectApplication(item, context: context, directoryOpenTimeout: openTimeout)
                    }
                }
                for await inspection in group {
                    applications.append(inspection.application)
                    coverage.append(contentsOf: inspection.coverage)
                    await progress(ApplicationScanProgress(currentPath: inspection.application.path,
                        discoveredCount: discovered.count, measuredCount: applications.count))
                }
            }
        }
        applications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        await progress(ApplicationScanProgress(currentPath: String(localized: "应用扫描完成"),
            discoveredCount: applications.count, measuredCount: applications.count))
        return ApplicationScanReport(applications: applications, coverage: coverage.boundedIssueSamples(30),
            startedAt: context.startedAt, finishedAt: Date())
    }

    private func discoverApplications(
        descriptor: Int32,
        directoryURL: URL,
        rootURL: URL,
        depth: Int,
        discovered: inout [DiscoveredApplication],
        observation: inout ScanObservation,
        progress: @escaping @Sendable (ApplicationScanProgress) async -> Void
    ) async throws {
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
            try Task.checkCancellation()
            let name = Self.entryName(entry)
            guard name != ".", name != "..", !name.hasPrefix(".") else { continue }

            var info = stat()
            let status = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                observation.recordPOSIX(path: directoryURL.appendingPathComponent(name).path, code: errno,
                    projectsToLegacyAccessIssues: true)
                continue
            }

            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    observation.skip(path: directoryURL.appendingPathComponent(name).path,
                        reason: .symbolicLink, message: String(localized: "应用发现不跟随符号链接"),
                        projectsToLegacyAccessIssues: false)
                }
                continue
            }
            let childURL = directoryURL.appendingPathComponent(name, isDirectory: true)

            if childURL.pathExtension.lowercased() == "app" {
                discovered.append(DiscoveredApplication(url: childURL, rootURL: rootURL, identity: info))
                if discovered.count.isMultiple(of: 10) {
                    await progress(ApplicationScanProgress(
                        currentPath: childURL.path,
                        discoveredCount: discovered.count,
                        measuredCount: 0
                    ))
                }
                continue
            }

            guard depth < maximumDiscoveryDepth else {
                observation.skip(path: childURL.path, reason: .depthLimit,
                    message: String(localized: "已到本轮应用发现深度边界"), policy: true,
                    projectsToLegacyAccessIssues: false)
                continue
            }
            let childOpen = await Self.openDirectory(
                parentDescriptor: directoryDescriptor,
                name: name,
                timeout: directoryOpenTimeout
            )
            guard childOpen.descriptor >= 0 else {
                observation.recordPOSIX(path: childURL.path, code: childOpen.errorCode,
                    projectsToLegacyAccessIssues: true)
                continue
            }

            try await discoverApplications(
                descriptor: childOpen.descriptor,
                directoryURL: childURL,
                rootURL: rootURL,
                depth: depth + 1,
                discovered: &discovered,
                observation: &observation,
                progress: progress
            )
        }
    }

    private static func inspectApplication(
        _ item: DiscoveredApplication,
        context: ScanContext,
        directoryOpenTimeout: TimeInterval
    ) async -> ApplicationInspection {
        let measurement = await measureTree(
            at: item.url,
            context: context,
            directoryOpenTimeout: directoryOpenTimeout
        )

        var metadata = ScanObservation(context: context, scope: ScanScope(id: "inspect|\(item.url.path)",
            scanner: .application, phase: .inspect, rootPath: item.url.path, targetPath: item.url.path,
            policy: ScanPolicy(recursive: false, matching: "Bundle metadata and existing Security framework checks")), issueLimit: 30)
        metadata.begin()
        let bundle = Bundle(url: item.url)
        let info = bundle?.infoDictionary
        Self.recordBundleMetadataDiagnostics(at: item.url, observation: &metadata)
        if info == nil {
            metadata.record(path: item.url.path, kind: .parseFailure,
                message: String(localized: "Bundle 未返回应用元数据字典；未取得底层错误码"),
                projectsToLegacyAccessIssues: false)
        }
        if let restriction = ScanRules.bundleIdentifierRestriction(bundle?.bundleIdentifier) {
            metadata.skip(path: item.url.path, reason: restriction,
                message: restriction == .missingBundleIdentifier
                    ? String(localized: "应用元数据缺少 Bundle Identifier，后续精确残留和关联分析受限")
                    : String(localized: "应用 Bundle Identifier 不符合固定路径规则，后续精确残留和关联分析受限"),
                policy: true, projectsToLegacyAccessIssues: false)
        }
        let displayName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? item.url.deletingPathExtension().lastPathComponent
        let version = info?["CFBundleShortVersionString"] as? String
        let buildNumber = info?["CFBundleVersion"] as? String
        let signature = Self.signatureInformation(for: item.url, observation: &metadata)
        metadata.finish()

        let application = InstalledApplication(
            id: "\(item.identity.st_dev)|\(item.identity.st_ino)|\(item.url.path)",
            name: displayName,
            path: item.url.path,
            rootPath: item.rootURL.standardizedFileURL.path,
            bundleIdentifier: bundle?.bundleIdentifier,
            version: version,
            buildNumber: buildNumber,
            allocatedBytes: measurement.allocatedBytes,
            logicalBytes: Int64(item.identity.st_size),
            modifiedSeconds: Int64(item.identity.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(item.identity.st_mtimespec.tv_nsec),
            deviceID: UInt64(item.identity.st_dev),
            inode: UInt64(item.identity.st_ino),
            signatureState: signature.state,
            signer: signature.signer,
            teamIdentifier: signature.teamIdentifier,
            evidenceOrigin: CandidateEvidenceOrigin(context: context, scopeID: item.rootURL.path,
                reasonCode: .applicationDirectory)
        )
        return ApplicationInspection(
            application: application,
            coverage: [measurement.coverage, metadata.snapshot]
        )
    }

    private static func measurementObservation(for url: URL, context: ScanContext, timeout: TimeInterval) -> ScanObservation {
        ScanObservation(context: context, scope: ScanScope(id: "measure|\(url.path)",
            scanner: .application, phase: .measure, rootPath: url.path, targetPath: url.path,
            policy: ScanPolicy(recursive: true, matching: "sum regular file blocks; traverse directories without following links",
                directoryOpenTimeout: timeout)), issueLimit: 30)
    }

    private static func measureTree(at rootURL: URL, context: ScanContext,
                                    directoryOpenTimeout: TimeInterval) async -> TreeMeasurement {
        var observation = measurementObservation(for: rootURL, context: context, timeout: directoryOpenTimeout)
        observation.begin()
        let openResult = await Self.openDirectory(parentDescriptor: AT_FDCWD,
            name: rootURL.path, timeout: directoryOpenTimeout)
        guard openResult.descriptor >= 0 else {
            observation.recordPOSIX(path: rootURL.path, code: openResult.errorCode, atRoot: true,
                projectsToLegacyAccessIssues: true)
            return TreeMeasurement(allocatedBytes: 0, coverage: observation.snapshot)
        }
        var bytes: Int64 = 0
        await measureDirectory(descriptor: openResult.descriptor, directoryURL: rootURL,
            bytes: &bytes, observation: &observation, directoryOpenTimeout: directoryOpenTimeout)
        observation.finish(Task.isCancelled ? .cancelled : nil)
        return TreeMeasurement(allocatedBytes: bytes, coverage: observation.snapshot)
    }

    private static func measureDirectory(
        descriptor: Int32,
        directoryURL: URL,
        bytes: inout Int64,
        observation: inout ScanObservation,
        directoryOpenTimeout: TimeInterval
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
                let allocated = Int64(info.st_blocks) * 512
                bytes += max(0, allocated > 0 ? allocated : Int64(info.st_size))
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
                    observation: &observation,
                    directoryOpenTimeout: directoryOpenTimeout
                )
            } else {
                observation.skip(path: directoryURL.appendingPathComponent(name).path,
                    reason: type == mode_t(S_IFLNK) ? .symbolicLink : .unsupportedType,
                    message: String(localized: "容量测量仅累计普通文件并下探目录"),
                    projectsToLegacyAccessIssues: false)
            }
        }
    }

    private static func recordBundleMetadataDiagnostics(
        at applicationURL: URL,
        observation: inout ScanObservation
    ) {
        let infoURL = applicationURL.appending(path: "Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: infoURL, options: [.mappedIfSafe])
        } catch {
            observation.record(error: error, path: infoURL.path, kind: .readFailure,
                projectsToLegacyAccessIssues: false)
            return
        }
        do {
            guard try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) is [String: Any] else {
                observation.record(path: infoURL.path, kind: .parseFailure,
                    message: String(localized: "应用 Info.plist 顶层不是字典"),
                    projectsToLegacyAccessIssues: false)
                return
            }
        } catch {
            observation.record(error: error, path: infoURL.path, kind: .parseFailure,
                projectsToLegacyAccessIssues: false)
        }
    }

    private static func signatureInformation(for url: URL, observation: inout ScanObservation) -> SignatureInformation {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            observation.record(path: url.path, kind: .readFailure, message: String(localized: "无法创建应用静态签名对象"),
                domain: NSOSStatusErrorDomain, code: Int(createStatus),
                projectsToLegacyAccessIssues: false)
            return SignatureInformation(state: .unavailable, signer: nil, teamIdentifier: nil)
        }

        let validityStatus = SecStaticCodeCheckValidity(staticCode, [], nil)
        if validityStatus != errSecSuccess && validityStatus != errSecCSUnsigned {
            observation.record(path: url.path, kind: .readFailure, message: String(localized: "应用签名校验返回异常状态"),
                domain: NSOSStatusErrorDomain, code: Int(validityStatus),
                projectsToLegacyAccessIssues: false)
        }
        var signingDictionary: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingDictionary
        )

        guard infoStatus == errSecSuccess,
              let dictionary = signingDictionary as? [String: Any] else {
            observation.record(path: url.path, kind: .readFailure, message: String(localized: "无法取得签名信息字典"),
                domain: infoStatus == errSecSuccess ? nil : NSOSStatusErrorDomain,
                code: infoStatus == errSecSuccess ? nil : Int(infoStatus),
                projectsToLegacyAccessIssues: false)
            return SignatureInformation(
                state: validityStatus == errSecCSUnsigned ? .unsigned : .invalid,
                signer: nil,
                teamIdentifier: nil
            )
        }

        let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let signer = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let state: ApplicationSignatureState
        if validityStatus == errSecSuccess {
            state = .valid
        } else if validityStatus == errSecCSUnsigned {
            state = .unsigned
        } else {
            state = .invalid
        }

        return SignatureInformation(state: state, signer: signer, teamIdentifier: teamIdentifier)
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
    ) async -> AppDirectoryOpenResult {
        let retainedParent: Int32
        if parentDescriptor == AT_FDCWD {
            retainedParent = AT_FDCWD
        } else {
            retainedParent = Darwin.dup(parentDescriptor)
            guard retainedParent >= 0 else {
                return AppDirectoryOpenResult(descriptor: -1, errorCode: errno)
            }
        }

        return await withCheckedContinuation { continuation in
            let gate = AppDirectoryOpenGate(continuation: continuation)
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

private struct DiscoveredApplication: @unchecked Sendable {
    let url: URL
    let rootURL: URL
    let identity: stat
}

private struct ApplicationInspection: Sendable {
    let application: InstalledApplication
    let coverage: [ScanCoverage]
}

private struct TreeMeasurement {
    let allocatedBytes: Int64
    let coverage: ScanCoverage
}

private struct SignatureInformation {
    let state: ApplicationSignatureState
    let signer: String?
    let teamIdentifier: String?
}

private struct AppDirectoryOpenResult: Sendable {
    let descriptor: Int32
    let errorCode: Int32
}

private final class AppDirectoryOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResolved = false
    private var timeoutWorkItem: DispatchWorkItem?
    private let continuation: CheckedContinuation<AppDirectoryOpenResult, Never>

    init(continuation: CheckedContinuation<AppDirectoryOpenResult, Never>) {
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
        continuation.resume(returning: AppDirectoryOpenResult(
            descriptor: descriptor,
            errorCode: errorCode
        ))
    }
}
