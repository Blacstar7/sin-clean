import Foundation

/// The immutable source selected for review. It remains the single source of candidate facts.
enum UninstallEvidenceSource: Hashable, Sendable {
    case application(InstalledApplication)
    case residue(AppResidueCandidate)
    case association(AppAssociatedItem)
}

/// A read-only presentation projection. It never authorizes or constructs uninstall work.
struct UninstallEvidenceDetail: Identifiable, Hashable, Sendable {
    let source: UninstallEvidenceSource
    let coverage: ScanCoverage?

    init(application: InstalledApplication, coverageRecords: [ScanCoverage]) {
        source = .application(application)
        coverage = Self.exactCoverage(for: application.evidenceOrigin, in: coverageRecords)
    }

    init(residue: AppResidueCandidate, coverageRecords: [ScanCoverage]) {
        source = .residue(residue)
        coverage = Self.exactCoverage(for: residue.evidenceOrigin, in: coverageRecords)
    }

    init(association: AppAssociatedItem, coverageRecords: [ScanCoverage]) {
        source = .association(association)
        coverage = Self.exactCoverage(for: association.evidenceOrigin, in: coverageRecords)
    }

    var id: String {
        switch source {
        case .application(let application): "application|\(application.id)"
        case .residue(let candidate): "residue|\(candidate.id)"
        case .association(let item): "association|\(item.id)"
        }
    }

    var evidence: CandidateEvidence {
        switch source {
        case .application(let application): application.evidence
        case .residue(let candidate): candidate.evidence
        case .association(let item): item.evidence
        }
    }

    var categoryName: String {
        switch source {
        case .application: String(localized: "应用本体")
        case .residue(let candidate): candidate.kind.localizedDisplayName
        case .association(let item): item.kind.localizedDisplayName
        }
    }

    var categoryIdentifier: String {
        switch source {
        case .application: "application.bundle"
        case .residue(let candidate): "residue.\(candidate.kind)"
        case .association(let item): "association.\(item.kind)"
        }
    }

    var path: String { evidence.sourcePath }
    var parentBundleIdentifier: String { evidence.associatedBundleIdentifier ?? String(localized: "未记录") }
    var bundleIdentifierLabel: String { isApplication ? "Bundle Identifier" : String(localized: "父应用 Bundle Identifier") }
    var reasonCode: String { evidence.reasonCode.rawValue }
    var reasonText: String { evidence.reasonText }
    var matchedValue: String? { evidence.origin.matchedValue }
    var lastModifiedAt: Date? { evidence.lastModifiedAt }
    var ruleVersion: String { evidence.ruleVersion }
    var impactLevel: ImpactLevel { evidence.impactLevel }
    var impactText: String { evidence.impactText }
    var recoverability: Recoverability { evidence.recoverability }
    var restrictionReason: RestrictionReason? { evidence.restrictionReason }

    var allocatedBytes: Int64? {
        switch source {
        case .application(let application): application.allocatedBytes
        case .residue(let candidate): candidate.allocatedBytes
        case .association: nil
        }
    }

    var logicalBytes: Int64? {
        switch source {
        case .application(let application): application.logicalBytes
        case .residue(let candidate): candidate.logicalBytes
        case .association: nil
        }
    }

    var residueMatchReason: String? {
        guard case .residue(let candidate) = source else { return nil }
        return candidate.matchReason
    }

    var itemIdentifier: String? {
        guard case .association(let item) = source else { return nil }
        return item.identifier
    }

    var relationship: AppAssociationRelationship? {
        guard case .association(let item) = source else { return nil }
        return item.relationship
    }

    var isReadOnlyAssociation: Bool {
        if case .association = source { return true }
        return false
    }

    var isApplication: Bool {
        if case .application = source { return true }
        return false
    }

    var presentationSubtitle: String {
        switch source {
        case .application: String(localized: "应用本体 · 卸载候选")
        case .residue: String(localized: "\(categoryName) · 残留候选")
        case .association: String(localized: "\(categoryName) · 只读关联")
        }
    }

