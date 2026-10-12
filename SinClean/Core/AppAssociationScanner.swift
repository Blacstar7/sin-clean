import Darwin
import Foundation

protocol AppAssociationScanning: Sendable {
    func scan(for application: InstalledApplication) async -> AppAssociationReport
    func scan(for application: InstalledApplication, enabled: Bool) async -> AppAssociationReport
}

extension AppAssociationScanning {
    func scan(for application: InstalledApplication, enabled: Bool) async -> AppAssociationReport {
        if enabled { return await scan(for: application) }
        var observation = ScanObservation(context: ScanContext(), scope: ScanScope(id: "association-disabled",
            scanner: .association, phase: .associate, rootPath: application.path, applicationID: application.id,
            bundleIdentifier: application.bundleIdentifier, policy: ScanPolicy(recursive: false, matching: "injected association scanner disabled")))
        observation.finish(.notSelected)
        return AppAssociationReport(items: [], coverage: [observation.snapshot])
    }
}

actor AppAssociationScanner: AppAssociationScanning {
    private let launchItemLocations: [AssociationLocation]
    private let privilegedHelperRoot: URL
    private let receiptRoot: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        launchItemLocations = [
            AssociationLocation(
                rootURL: homeDirectory.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory),
                kind: .userLaunchAgent
            ),
            AssociationLocation(
                rootURL: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                kind: .systemLaunchAgent
            ),
            AssociationLocation(
                rootURL: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
                kind: .systemLaunchDaemon
            )
        ]
        privilegedHelperRoot = URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true)
        receiptRoot = URL(fileURLWithPath: "/var/db/receipts", isDirectory: true)
    }

    init(
        launchItemLocations: [AssociationLocation],
        privilegedHelperRoot: URL,
        receiptRoot: URL
    ) {
        self.launchItemLocations = launchItemLocations
        self.privilegedHelperRoot = privilegedHelperRoot
        self.receiptRoot = receiptRoot
    }

    func scan(for application: InstalledApplication) async -> AppAssociationReport {
        await scan(for: application, enabled: true)
    }

    func scan(for application: InstalledApplication, enabled: Bool) async -> AppAssociationReport {
        let context = ScanContext()
        let embedded = URL(fileURLWithPath: application.path, isDirectory: true)
            .appending(path: "Contents/Library/LoginItems", directoryHint: .isDirectory)
        let locations = [AssociationLocation(rootURL: embedded, kind: .embeddedLoginItem)]
            + launchItemLocations
            + [AssociationLocation(rootURL: privilegedHelperRoot, kind: .privilegedHelper),
               AssociationLocation(rootURL: receiptRoot, kind: .packageReceipt)]
        // Register the whole effective scope before any filesystem access.
        let scopes = locations.map { location -> ScanScope in
            let isLaunch = [.userLaunchAgent, .systemLaunchAgent, .systemLaunchDaemon].contains(location.kind)
            let extensions = isLaunch ? ["plist"] : (location.kind == .packageReceipt ? ["plist", "bom"] : (location.kind == .embeddedLoginItem ? ["app"] : []))
            return ScanScope(id: "\(location.kind.rawValue)|\(location.rootURL.path)", scanner: .association,
                phase: .associate, rootPath: location.rootURL.path, applicationID: application.id,
                bundleIdentifier: application.bundleIdentifier,
                policy: ScanPolicy(recursive: false, skipsHiddenFiles: true,
                    acceptedTypes: isLaunch ? ["regularFile"] : (location.kind == .embeddedLoginItem ? ["directory"] : ["regularFile", "directory"]),
                    extensions: extensions,
                    matching: isLaunch ? "Label namespace first, otherwise absolute application path reference" : (location.kind == .embeddedLoginItem ? "embedded app directory" : "exact or dot-delimited Bundle Identifier namespace"),
                    maximumReadBytes: isLaunch ? 2_000_000 : nil))
        }
        var items: [AppAssociatedItem] = []
        var coverage: [ScanCoverage] = []
        for (index, pair) in zip(locations, scopes).enumerated() {
            let (location, scope) = pair
            var observation = ScanObservation(context: context, scope: scope)
            if !enabled { observation.finish(.notSelected); coverage.append(observation.snapshot); continue }
            guard let bundleIdentifier = application.bundleIdentifier,
                  Self.isSafeBundleIdentifier(bundleIdentifier) else {
                observation.skip(path: application.path,
                    reason: application.bundleIdentifier == nil ? .missingBundleIdentifier : .invalidBundleIdentifier,
                    message: String(localized: "应用没有可安全使用的 Bundle Identifier，未分析后台关联项目。"),
                    atRoot: true, projectsToLegacyAccessIssues: index == 0)
                coverage.append(observation.snapshot); continue
            }
            if Task.isCancelled { observation.finish(.cancelled); coverage.append(observation.snapshot); continue }
            observation.begin()
            switch location.kind {
            case .embeddedLoginItem:
                scanEmbeddedLoginItems(at: location.rootURL, bundleIdentifier: bundleIdentifier, into: &items, observation: &observation)
            case .userLaunchAgent, .systemLaunchAgent, .systemLaunchDaemon:
                scanLaunchItems(at: location, bundleIdentifier: bundleIdentifier,
                    applicationPath: application.path, into: &items, observation: &observation)
            case .privilegedHelper, .packageReceipt:
                scanNamespaceEntries(at: location.rootURL, kind: location.kind, bundleIdentifier: bundleIdentifier,
                    acceptedExtensions: location.kind == .packageReceipt ? ["plist", "bom"] : nil,
                    into: &items, observation: &observation)
            }
            observation.finish(Task.isCancelled && observation.status == .inProgress ? .cancelled : nil)
            coverage.append(observation.snapshot)
        }
        let uniqueItems = Dictionary(grouping: items, by: \.id).compactMap { $0.value.first }.sorted {
            if $0.kind.rawValue == $1.kind.rawValue { return $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return $0.kind.rawValue.localizedStandardCompare($1.kind.rawValue) == .orderedAscending
        }
        return AppAssociationReport(items: uniqueItems, coverage: coverage.boundedIssueSamples(20))
    }

    private func scanEmbeddedLoginItems(at root: URL, bundleIdentifier: String,
        into items: inout [AppAssociatedItem], observation: inout ScanObservation) {
        for entry in safeDirectoryEntries(at: root, observation: &observation) {
            guard entry.pathExtension.lowercased() == "app",
                  let info = fileInfo(at: entry, observation: &observation) else { continue }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                recordTypeSkip(at: entry, info: info, observation: &observation); continue
            }
            items.append(AppAssociatedItem(id: "embedded|\(entry.path)", kind: .embeddedLoginItem,
                path: entry.path, identifier: Bundle(url: entry)?.bundleIdentifier,
                relationship: .insideApplication, isInsideApplicationBundle: true,
                evidenceOrigin: CandidateEvidenceOrigin(context: observation.context, scopeID: observation.scope.id, reasonCode: .embeddedLoginApp),
                associatedBundleIdentifier: bundleIdentifier, observedModifiedAt: displayDate(info)))
        }
    }

    private func scanLaunchItems(at location: AssociationLocation, bundleIdentifier: String, applicationPath: String,
        into items: inout [AppAssociatedItem], observation: inout ScanObservation) {
        for entry in safeDirectoryEntries(at: location.rootURL, observation: &observation) {
            guard entry.pathExtension.lowercased() == "plist",
                  let info = fileInfo(at: entry, observation: &observation) else { continue }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                recordTypeSkip(at: entry, info: info, observation: &observation); continue
            }
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: entry.path) }
            catch {
                observation.record(error: error, path: entry.path,
                    projectsToLegacyAccessIssues: false)
                continue
            }
            guard let size = attributes[.size] as? NSNumber else {
                observation.record(path: entry.path, kind: .readFailure,
                    message: String(localized: "文件属性未返回大小"), projectsToLegacyAccessIssues: false)
                continue
            }
            guard size.int64Value <= 2_000_000 else {
                observation.skip(path: entry.path, reason: .sizeLimit,
                    message: String(localized: "超过既有 2,000,000 字节读取上限"), policy: true,
                    projectsToLegacyAccessIssues: false)
                continue
            }
            let data: Data
            do { data = try Data(contentsOf: entry, options: [.mappedIfSafe]) }
            catch {
                observation.record(error: error, path: entry.path,
                    projectsToLegacyAccessIssues: false)
                continue
            }
            let dictionary: [String: Any]
            do {
                guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    observation.record(path: entry.path, kind: .parseFailure,
                        message: String(localized: "plist 顶层不是字典"), projectsToLegacyAccessIssues: false)
                    continue
                }
                dictionary = value
            } catch {
                observation.record(error: error, path: entry.path, kind: .parseFailure,
                    projectsToLegacyAccessIssues: false)
                continue
            }
            let label = dictionary["Label"] as? String
            let program = dictionary["Program"] as? String
            let arguments = dictionary["ProgramArguments"] as? [String] ?? []
            let referencedPaths = ([program].compactMap { $0 } + arguments).filter { $0.hasPrefix("/") }
            let relationship: AppAssociationRelationship
            let code: CandidateRuleCode
            let matchedValue: String
            if label == bundleIdentifier || label?.hasPrefix("\(bundleIdentifier).") == true {
                relationship = .exactLabel; code = .launchLabelNamespace; matchedValue = label!
            } else if let path = referencedPaths.first(where: { Self.isSamePathOrDescendant($0, of: applicationPath) }) {
                relationship = .applicationPathReference; code = .launchApplicationPathReference; matchedValue = path
            } else { continue }
            items.append(AppAssociatedItem(id: "launch|\(entry.path)", kind: location.kind, path: entry.path,
                identifier: label, relationship: relationship, isInsideApplicationBundle: false,
                evidenceOrigin: CandidateEvidenceOrigin(context: observation.context, scopeID: observation.scope.id, reasonCode: code, matchedValue: matchedValue),
                associatedBundleIdentifier: bundleIdentifier, observedModifiedAt: displayDate(info)))
        }
    }

    private func scanNamespaceEntries(at root: URL, kind: AppAssociationKind, bundleIdentifier: String,
        acceptedExtensions: Set<String>?, into items: inout [AppAssociatedItem], observation: inout ScanObservation) {
        for entry in safeDirectoryEntries(at: root, observation: &observation) {
            guard let info = fileInfo(at: entry, observation: &observation) else { continue }
            let type = info.st_mode & mode_t(S_IFMT)
            guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) else {
                recordTypeSkip(at: entry, info: info, observation: &observation); continue
            }
            if let acceptedExtensions, !acceptedExtensions.contains(entry.pathExtension.lowercased()) { continue }
            let identifier = acceptedExtensions == nil ? entry.lastPathComponent : entry.deletingPathExtension().lastPathComponent
            guard identifier == bundleIdentifier || identifier.hasPrefix("\(bundleIdentifier).") else { continue }
            items.append(AppAssociatedItem(id: "namespace|\(entry.path)", kind: kind, path: entry.path,
                identifier: identifier, relationship: .exactNamespace, isInsideApplicationBundle: false,
                evidenceOrigin: CandidateEvidenceOrigin(context: observation.context, scopeID: observation.scope.id,
                    reasonCode: kind == .packageReceipt ? .receiptNamespace : .helperNamespace, matchedValue: identifier),
                associatedBundleIdentifier: bundleIdentifier, observedModifiedAt: displayDate(info)))
        }
    }

    private func safeDirectoryEntries(at root: URL, observation: inout ScanObservation) -> [URL] {
        var rootInfo = stat()
        let rootStatus = root.path.withCString { Darwin.lstat($0, &rootInfo) }
        guard rootStatus == 0 else {
            observation.recordPOSIX(path: root.path, code: errno, atRoot: true,
                projectsToLegacyAccessIssues: true)
            return []
        }
        guard rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            observation.skip(path: root.path,
                reason: rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) ? .symbolicLink : .unsupportedType,
                message: String(localized: "不是可读取目录"), atRoot: true,
                projectsToLegacyAccessIssues: false)
            return []
        }
        do {
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            observation.record(error: error, path: root.path, atRoot: true,
                projectsToLegacyAccessIssues: true)
            return []
        }
    }

    private func fileInfo(at url: URL, observation: inout ScanObservation) -> stat? {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else {
            observation.recordPOSIX(path: url.path, code: errno,
                projectsToLegacyAccessIssues: false)
            return nil
        }
        return info
    }

    private func recordTypeSkip(at url: URL, info: stat, observation: inout ScanObservation) {
        observation.skip(path: url.path, reason: info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) ? .symbolicLink : .unsupportedType,
            message: String(localized: "目标类型不符合本关联规则，已跳过"),
            projectsToLegacyAccessIssues: false)
    }

    private func displayDate(_ info: stat) -> Date {
        CandidateEvidence.displayDate(seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    private static func isSamePathOrDescendant(_ path: String, of rootPath: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.pathComponents
        guard candidate.count >= root.count else { return false }
        return Array(candidate.prefix(root.count)) == root
    }

    private static func isSafeBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains("..") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

}

struct AssociationLocation: Sendable {
    let rootURL: URL
    let kind: AppAssociationKind
}
