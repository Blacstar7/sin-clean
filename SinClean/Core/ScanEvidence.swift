import Darwin
import Foundation

/// Scan rule schema, deliberately independent of the application's marketing version.
enum ScanRules {
    static let version = "fixed-rules-1"

    /// Same predicate as the existing residue/association guards; diagnostic classification only.
    static func bundleIdentifierRestriction(_ value: String?) -> RestrictionReason? {
        guard let value else { return .missingBundleIdentifier }
        guard !value.isEmpty, !value.hasPrefix("."), !value.hasSuffix("."), !value.contains("..") else {
            return .invalidBundleIdentifier
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) } ? nil : .invalidBundleIdentifier
    }
}

struct ScanContext: Hashable, Sendable {
    let id = UUID()
    let startedAt = Date()
    let ruleVersion = ScanRules.version
}

enum CandidateRuleCode: String, CaseIterable, Sendable {
    case userCaches = "cleanup.userCaches.regularFile"
    case userLogs = "cleanup.userLogs.regularFile"
    case crashReports = "cleanup.crashReports.regularFile"
    case downloadedInstallers = "cleanup.downloads.installerExtension"
    // The injected ScanLocation API also supports arbitrary explicit match rules.
    case configuredRegularFiles = "cleanup.configured.regularFile"
    case configuredExtensions = "cleanup.configured.fileExtension"
    case applicationDirectory = "application.discoveredAppDirectory"
    case residueCache = "residue.cache.exactBundlePath"
    case residueLogs = "residue.logs.exactBundlePath"
    case residuePreferences = "residue.preferences.exactBundlePlist"
    case residueSavedState = "residue.savedState.exactBundlePath"
    case residueApplicationSupport = "residue.applicationSupport.exactBundlePath"
    case residueContainer = "residue.container.exactBundlePath"
    case residueHTTPStorage = "residue.httpStorage.exactBundlePath"
    case residueWebKit = "residue.webKit.exactBundlePath"
    case residueApplicationScripts = "residue.applicationScripts.exactBundlePath"
    case embeddedLoginApp = "association.embeddedLoginApp"
    case launchLabelNamespace = "association.launchLabelNamespace"
    case launchApplicationPathReference = "association.launchApplicationPathReference"
    case helperNamespace = "association.helperIdentifierNamespace"
    case receiptNamespace = "association.receiptIdentifierNamespace"

    var explanation: String {
        switch self {
        case .userCaches: return String(localized: "用户 Caches 扫描范围内的普通文件。")
        case .userLogs: return String(localized: "用户 Logs 扫描范围内的普通文件。")
        case .crashReports: return String(localized: "用户 CrashReporter 扫描范围内的普通文件。")
        case .downloadedInstallers: return String(localized: "Downloads 扫描范围内的普通文件，扩展名命中 dmg/pkg/zip/xip/iso 规则。")
        case .configuredRegularFiles: return String(localized: "注入扫描范围内命中普通文件规则。")
        case .configuredExtensions: return String(localized: "注入扫描范围内的普通文件，扩展名命中本轮配置。")
        case .applicationDirectory: return String(localized: "在本轮应用发现范围及深度内发现扩展名为 app 的目录。")
        case .residueCache, .residueLogs, .residuePreferences, .residueSavedState,
             .residueApplicationSupport, .residueContainer, .residueHTTPStorage,
             .residueWebKit, .residueApplicationScripts:
            return String(localized: "本类别固定路径与 Bundle Identifier 精确匹配，目标为普通文件或目录；未据此判断内容或独占所有权。")
        case .embeddedLoginApp: return String(localized: "应用包 Contents/Library/LoginItems 中发现 app 目录；未检查注册或运行状态。")
        case .launchLabelNamespace: return String(localized: "Launch plist 的 Label 等于应用 Bundle Identifier 或属于其点分命名空间。")
        case .launchApplicationPathReference: return String(localized: "Launch plist 的 Program 或 ProgramArguments 中存在引用应用路径或其后代的绝对路径。")
        case .helperNamespace: return String(localized: "辅助工具文件或目录名称命中应用 Bundle Identifier 的点分命名空间。")
        case .receiptNamespace: return String(localized: "plist/bom 收据名称去除扩展名后命中应用 Bundle Identifier 的点分命名空间；未解析安装所有权。")
        }
    }
}

