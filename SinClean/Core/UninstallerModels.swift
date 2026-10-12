import Foundation

enum ApplicationSignatureState: String, Codable, Sendable {
    case valid = "签名有效"
    case unsigned = "未签名"
    case invalid = "签名异常"
    case unavailable = "无法读取"
}

extension ApplicationSignatureState {
    var localizedDisplayName: String {
        switch self {
        case .valid: String(localized: "签名有效")
        case .unsigned: String(localized: "未签名")
        case .invalid: String(localized: "签名异常")
        case .unavailable: String(localized: "无法读取")
        }
    }
}

struct InstalledApplication: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let rootPath: String
    let bundleIdentifier: String?
    let version: String?
    let buildNumber: String?
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let deviceID: UInt64
    let inode: UInt64
    let signatureState: ApplicationSignatureState
    let signer: String?
    let teamIdentifier: String?
    let evidenceOrigin: CandidateEvidenceOrigin

    var evidence: CandidateEvidence {
        CandidateEvidence(category: .applicationBundle, origin: evidenceOrigin, sourcePath: path,
            associatedBundleIdentifier: bundleIdentifier,
            lastModifiedAt: CandidateEvidence.displayDate(seconds: modifiedSeconds, nanoseconds: modifiedNanoseconds),
            restrictionReason: ScanRules.bundleIdentifierRestriction(bundleIdentifier))
    }
}

enum AppResidueKind: String, Codable, CaseIterable, Sendable {
    case cache = "缓存"
    case logs = "日志"
    case preferences = "偏好设置"
    case savedState = "保存状态"
    case applicationSupport = "应用支持数据"
    case container = "沙盒容器"
    case httpStorage = "网络存储"
    case webKit = "网页数据"
    case applicationScripts = "应用脚本"
}

extension AppResidueKind {
    var localizedDisplayName: String {
        switch self {
        case .cache: String(localized: "缓存")
        case .logs: String(localized: "日志")
        case .preferences: String(localized: "偏好设置")
        case .savedState: String(localized: "保存状态")
        case .applicationSupport: String(localized: "应用支持数据")
        case .container: String(localized: "沙盒容器")
        case .httpStorage: String(localized: "网络存储")
        case .webKit: String(localized: "网页数据")
        case .applicationScripts: String(localized: "应用脚本")
        }
    }
}

struct AppResidueCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let bundleIdentifier: String
    let kind: AppResidueKind
    let path: String
    let rootPath: String
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let deviceID: UInt64
    let inode: UInt64
    let isDirectory: Bool
    let matchReason: String
    let evidenceOrigin: CandidateEvidenceOrigin

    var evidence: CandidateEvidence {
        CandidateEvidence(category: .residue(kind), origin: evidenceOrigin, sourcePath: path,
            associatedBundleIdentifier: bundleIdentifier,
            lastModifiedAt: CandidateEvidence.displayDate(seconds: modifiedSeconds, nanoseconds: modifiedNanoseconds),
            restrictionReason: nil)
    }
}

struct ApplicationScanProgress: Equatable, Sendable {
    static let idle = ApplicationScanProgress(
        currentPath: String(localized: "准备扫描应用"),
        discoveredCount: 0,
        measuredCount: 0
    )

    let currentPath: String
    let discoveredCount: Int
    let measuredCount: Int
}

struct ApplicationScanReport: ScanCoverageReporting {
    let applications: [InstalledApplication]
    let coverage: [ScanCoverage]
    var accessIssues: [String] { Array(coverage.flatMap(\.accessIssues).prefix(30)) }
    let startedAt: Date
    let finishedAt: Date
}

struct ResidueScanReport: ScanCoverageReporting {
    let candidates: [AppResidueCandidate]
    let coverage: [ScanCoverage]
    var accessIssues: [String] { Array(coverage.flatMap(\.accessIssues).prefix(20)) }

    var totalBytes: Int64 {
        candidates.reduce(0) { $0 + $1.allocatedBytes }
    }
}

enum AppAssociationKind: String, Codable, CaseIterable, Sendable {
    case embeddedLoginItem = "内嵌登录项"
    case userLaunchAgent = "用户登录代理"
    case systemLaunchAgent = "系统登录代理"
    case systemLaunchDaemon = "系统守护进程"
    case privilegedHelper = "特权辅助工具"
    case packageReceipt = "安装收据"
}

extension AppAssociationKind {
    var localizedDisplayName: String {
        switch self {
        case .embeddedLoginItem: String(localized: "内嵌登录项")
        case .userLaunchAgent: String(localized: "用户登录代理")
        case .systemLaunchAgent: String(localized: "系统登录代理")
        case .systemLaunchDaemon: String(localized: "系统守护进程")
        case .privilegedHelper: String(localized: "特权辅助工具")
        case .packageReceipt: String(localized: "安装收据")
        }
    }
}

enum AppAssociationRelationship: String, Codable, Sendable {
    case insideApplication = "位于应用包内部"
    case exactLabel = "配置标签与 Bundle Identifier 精确同源"
    case applicationPathReference = "配置明确引用应用路径"
    case exactNamespace = "标识符属于 Bundle Identifier 命名空间"
}

extension AppAssociationRelationship {
    var localizedDisplayName: String {
        switch self {
        case .insideApplication: String(localized: "位于应用包内部")
        case .exactLabel: String(localized: "配置标签与 Bundle Identifier 精确同源")
        case .applicationPathReference: String(localized: "配置明确引用应用路径")
        case .exactNamespace: String(localized: "标识符属于 Bundle Identifier 命名空间")
        }
    }
}

