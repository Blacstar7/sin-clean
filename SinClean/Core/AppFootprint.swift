import Darwin
import Foundation

// SC-PD3 应用占用全景（冻结语义 work/SC-PD3-frozen-semantics.md）。
// 纯派生层：只读消费既有扫描输出与一次身份复验；不产生执行项、不持久化、不重扫。

enum AppFootprintTier: String, CaseIterable, Sendable {
    case applicationBundle = "应用本体"
    case userResidue = "可归属用户级残留"
    case readOnlyAssociation = "只读关联项目"
    case unattributableScope = "未能读取或无法安全归属的范围"
}

// MARK: - 检查完整度四态（冻结 §2）

enum AppFootprintCompleteness: Equatable, Sendable {
    case complete
    case partial(gaps: [AppFootprintCoverageGap])
    case cannotJudge(reason: AppFootprintCannotJudgeReason)
    case notChecked(reason: AppFootprintNotCheckedReason)
}

enum AppFootprintCannotJudgeReason: Equatable, Sendable {
    case missingBundleIdentifier
    case invalidBundleIdentifier
    case applicationIdentityChanged(AppFootprintIdentityChangeDetail)
    case scanResultDamaged(detail: String)
}

enum AppFootprintIdentityChangeDetail: String, Equatable, Sendable {
    case pathMissing
    case notADirectory
    case deviceIDDiffer
    case inodeDiffer
    case logicalBytesDiffer
    case modifiedSecondsDiffer
    case modifiedNanosecondsDiffer
    case bundleIdentifierRereadMismatch
}

enum AppFootprintNotCheckedReason: Equatable, Sendable {
    case associationAnalysisDisabled
    case awaitingReports
}

struct AppFootprintCoverageGap: Equatable, Sendable {
    enum Kind: String, Sendable {
        case inaccessibleScope
        case partialScope
        case skippedScope
        case cancelledScope
        case completenessIssue
        case policySkip
    }

    let scopeID: String
    let rootPath: String
    let kind: Kind
    let issueCount: Int
    let samplePaths: [String]
}

// MARK: - 身份复验探针（一次 lstat＋一次 Bundle Identifier 复读；注入）

struct AppFootprintIdentityProbe: Equatable, Sendable {
    let exists: Bool
    let isDirectory: Bool
    let deviceID: UInt64
    let inode: UInt64
    let logicalBytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let bundleIdentifierReread: String?

    init(exists: Bool, isDirectory: Bool, deviceID: UInt64, inode: UInt64,
         logicalBytes: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64,
         bundleIdentifierReread: String?) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.deviceID = deviceID
        self.inode = inode
        self.logicalBytes = logicalBytes
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.bundleIdentifierReread = bundleIdentifierReread
    }

    init(applicationPath: String, expectedBundleIdentifier: String?) {
        var info = stat()
        let status = applicationPath.withCString { Darwin.lstat($0, &info) }
        if status != 0 {
            self.init(exists: false, isDirectory: false, deviceID: 0, inode: 0,
                      logicalBytes: 0, modifiedSeconds: 0, modifiedNanoseconds: 0,
                      bundleIdentifierReread: nil)
            return
        }
        let type = info.st_mode & mode_t(S_IFMT)
        let reread = Bundle(url: URL(fileURLWithPath: applicationPath, isDirectory: true))?.bundleIdentifier
        self.init(
            exists: true,
            isDirectory: type == mode_t(S_IFDIR),
            deviceID: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            logicalBytes: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            bundleIdentifierReread: reread
        )
    }

    /// nil＝身份可验证；非 nil＝首个不一致点（冻结 §2.2 P1b，字段集见修订 R1）。
    func firstMismatch(against application: InstalledApplication) -> AppFootprintIdentityChangeDetail? {
        guard exists else { return .pathMissing }
        guard isDirectory else { return .notADirectory }
        guard deviceID == application.deviceID else { return .deviceIDDiffer }
        guard inode == application.inode else { return .inodeDiffer }
        guard logicalBytes == application.logicalBytes else { return .logicalBytesDiffer }
        guard modifiedSeconds == application.modifiedSeconds else { return .modifiedSecondsDiffer }
        guard modifiedNanoseconds == application.modifiedNanoseconds else { return .modifiedNanosecondsDiffer }
        guard bundleIdentifierReread == application.bundleIdentifier else { return .bundleIdentifierRereadMismatch }
        return nil
    }
}