    var processingBoundary: String {
        switch source {
        case .application:
            return String(localized: "只有在用户明确确认卸载后，应用本体才会进入卸载计划；执行前仍会复验应用身份和路径，且只会移动到废纸篓。应用本体处理失败时，全部残留保持不动。查看证据本身不会选择、忽略、卸载或移动任何项目。")
        case .residue:
            return String(localized: "本项只有在用户单独勾选、确认卸载且执行前身份复验通过后，才会随应用本体移到废纸篓。")
        case .association(let item) where item.isInsideApplicationBundle:
            return String(localized: "位于 APP 包内部，会随 APP 本体移动，但不是独立执行项。")
        case .association:
            return String(localized: "仅供核对，不进入卸载执行清单，不会自动删除。")
        }
    }

    var coverageStatus: CoverageStatus? { coverage?.status }
    var coverageTitle: String { coverage?.status.uninstallEvidenceTitle ?? String(localized: "覆盖状态未知") }
    var coverageExplanation: String {
        coverage?.status.uninstallEvidenceExplanation ?? String(localized: "没有找到同一扫描上下文与精确范围的覆盖记录，建议重新扫描。")
    }

    private static func exactCoverage(
        for origin: CandidateEvidenceOrigin,
        in records: [ScanCoverage]
    ) -> ScanCoverage? {
        records.first {
            $0.context.id == origin.context.id && $0.scope.id == origin.scopeID
        }
    }
}

/// Neutral report-level wording used when a scan returns no displayed item.
struct UninstallCoverageSummary: Hashable, Sendable {
    let title: String
    let message: String
    let status: CoverageStatus?
    let issueCount: Int
    let accessIssueCount: Int
    let sampledIssueCount: Int
    let omittedIssueCount: Int

    init(records: [ScanCoverage], emptyResultTitle: String) {
        issueCount = records.reduce(0) { $0 + $1.issueCount }
        accessIssueCount = records.reduce(0) { $0 + $1.accessIssueCount }
        sampledIssueCount = records.reduce(0) { $0 + $1.issues.count }
        omittedIssueCount = records.reduce(0) { $0 + $1.omittedIssueCount }

        guard !records.isEmpty else {
            title = String(localized: "覆盖状态未知")
            message = String(localized: "没有找到本轮扫描覆盖记录，建议重新扫描。")
            status = nil
            return
        }

        let resolved = Self.mostSignificantStatus(in: records)
        status = resolved
        switch resolved {
        case .completed:
            title = emptyResultTitle
            message = String(localized: "相关扫描范围已完成，候选数量为零。")
        case .partial:
            title = String(localized: "扫描范围部分完成")
            message = String(localized: "部分位置未能完成核对；当前空结果不能代表没有相关项目。")
        case .inaccessible:
            title = String(localized: "扫描范围无法访问")
            message = String(localized: "该范围未能访问；请处理覆盖记录中的具体问题后重新扫描。")
        case .notFound:
            title = String(localized: "扫描路径不存在")
            message = String(localized: "本轮记录的扫描路径不存在；这与候选数量为零是不同状态。")
        case .skipped:
            title = String(localized: "扫描范围已跳过")
            message = Self.issueMessage(in: records) ?? String(localized: "该范围因记录的安全或策略限制未执行。")
        case .notSelected:
            title = String(localized: "本轮未选择此范围")
            message = String(localized: "该范围未纳入本轮扫描；当前没有可用于判断候选的结果。")
        case .cancelled:
            title = String(localized: "扫描已取消")
            message = String(localized: "该范围没有完成核对，建议重新扫描。")
        case .notStarted:
            title = String(localized: "扫描尚未开始")
            message = String(localized: "该范围尚未开始核对。")
        case .inProgress:
            title = String(localized: "扫描正在进行")
            message = String(localized: "该范围仍在核对中，当前结果尚未冻结。")
        }
    }