struct AppAssociatedItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: AppAssociationKind
    let path: String
    let identifier: String?
    let relationship: AppAssociationRelationship
    let isInsideApplicationBundle: Bool
    let evidenceOrigin: CandidateEvidenceOrigin
    let associatedBundleIdentifier: String
    let observedModifiedAt: Date?

    var evidence: CandidateEvidence {
        CandidateEvidence(category: .association(kind), origin: evidenceOrigin, sourcePath: path,
            associatedBundleIdentifier: associatedBundleIdentifier, lastModifiedAt: observedModifiedAt,
            restrictionReason: isInsideApplicationBundle ? .movesWithApplication : .readOnlyExternal)
    }
}

struct AppAssociationReport: ScanCoverageReporting {
    let items: [AppAssociatedItem]
    let coverage: [ScanCoverage]
    var accessIssues: [String] { Array(coverage.flatMap(\.accessIssues).prefix(20)) }

    static let empty = AppAssociationReport(items: [], coverage: [])
}

struct ApplicationScanConfiguration: Equatable, Sendable {
    let includeSystemApplications: Bool
    let includeUserApplications: Bool
    let analyzeAssociatedComponents: Bool
    let measurementConcurrency: Int

    static let standard = ApplicationScanConfiguration(
        includeSystemApplications: true,
        includeUserApplications: true,
        analyzeAssociatedComponents: true,
        measurementConcurrency: 4
    )

    func notSelectedApplicationRoots(homeDirectory: URL) -> [URL] {
        let effectiveRoots = applicationRoots(homeDirectory: homeDirectory)
        return [URL(fileURLWithPath: "/Applications", isDirectory: true),
                homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)]
            .filter { !effectiveRoots.contains($0) }
    }

    func applicationRoots(homeDirectory: URL) -> [URL] {
        var roots: [URL] = []
        if includeSystemApplications {
            roots.append(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
        if includeUserApplications {
            roots.append(homeDirectory.appending(path: "Applications", directoryHint: .isDirectory))
        }
        return roots.isEmpty
            ? [URL(fileURLWithPath: "/Applications", isDirectory: true)]
            : roots
    }
}

enum ApplicationSortOption: String, CaseIterable, Identifiable, Sendable {
    case name = "名称"
    case size = "占用空间"
    case modified = "最近修改"

    var id: Self { self }

    func sort(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        applications.sorted { lhs, rhs in
            switch self {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                return lhs.allocatedBytes == rhs.allocatedBytes
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.allocatedBytes > rhs.allocatedBytes
            case .modified:
                if lhs.modifiedSeconds == rhs.modifiedSeconds {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.modifiedSeconds > rhs.modifiedSeconds
            }
        }
    }
}

enum UninstallItemKind: String, Codable, Sendable {
    case applicationBundle
    case residueFile
    case residueDirectory
}

struct UninstallItemCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let applicationName: String
    let bundleIdentifier: String
    let kind: UninstallItemKind
    let residueKind: AppResidueKind?
    let path: String
    let rootPath: String
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let deviceID: UInt64
    let inode: UInt64
}

struct UninstallProgress: Equatable, Sendable {
    static let idle = UninstallProgress(
        currentPath: String(localized: "准备卸载"),
        completedCount: 0,
        totalCount: 0,
        movedBytes: 0,
        failureCount: 0
    )

    let currentPath: String
    let completedCount: Int
    let totalCount: Int
    let movedBytes: Int64
    let failureCount: Int
}

struct UninstallFailure: Identifiable, Hashable, Sendable {
    var id: String { "\(path)|\(reason)" }
    let path: String
    let reason: String
}

struct UninstallExecutionReport: Sendable {
    let applicationName: String
    let bundleIdentifier: String
    let requestedCount: Int
    let movedCount: Int
    let movedBytes: Int64
    let applicationMoved: Bool
    let failures: [UninstallFailure]
    let cancelled: Bool
    let startedAt: Date
    let finishedAt: Date
    let itemResults: [ExecutionItemResult]

    init(
        applicationName: String,
        bundleIdentifier: String,
        requestedCount: Int,
        movedCount: Int,
        movedBytes: Int64,
        applicationMoved: Bool,
        failures: [UninstallFailure],
        cancelled: Bool,
        finishedAt: Date,
        startedAt: Date? = nil,
        itemResults: [ExecutionItemResult] = []
    ) {
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.requestedCount = requestedCount
        self.movedCount = movedCount
        self.movedBytes = movedBytes
        self.applicationMoved = applicationMoved
        self.failures = failures
        self.cancelled = cancelled
        self.startedAt = startedAt ?? finishedAt
        self.finishedAt = finishedAt
        self.itemResults = itemResults
    }

    var executionResultSet: ExecutionResultSet {
        ExecutionResultSet(
            domain: .uninstall,
            startedAt: startedAt,
            completedAt: finishedAt,
            wasUserAborted: cancelled,
            items: itemResults
        )
    }
}

struct UninstallHistoryEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let applicationName: String
    let bundleIdentifier: String
    let finishedAt: Date
    let applicationMoved: Bool
    let movedResidueCount: Int
    let movedBytes: Int64
    let failedCount: Int
    let cancelled: Bool
}