struct AppFootprintIdentityProbing: Sendable {
    let makeProbe: @Sendable (InstalledApplication) -> AppFootprintIdentityProbe

    static let live = AppFootprintIdentityProbing { application in
        AppFootprintIdentityProbe(
            applicationPath: application.path,
            expectedBundleIdentifier: application.bundleIdentifier
        )
    }
}

// MARK: - 去重（冻结 §1.3；仅作用于 L1＋L2 合计集合）

struct AppFootprintSumItem: Equatable, Sendable {
    let tier: AppFootprintTier
    let path: String
    let allocatedBytes: Int64
    let deviceID: UInt64
    let inode: UInt64
}

struct AppFootprintDedupExclusion: Equatable, Sendable {
    enum Cause: String, Sendable {
        case duplicatePath
        case duplicateFileIdentity
        case nestedPath
    }

    let excludedPath: String
    let keptPath: String
    let cause: Cause
}

// MARK: - 报告模型

struct AppFootprintResidueEntry: Equatable, Sendable, Identifiable {
    let id: String
    let kind: AppResidueKind
    let path: String
    let allocatedBytes: Int64
}

struct AppFootprintAssociationEntry: Equatable, Sendable, Identifiable {
    let id: String
    let kind: AppAssociationKind
    let path: String
    let isInsideApplicationBundle: Bool
}

struct AppFootprintReport: Equatable, Sendable {
    let applicationID: String
    let applicationName: String
    let bundleIdentifier: String?
    let computedAt: Date
    let identityVerified: Bool
    let completeness: AppFootprintCompleteness

    let applicationBytes: Int64?
    let residueEntries: [AppFootprintResidueEntry]
    let residueBytes: Int64?
    let dedupExclusions: [AppFootprintDedupExclusion]
    let associationEntries: [AppFootprintAssociationEntry]
    let coverageGaps: [AppFootprintCoverageGap]
    let ignoredResidueCount: Int
    let sumOverflowDetected: Bool

    /// 「已知占用合计」＝L1＋L2 去重后；无法安全判断或检出溢出时为 nil（冻结 §1.1／§1.3.5）。
    var knownTotalBytes: Int64? {
        guard let applicationBytes, let residueBytes else { return nil }
        let (sum, overflow) = applicationBytes.addingReportingOverflow(residueBytes)
        guard !overflow, sum >= 0 else { return nil }
        return sum
    }
}

// MARK: - 引擎

struct AppFootprintEngineInput: Sendable {
    let application: InstalledApplication
    let applicationScanFailed: Bool
    let residueReport: ResidueScanReport?
    let associationReport: AppAssociationReport?
    let associationAnalysisEnabled: Bool
    let selectableResidues: [AppResidueCandidate]
    let ignoredResidueCount: Int
    let applicationCoverage: [ScanCoverage]
}