enum CandidateCategory: Hashable, Sendable {
    case cleanup(locationID: String)
    case applicationBundle
    case residue(AppResidueKind)
    case association(AppAssociationKind)
}

enum ImpactLevel: String, Sendable { case review, caution, readOnly }
enum Recoverability: String, Sendable { case trashManual, withApplicationBundle, notApplicable }
enum RestrictionReason: String, Sendable {
    case readOnlyExternal, movesWithApplication, missingBundleIdentifier, invalidBundleIdentifier
    case symbolicLink, unsupportedType, packageBoundary, depthLimit, sizeLimit, notSelected
}

/// Only rule provenance is stored alongside executable candidates. Identity stays in the original fields.
struct CandidateEvidenceOrigin: Hashable, Sendable {
    let context: ScanContext
    let scopeID: String
    let reasonCode: CandidateRuleCode
    let matchedValue: String?

    init(context: ScanContext, scopeID: String, reasonCode: CandidateRuleCode, matchedValue: String? = nil) {
        self.context = context
        self.scopeID = scopeID
        self.reasonCode = reasonCode
        self.matchedValue = matchedValue
    }
}

/// A read-only projection, never an authorization or executor identity snapshot.
struct CandidateEvidence: Hashable, Sendable {
    let category: CandidateCategory
    let origin: CandidateEvidenceOrigin
    let sourcePath: String
    let associatedBundleIdentifier: String?
    let lastModifiedAt: Date?
    let restrictionReason: RestrictionReason?

    var reasonCode: CandidateRuleCode { origin.reasonCode }
    var reasonText: String {
        reasonCode.explanation + (origin.matchedValue.map { String(localized: " 实际匹配值：\($0)") } ?? "")
    }
    var ruleVersion: String { origin.context.ruleVersion }
    var impactLevel: ImpactLevel {
        switch category {
        case .cleanup: return .review
        case .applicationBundle, .residue: return .caution
        case .association: return .readOnly
        }
    }
    var impactText: String {
        switch category {
        case .cleanup: return String(localized: "移除会使原路径下的文件不再可用，请确认用途；不保证能够重新生成。")
        case .applicationBundle: return String(localized: "移动应用包会使该路径下的应用及包内组件不可用。")
        case .residue: return String(localized: "移动本项可能影响应用配置、登录状态或本地数据，请逐项确认。")
        case .association: return restrictionReason == .movesWithApplication
            ? String(localized: "仅作关联说明；该项位于应用包内，可能随应用包一起移动。")
            : String(localized: "仅供核对，当前卸载流程不会单独处理此关联项。")
        }
    }
    var recoverability: Recoverability {
        switch category {
        case .association: return restrictionReason == .movesWithApplication ? .withApplicationBundle : .notApplicable
        default: return .trashManual
        }
    }

    static func displayDate(seconds: Int64, nanoseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }
}

extension ScanLocation {
    var evidenceRule: CandidateRuleCode {
        switch (id, matchRule) {
        case ("user-caches", .allRegularFiles): return .userCaches
        case ("user-logs", .allRegularFiles): return .userLogs
        case ("crash-reports", .allRegularFiles): return .crashReports
        case ("downloaded-installers", .fileExtensions(let values)) where values == ["dmg", "pkg", "zip", "xip", "iso"]: return .downloadedInstallers
        case (_, .allRegularFiles): return .configuredRegularFiles
        case (_, .fileExtensions): return .configuredExtensions
        }
    }
}

extension AppResidueKind {
    var evidenceRule: CandidateRuleCode {
        switch self {
        case .cache: return .residueCache
        case .logs: return .residueLogs
        case .preferences: return .residuePreferences
        case .savedState: return .residueSavedState
        case .applicationSupport: return .residueApplicationSupport
        case .container: return .residueContainer
        case .httpStorage: return .residueHTTPStorage
        case .webKit: return .residueWebKit
        case .applicationScripts: return .residueApplicationScripts
        }
    }
}