    private static func issueMessage(in records: [ScanCoverage]) -> String? {
        records.lazy.flatMap(\.issues).first?.message
    }

    private static func mostSignificantStatus(in records: [ScanCoverage]) -> CoverageStatus {
        let priority: [CoverageStatus] = [
            .inaccessible, .partial, .cancelled, .skipped, .inProgress,
            .notStarted, .notSelected, .notFound, .completed
        ]
        return priority.first { status in records.contains { $0.status == status } } ?? .notStarted
    }
}

extension CoverageStatus {
    var uninstallEvidenceTitle: String {
        switch self {
        case .completed: String(localized: "已完成")
        case .partial: String(localized: "部分完成")
        case .inaccessible: String(localized: "无法访问")
        case .notFound: String(localized: "路径不存在")
        case .skipped: String(localized: "已跳过")
        case .notSelected: String(localized: "本轮未选择")
        case .cancelled: String(localized: "已取消")
        case .notStarted: String(localized: "尚未开始")
        case .inProgress: String(localized: "进行中")
        }
    }

    var uninstallEvidenceExplanation: String {
        switch self {
        case .completed: String(localized: "所属扫描范围已完整结束。")
        case .partial: String(localized: "所属扫描范围存在覆盖缺口；这不表示当前项目本身未被读取。")
        case .inaccessible: String(localized: "所属扫描范围无法访问，请根据结构化问题处理后重新扫描。")
        case .notFound: String(localized: "本轮记录的扫描路径不存在。")
        case .skipped: String(localized: "所属扫描范围因记录的安全或策略限制被跳过。")
        case .notSelected: String(localized: "所属扫描范围没有纳入本轮扫描。")
        case .cancelled: String(localized: "所属扫描范围在完成前被取消。")
        case .notStarted: String(localized: "所属扫描范围尚未开始。")
        case .inProgress: String(localized: "所属扫描范围仍在进行，结果尚未冻结。")
        }
    }
}

extension ImpactLevel {
    var uninstallEvidenceTitle: String {
        switch self {
        case .review: String(localized: "需要核对")
        case .caution: String(localized: "谨慎处理")
        case .readOnly: String(localized: "只读信息")
        }
    }
}

extension Recoverability {
    var uninstallEvidenceText: String {
        switch self {
        case .trashManual: String(localized: "若本项被移入废纸篓，可在 Finder 中手动放回。")
        case .withApplicationBundle: String(localized: "本项位于 APP 包内，可随应用本体一起从废纸篓放回。")
        case .notApplicable: String(localized: "只读核对项，不适用独立恢复。")
        }
    }
}

extension RestrictionReason {
    var uninstallEvidenceText: String {
        switch self {
        case .readOnlyExternal: String(localized: "外部关联项仅供核对")
        case .movesWithApplication: String(localized: "位于 APP 包内部")
        case .missingBundleIdentifier: String(localized: "缺少 Bundle Identifier")
        case .invalidBundleIdentifier: String(localized: "Bundle Identifier 非法")
        case .symbolicLink: String(localized: "符号链接安全跳过")
        case .unsupportedType: String(localized: "文件类型不受支持")
        case .packageBoundary: String(localized: "到达包边界")
        case .depthLimit: String(localized: "达到扫描深度限制")
        case .sizeLimit: String(localized: "达到读取大小限制")
        case .notSelected: String(localized: "本轮未选择")
        }
    }
}

extension ScanIssueKind {
    var uninstallEvidenceTitle: String {
        switch self {
        case .accessFailure: String(localized: "访问失败")
        case .timeout: String(localized: "读取超时")
        case .readFailure: String(localized: "读取失败")
        case .parseFailure: String(localized: "解析或核验失败")
        case .safetySkip: String(localized: "安全跳过")
        case .policySkip: String(localized: "策略跳过")
        case .notFound: String(localized: "路径不存在")
        }
    }
}