enum AppFootprintEngine {
    static func build(
        input: AppFootprintEngineInput,
        identityProbe: AppFootprintIdentityProbe,
        clock: () -> Date = { Date() }
    ) -> AppFootprintReport {
        // P1a：Bundle Identifier 缺失／非法
        if let restriction = ScanRules.bundleIdentifierRestriction(input.application.bundleIdentifier) {
            return cannotJudge(
                input: input,
                reason: restriction == .missingBundleIdentifier ? .missingBundleIdentifier : .invalidBundleIdentifier,
                clock: clock
            )
        }

        // P1b：应用身份复验（字段集见冻结修订 R1）
        if let mismatch = identityProbe.firstMismatch(against: input.application) {
            return cannotJudge(
                input: input,
                reason: .applicationIdentityChanged(mismatch),
                clock: clock
            )
        }

        // P1c：扫描结果损坏
        if input.applicationScanFailed {
            return cannotJudge(
                input: input,
                reason: .scanResultDamaged(detail: String(localized: "应用扫描阶段失败，本轮没有可安全使用的扫描结果。")),
                clock: clock
            )
        }

        // P4（先于 P3 的报告在场性求值仅用于本分支；P2→P3→P4 判定序由上方命中顺序保证）：
        // 关联分析关闭时 associationReport 为 notSelected 空报告，属 P3。
        let residueAvailable = input.residueReport != nil
        let associationAvailable = input.associationReport != nil

        // P2：任一声明范围降级（层容量与合计照常显示其可靠部分，冻结 §2.3）
        let coverage = input.applicationCoverage
            + (input.residueReport?.coverage ?? [])
            + (input.associationReport?.coverage ?? [])
        let gaps = Self.coverageGaps(in: coverage)

        let measured = Self.measuredTiers(input: input)

        if !gaps.isEmpty {
            return AppFootprintReport(
                applicationID: input.application.id,
                applicationName: input.application.name,
                bundleIdentifier: input.application.bundleIdentifier,
                computedAt: clock(),
                identityVerified: true,
                completeness: .partial(gaps: gaps),
                applicationBytes: input.application.allocatedBytes,
                residueEntries: measured.residueEntries,
                residueBytes: measured.residueBytes,
                dedupExclusions: measured.exclusions,
                associationEntries: Self.associationEntries(input.associationReport),
                coverageGaps: gaps,
                ignoredResidueCount: input.ignoredResidueCount,
                sumOverflowDetected: measured.overflow
            )
        }

        // P3：关联分析关闭
        if !input.associationAnalysisEnabled {
            return AppFootprintReport(
                applicationID: input.application.id,
                applicationName: input.application.name,
                bundleIdentifier: input.application.bundleIdentifier,
                computedAt: clock(),
                identityVerified: true,
                completeness: .notChecked(reason: .associationAnalysisDisabled),
                applicationBytes: input.application.allocatedBytes,
                residueEntries: measured.residueEntries,
                residueBytes: measured.residueBytes,
                dedupExclusions: measured.exclusions,
                associationEntries: [],
                coverageGaps: [],
                ignoredResidueCount: input.ignoredResidueCount,
                sumOverflowDetected: measured.overflow
            )
        }

        // P4：全景尚未运行（报告未齐）
        if !residueAvailable || !associationAvailable {
            return AppFootprintReport(
                applicationID: input.application.id,
                applicationName: input.application.name,
                bundleIdentifier: input.application.bundleIdentifier,
                computedAt: clock(),
                identityVerified: true,
                completeness: .notChecked(reason: .awaitingReports),
                applicationBytes: input.application.allocatedBytes,
                residueEntries: [],
                residueBytes: nil,
                dedupExclusions: [],
                associationEntries: [],
                coverageGaps: [],
                ignoredResidueCount: input.ignoredResidueCount,
                sumOverflowDetected: false
            )
        }

        // P5：完整检查——全部声明范围完成且身份可验证
        return AppFootprintReport(
            applicationID: input.application.id,
            applicationName: input.application.name,
            bundleIdentifier: input.application.bundleIdentifier,
            computedAt: clock(),
            identityVerified: true,
            completeness: .complete,
            applicationBytes: input.application.allocatedBytes,
            residueEntries: measured.residueEntries,
            residueBytes: measured.residueBytes,
            dedupExclusions: measured.exclusions,
            associationEntries: Self.associationEntries(input.associationReport),
            coverageGaps: [],
            ignoredResidueCount: input.ignoredResidueCount,
            sumOverflowDetected: measured.overflow
        )
    }

    // MARK: 覆盖缺口检测（冻结 §2.2 P2；供复查共用）

    static func coverageGaps(in coverage: [ScanCoverage]) -> [AppFootprintCoverageGap] {
        var gaps: [AppFootprintCoverageGap] = []
        for record in coverage {
            switch record.status {
            case .partial:
                gaps.append(Self.gap(record: record, kind: .partialScope))
            case .inaccessible:
                gaps.append(Self.gap(record: record, kind: .inaccessibleScope))
            case .skipped:
                gaps.append(Self.gap(record: record, kind: .skippedScope))
            case .cancelled:
                gaps.append(Self.gap(record: record, kind: .cancelledScope))
            case .notStarted, .inProgress, .completed, .notSelected, .notFound:
                break
            }
            let policySkips = record.issues.filter { $0.kind == .policySkip }
            if !policySkips.isEmpty {
                gaps.append(AppFootprintCoverageGap(
                    scopeID: record.scope.id,
                    rootPath: record.scope.rootPath,
                    kind: .policySkip,
                    issueCount: policySkips.count,
                    samplePaths: policySkips.compactMap(\.path)
                ))
            }
            let completenessIssues = record.issues.filter { $0.affectsCompleteness }
            if !completenessIssues.isEmpty {
                gaps.append(AppFootprintCoverageGap(
                    scopeID: record.scope.id,
                    rootPath: record.scope.rootPath,
                    kind: .completenessIssue,
                    issueCount: completenessIssues.count,
                    samplePaths: completenessIssues.compactMap(\.path)
                ))
            }
        }
        return gaps
    }

    private static func gap(record: ScanCoverage, kind: AppFootprintCoverageGap.Kind) -> AppFootprintCoverageGap {
        AppFootprintCoverageGap(
            scopeID: record.scope.id,
            rootPath: record.scope.rootPath,
            kind: kind,
            issueCount: max(record.issueCount, 1),
            samplePaths: record.issues.compactMap(\.path)
        )
    }

    // MARK: 去重求和（冻结 §1.3：D1 路径→D2 设备号+inode→D3 父子；确定性输入序）

    struct DedupResult: Sendable {
        let accepted: [AppFootprintSumItem]
        let total: Int64?
        let exclusions: [AppFootprintDedupExclusion]
        let overflow: Bool
    }

    static func deduplicatedSum(items: [AppFootprintSumItem]) -> DedupResult {
        // 确定性输入序：L1 在前，其余按路径字典序升序（父路径恒先于子路径）。
        let ordered = items.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier == .applicationBundle }
            return lhs.path < rhs.path
        }

        var accepted: [AppFootprintSumItem] = []
        var acceptedPaths: [String] = []
        var firstPathByIdentity: [String: String] = [:]
        var exclusions: [AppFootprintDedupExclusion] = []

        for item in ordered {
            guard item.allocatedBytes >= 0 else {
                return DedupResult(accepted: [], total: nil, exclusions: exclusions, overflow: true)
            }
            // D1 重复来源（同规范化路径）
            if let kept = acceptedPaths.first(where: { $0 == item.path }) {
                exclusions.append(AppFootprintDedupExclusion(
                    excludedPath: item.path, keptPath: kept, cause: .duplicatePath))
                continue
            }
            let identityKey = "\(item.deviceID)|\(item.inode)"
            // D2 硬链接（顶层同设备号＋inode）
            if let kept = firstPathByIdentity[identityKey] {
                exclusions.append(AppFootprintDedupExclusion(
                    excludedPath: item.path, keptPath: kept, cause: .duplicateFileIdentity))
                continue
            }
            // D3 父子路径（组件边界前缀；子项容量已含于父项）
            if let ancestor = acceptedPaths.first(where: { item.path.hasPrefix($0 + "/") }) {
                exclusions.append(AppFootprintDedupExclusion(
                    excludedPath: item.path, keptPath: ancestor, cause: .nestedPath))
                continue
            }
            accepted.append(item)
            acceptedPaths.append(item.path)
            firstPathByIdentity[identityKey] = item.path
        }

        var total: Int64 = 0
        var overflow = false
        for item in accepted {
            let (sum, didOverflow) = total.addingReportingOverflow(item.allocatedBytes)
            if didOverflow || sum < 0 {
                overflow = true
                break
            }
            total = sum
        }
        return DedupResult(
            accepted: accepted,
            total: overflow ? nil : total,
            exclusions: exclusions,
            overflow: overflow
        )
    }

    // MARK: 私有工具

    private struct MeasuredTiers: Sendable {
        let residueEntries: [AppFootprintResidueEntry]
        let residueBytes: Int64?
        let exclusions: [AppFootprintDedupExclusion]
        let overflow: Bool
    }

    private static func measuredTiers(input: AppFootprintEngineInput) -> MeasuredTiers {
        let items = sumItems(application: input.application, residues: input.selectableResidues)
        let dedup = deduplicatedSum(items: items)
        var residueBytes: Int64 = 0
        for item in dedup.accepted where item.tier == .userResidue {
            let (sum, overflow) = residueBytes.addingReportingOverflow(item.allocatedBytes)
            if overflow || sum < 0 {
                return MeasuredTiers(
                    residueEntries: input.selectableResidues.map(residueEntry),
                    residueBytes: nil,
                    exclusions: dedup.exclusions,
                    overflow: true
                )
            }
            residueBytes = sum
        }
        return MeasuredTiers(
            residueEntries: input.selectableResidues.map(residueEntry),
            residueBytes: dedup.overflow ? nil : residueBytes,
            exclusions: dedup.exclusions,
            overflow: dedup.overflow
        )
    }

    private static func checkedSum(partial: Int64, _ next: Int64) -> Int64 {
        let (sum, overflow) = partial.addingReportingOverflow(next)
        return overflow ? 0 : sum
    }

    private static func sumItems(
        application: InstalledApplication,
        residues: [AppResidueCandidate]
    ) -> [AppFootprintSumItem] {
        [AppFootprintSumItem(
            tier: .applicationBundle,
            path: URL(fileURLWithPath: application.path).standardizedFileURL.path,
            allocatedBytes: application.allocatedBytes,
            deviceID: application.deviceID,
            inode: application.inode
        )] + residues.map { residue in
            AppFootprintSumItem(
                tier: .userResidue,
                path: URL(fileURLWithPath: residue.path).standardizedFileURL.path,
                allocatedBytes: residue.allocatedBytes,
                deviceID: residue.deviceID,
                inode: residue.inode
            )
        }
    }

    private static func residueEntry(_ residue: AppResidueCandidate) -> AppFootprintResidueEntry {
        AppFootprintResidueEntry(
            id: residue.id,
            kind: residue.kind,
            path: residue.path,
            allocatedBytes: residue.allocatedBytes
        )
    }

    private static func associationEntries(_ report: AppAssociationReport?) -> [AppFootprintAssociationEntry] {
        (report?.items ?? []).map { item in
            AppFootprintAssociationEntry(
                id: item.id,
                kind: item.kind,
                path: item.path,
                isInsideApplicationBundle: item.isInsideApplicationBundle
            )
        }
    }

    private static func cannotJudge(
        input: AppFootprintEngineInput,
        reason: AppFootprintCannotJudgeReason,
        clock: () -> Date
    ) -> AppFootprintReport {
        AppFootprintReport(
            applicationID: input.application.id,
            applicationName: input.application.name,
            bundleIdentifier: input.application.bundleIdentifier,
            computedAt: clock(),
            identityVerified: false,
            completeness: .cannotJudge(reason: reason),
            applicationBytes: nil,
            residueEntries: [],
            residueBytes: nil,
            dedupExclusions: [],
            associationEntries: [],
            coverageGaps: [],
            ignoredResidueCount: input.ignoredResidueCount,
            sumOverflowDetected: false
        )
    }
}
