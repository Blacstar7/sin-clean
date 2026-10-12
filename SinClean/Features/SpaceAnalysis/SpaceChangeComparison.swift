import CryptoKit
import Foundation

// SC-PD2 空间变化追踪：纯函数对比引擎。
// 冻结语义：work/SC-PD2-frozen-semantics.md（§3 指纹、§6 可比性求值序、§7 delta/排序/
// 阈值/tie-breaker、§10 七态派生）。无 I/O、无扫描器依赖、无网络、无时间依赖——
// 同一输入重复求值输出全等。

// MARK: - 范围指纹（冻结 §3）

enum SpaceChangeFingerprint {
    /// SHA-256(盐十六进制 + U+001F + 规范化路径按 U+001F 连接) 的小写十六进制。
    /// 路径含 U+001F 或为空 → 返回 nil（按数据异常拒绝）。
    static func compute(normalizedScopes: [String], saltHex: String) -> String? {
        guard !normalizedScopes.isEmpty else { return nil }
        for path in normalizedScopes where path.isEmpty || path.contains("\u{1F}") {
            return nil
        }
        guard saltHex.allSatisfy({ character in
            (character >= "0" && character <= "9") || (character >= "a" && character <= "f")
        }) else { return nil }
        let sorted = normalizedScopes.sorted {
            Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
        }
        let input = saltHex + "\u{1F}" + sorted.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 不可比较原因（冻结 §6.2）

enum SpaceChangeNotComparableReason: String, Hashable, Sendable {
    case currentScanCancelled = "本次扫描未完成"
    case currentDataInconsistent = "本次结果未通过数据校验"
    case recordWriteFailed = "本次结果未能记录"
    case scopeSetChanged = "扫描范围与基准不同"
    case ruleVersionChanged = "分类规则版本与基准不同"
    case capacitySemanticsChanged = "容量统计口径与基准不同"
    case coverageIncomplete = "覆盖状态与基准不同"
    case dataAnomaly = "数据异常"

    /// 面向用户的人话（不得输出任何增减数字）。
    var explanation: String {
        switch self {
        case .currentScanCancelled:
            String(localized: "本次扫描已取消，未生成完整结果，因此暂不与历史比较。完成一次扫描后再查看变化。")
        case .currentDataInconsistent:
            String(localized: "本次扫描结果未通过数据一致性校验，为避免误导，暂不与历史比较。可以重新扫描后再看。")
        case .recordWriteFailed:
            String(localized: "本次结果未能写入本地记录（写入失败），因此暂无可靠的对比基准。下次成功扫描后会自动恢复。")
        case .scopeSetChanged:
            String(localized: "本次扫描范围与最近一次记录的范围不同，直接比较会误导。用同一范围组合再扫描一次即可比较。")
        case .ruleVersionChanged:
            String(localized: "最近一次记录使用的分类规则版本与当前不同，类别口径不一致，暂不可比较。完成一次新的扫描后即可恢复。")
        case .capacitySemanticsChanged:
            String(localized: "最近一次记录的容量统计口径与当前不同，暂不可比较。完成一次新的扫描后即可恢复。")
        case .coverageIncomplete:
            String(localized: "本次或基准扫描存在未统计目录，覆盖范围不一致，暂不可比较。本次与基准都完整读取后才能公平比较。")
        case .dataAnomaly:
            String(localized: "对比计算出现数据异常，为避免误导，暂不显示变化。")
        }
    }
}

// MARK: - 七态（冻结 §10）

enum SpaceChangeDamagedKind: String, Hashable, Sendable {
    case corrupt = "历史记录损坏"
    case migrationFailed = "记录由更新版本生成"
    case saltMissing = "本地盐缺失"

    var explanation: String {
        switch self {
        case .corrupt:
            String(localized: "空间变化记录文件无法读取或校验失败。原文件已保留、不会被清除；可在设置的「空间变化记录」中确认清除后重新开始。")
        case .migrationFailed:
            String(localized: "空间变化记录由更新版本的 Sin Clean 生成，本版本无法安全读取。原文件已保留；如需在本版本继续记录，可在设置中确认清除。")
        case .saltMissing:
            String(localized: "本地随机盐缺失，无法核对范围可比性。记录文件已保留；可在设置的「空间变化记录」中确认清除后重新开始。")
        }
    }
}

enum SpaceChangeUIState: Equatable, Hashable, Sendable {
    case first
    case growth
    case shrink
    case noChange
    case notComparable(reason: SpaceChangeNotComparableReason)
    case recordingDisabled(retainedCount: Int)
    case damaged(kind: SpaceChangeDamagedKind)

    var title: String {
        switch self {
        case .first: String(localized: "首次记录")
        case .growth: String(localized: "相比上次增长")
        case .shrink: String(localized: "相比上次缩小")
        case .noChange: String(localized: "相比上次无明显变化")
        case .notComparable: String(localized: "暂不可比较")
        case .recordingDisabled: String(localized: "记录已关闭")
        case .damaged: String(localized: "记录异常")
        }
    }
}

// MARK: - 类别变化行（冻结 §7）

struct SpaceChangeCategoryDelta: Identifiable, Hashable, Sendable {
    var id: String { categoryID.rawValue }

    let categoryID: SpaceAnalysisDiagnosisCategoryID
    /// 当前 − 基准（带符号）。
    let delta: Int64
    let currentBytes: Int64
    let baselineBytes: Int64
}

// MARK: - 评估结果

struct SpaceChangeEvaluation: Hashable, Sendable {
    let state: SpaceChangeUIState
    let totalDelta: Int64?
    let currentTotalBytes: Int64?
    let baselineTotalBytes: Int64?
    /// 增长前三（delta 降序，tie-breaker 类别 ID 字典序升序）。
    let growthTop: [SpaceChangeCategoryDelta]
    /// 缩小前三（|delta| 降序，同上 tie-breaker）。
    let shrinkTop: [SpaceChangeCategoryDelta]
    let currentFinishedAt: Date?
    let baselineCreatedAt: Date?
    let snapshotCount: Int
    let baselineCoverageComplete: Bool?
    let capacityIsUpperBound: Bool
    let datalessPlaceholderCount: Int

    /// 可比三态才有数字。
    var presentsNumbers: Bool {
        switch state {
        case .growth, .shrink, .noChange: true
        default: false
        }
    }

    static let empty = SpaceChangeEvaluation(
        state: .first,
        totalDelta: nil,
        currentTotalBytes: nil,
        baselineTotalBytes: nil,
        growthTop: [],
        shrinkTop: [],
        currentFinishedAt: nil,
        baselineCreatedAt: nil,
        snapshotCount: 0,
        baselineCoverageComplete: nil,
        capacityIsUpperBound: false,
        datalessPlaceholderCount: 0
    )
}

// MARK: - 引擎（纯函数）

enum SpaceChangeComparisonEngine {
    static let topLimit = 3

    // MARK: 快照构建（记录路径，冻结 §5）

    /// 由同一轮扫描结果构建快照；不可记录态（取消／不一致／守恒失配／负值）返回 nil。
    static func buildSnapshot(
        outcome: SpaceAnalysisScanOutcome,
        report: SpaceAnalysisDiagnosisReport,
        scopeFingerprint: String
    ) -> SpaceChangeSnapshot? {
        guard SpaceChangeHistoryStore.isRecordableReportState(report.state) else { return nil }
        guard !outcome.summary.cancelled else { return nil }

        var bytesByID: [SpaceAnalysisDiagnosisCategoryID: Int64] = [:]
        var countByID: [SpaceAnalysisDiagnosisCategoryID: Int] = [:]
        for category in report.categories {
            bytesByID[category.categoryID] = category.bytes
            countByID[category.categoryID] = category.entryCount
        }
        let categories = SpaceAnalysisDiagnosisCategoryID.allCases.map { id in
            SpaceChangeCategoryMeasurement(
                id: id.rawValue,
                bytes: bytesByID[id] ?? 0,
                entryCount: countByID[id] ?? 0
            )
        }
        let total = outcome.summary.scannedTotalBytes
        var recomputed: Int64 = 0
        for category in categories {
            guard category.bytes >= 0 else { return nil }
            let (sum, overflow) = recomputed.addingReportingOverflow(category.bytes)
            guard !overflow else { return nil }
            recomputed = sum
        }
        guard recomputed == total, total >= 0 else { return nil }

        return SpaceChangeSnapshot(
            createdAtEpochSeconds: outcome.summary.finishedAt.timeIntervalSince1970,
            scopeFingerprint: scopeFingerprint,
            ruleVersion: SpaceChangeSemantics.ruleVersion,
            capacitySemanticsVersion: SpaceChangeSemantics.capacitySemanticsVersion,
            totalBytes: total,
            categories: categories,
            coverageComplete: outcome.summary.unreadableDirectoryCount == 0 && !outcome.summary.cancelled,
            unreadableDirectoryCount: outcome.summary.unreadableDirectoryCount,
            capacityIsUpperBound: outcome.deduplication.capacityIsUpperBound,
            datalessPlaceholderCount: outcome.deduplication.datalessPlaceholderCount
        )
    }

    // MARK: 七态与 delta（冻结 §6.2 求值序／§7 算法）

    static func evaluate(
        outcome: SpaceAnalysisScanOutcome?,
        report: SpaceAnalysisDiagnosisReport?,
        recordingEnabled: Bool,
        storeCondition: SpaceChangeStoreCondition,
        lastFailedStamp: String?,
        snapshots: [SpaceChangeSnapshot],
        saltHex: String?
    ) -> SpaceChangeEvaluation {
        // 1. 存储层损坏／迁移失败／盐缺失（§6.2.1）
        if storeCondition != .ready {
            let kind: SpaceChangeDamagedKind
            switch storeCondition {
            case .corrupt: kind = .corrupt
            case .migrationFailed: kind = .migrationFailed
            case .saltMissing: kind = .saltMissing
            case .ready: kind = .corrupt
            }
            return damagedEvaluation(kind: kind, snapshots: snapshots)
        }

        // 2. 记录开关关闭（§6.2.2）：不比较、不显示数字（§9.1）。
        if !recordingEnabled {
            return SpaceChangeEvaluation(
                state: .recordingDisabled(retainedCount: snapshots.count),
                totalDelta: nil,
                currentTotalBytes: nil,
                baselineTotalBytes: nil,
                growthTop: [],
                shrinkTop: [],
                currentFinishedAt: outcome?.summary.finishedAt,
                baselineCreatedAt: nil,
                snapshotCount: snapshots.count,
                baselineCoverageComplete: nil,
                capacityIsUpperBound: outcome?.deduplication.capacityIsUpperBound ?? false,
                datalessPlaceholderCount: outcome?.deduplication.datalessPlaceholderCount ?? 0
            )
        }

        // 3. 无当前结果（§6.2.3）
        guard let outcome, let report else { return .empty }

        // 4. 本次诊断不一致（§6.2.4）
        if case .inconsistent = report.state {
            return notComparableEvaluation(
                .currentDataInconsistent, outcome: outcome, snapshots: snapshots
            )
        }

        // 5. 本次已取消（§6.2.5）
        if outcome.summary.cancelled {
            return notComparableEvaluation(
                .currentScanCancelled, outcome: outcome, snapshots: snapshots
            )
        }

        let roots = SpaceChangeHistoryStore.scopeRoots(of: outcome)
        let currentStampComponents: (fingerprint: String, total: Int64)?
        if let saltHex, let fingerprint = SpaceChangeFingerprint.compute(normalizedScopes: roots, saltHex: saltHex) {
            currentStampComponents = (fingerprint, outcome.summary.scannedTotalBytes)
        } else {
            currentStampComponents = nil
        }
        let currentStamp = currentStampComponents.map {
            "\(outcome.summary.finishedAt.timeIntervalSince1970)|\($0.fingerprint)|\($0.total)"
        }

        // 6. 本轮记录写入失败（§6.2.6，按失败戳精确匹配当前扫描）
        if let currentStamp, let lastFailedStamp, currentStamp == lastFailedStamp {
            return notComparableEvaluation(
                .recordWriteFailed, outcome: outcome, snapshots: snapshots
            )
        }

        // 7. 对比基准＝最新一条且去重戳 ≠ 当前扫描（§6.1）
        let baseline = snapshots.last { $0.dedupeStamp != currentStamp }
        guard let baseline else {
            return SpaceChangeEvaluation(
                state: .first,
                totalDelta: nil,
                currentTotalBytes: outcome.summary.scannedTotalBytes,
                baselineTotalBytes: nil,
                growthTop: [],
                shrinkTop: [],
                currentFinishedAt: outcome.summary.finishedAt,
                baselineCreatedAt: nil,
                snapshotCount: snapshots.count,
                baselineCoverageComplete: nil,
                capacityIsUpperBound: outcome.deduplication.capacityIsUpperBound,
                datalessPlaceholderCount: outcome.deduplication.datalessPlaceholderCount
            )
        }

        // 8–10. 指纹／规则版本／容量口径（§6.2.8–10）
        if let currentStampComponents {
            if currentStampComponents.fingerprint != baseline.scopeFingerprint {
                return notComparableEvaluation(
                    .scopeSetChanged, outcome: outcome, snapshots: snapshots, baseline: baseline
                )
            }
        } else {
            return notComparableEvaluation(
                .dataAnomaly, outcome: outcome, snapshots: snapshots, baseline: baseline
            )
        }
        if baseline.ruleVersion != SpaceChangeSemantics.ruleVersion {
            return notComparableEvaluation(
                .ruleVersionChanged, outcome: outcome, snapshots: snapshots, baseline: baseline
            )
        }
        if baseline.capacitySemanticsVersion != SpaceChangeSemantics.capacitySemanticsVersion {
            return notComparableEvaluation(
                .capacitySemanticsChanged, outcome: outcome, snapshots: snapshots, baseline: baseline
            )
        }

        // 11. 覆盖状态（§6.2.11）
        if outcome.summary.unreadableDirectoryCount > 0 || !baseline.coverageComplete {
            return notComparableEvaluation(
                .coverageIncomplete, outcome: outcome, snapshots: snapshots, baseline: baseline
            )
        }

        // 12. 可比：delta（§7）
        return comparableEvaluation(outcome: outcome, report: report, baseline: baseline, snapshots: snapshots)
    }

    private static func damagedEvaluation(
        kind: SpaceChangeDamagedKind,
        snapshots: [SpaceChangeSnapshot]
    ) -> SpaceChangeEvaluation {
        SpaceChangeEvaluation(
            state: .damaged(kind: kind),
            totalDelta: nil,
            currentTotalBytes: nil,
            baselineTotalBytes: nil,
            growthTop: [],
            shrinkTop: [],
            currentFinishedAt: nil,
            baselineCreatedAt: nil,
            snapshotCount: snapshots.count,
            baselineCoverageComplete: nil,
            capacityIsUpperBound: false,
            datalessPlaceholderCount: 0
        )
    }

    private static func notComparableEvaluation(
        _ reason: SpaceChangeNotComparableReason,
        outcome: SpaceAnalysisScanOutcome,
        snapshots: [SpaceChangeSnapshot],
        baseline: SpaceChangeSnapshot? = nil
    ) -> SpaceChangeEvaluation {
        SpaceChangeEvaluation(
            state: .notComparable(reason: reason),
            totalDelta: nil,
            currentTotalBytes: nil,
            baselineTotalBytes: nil,
            growthTop: [],
            shrinkTop: [],
            currentFinishedAt: outcome.summary.finishedAt,
            baselineCreatedAt: baseline?.createdAt,
            snapshotCount: snapshots.count,
            baselineCoverageComplete: baseline?.coverageComplete,
            capacityIsUpperBound: outcome.deduplication.capacityIsUpperBound,
            datalessPlaceholderCount: outcome.deduplication.datalessPlaceholderCount
        )
    }

    private static func comparableEvaluation(
        outcome: SpaceAnalysisScanOutcome,
        report: SpaceAnalysisDiagnosisReport,
        baseline: SpaceChangeSnapshot,
        snapshots: [SpaceChangeSnapshot]
    ) -> SpaceChangeEvaluation {
        var currentBytes: [SpaceAnalysisDiagnosisCategoryID: Int64] = [:]
        for category in report.categories {
            currentBytes[category.categoryID] = category.bytes
        }
        var baselineBytes: [SpaceAnalysisDiagnosisCategoryID: Int64] = [:]
        for category in baseline.categories {
            if let id = SpaceAnalysisDiagnosisCategoryID(rawValue: category.id) {
                baselineBytes[id] = category.bytes
            }
        }

        let (totalDelta, totalOverflow) =
            outcome.summary.scannedTotalBytes.subtractingReportingOverflow(baseline.totalBytes)
        guard !totalOverflow else {
            return notComparableEvaluation(
                .dataAnomaly, outcome: outcome, snapshots: snapshots, baseline: baseline
            )
        }

        var deltas: [SpaceChangeCategoryDelta] = []
        for id in SpaceAnalysisDiagnosisCategoryID.allCases {
            let current = currentBytes[id] ?? 0
            let base = baselineBytes[id] ?? 0
            let (delta, overflow) = current.subtractingReportingOverflow(base)
            guard !overflow else {
                return notComparableEvaluation(
                    .dataAnomaly, outcome: outcome, snapshots: snapshots, baseline: baseline
                )
            }
            deltas.append(SpaceChangeCategoryDelta(
                categoryID: id,
                delta: delta,
                currentBytes: current,
                baselineBytes: base
            ))
        }

        let growthTop = deltas
            .filter { $0.delta > 0 }
            .sorted { lhs, rhs in
                if lhs.delta != rhs.delta { return lhs.delta > rhs.delta }
                return lhs.categoryID.rawValue < rhs.categoryID.rawValue
            }
            .prefix(topLimit)
        let shrinkTop = deltas
            .filter { $0.delta < 0 }
            .sorted { lhs, rhs in
                if lhs.delta != rhs.delta { return lhs.delta < rhs.delta }
                return lhs.categoryID.rawValue < rhs.categoryID.rawValue
            }
            .prefix(topLimit)

        let state: SpaceChangeUIState
        if totalDelta > 0 {
            state = .growth
        } else if totalDelta < 0 {
            state = .shrink
        } else {
            state = .noChange
        }

        return SpaceChangeEvaluation(
            state: state,
            totalDelta: totalDelta,
            currentTotalBytes: outcome.summary.scannedTotalBytes,
            baselineTotalBytes: baseline.totalBytes,
            growthTop: Array(growthTop),
            shrinkTop: Array(shrinkTop),
            currentFinishedAt: outcome.summary.finishedAt,
            baselineCreatedAt: baseline.createdAt,
            snapshotCount: snapshots.count,
            baselineCoverageComplete: baseline.coverageComplete,
            capacityIsUpperBound: outcome.deduplication.capacityIsUpperBound,
            datalessPlaceholderCount: outcome.deduplication.datalessPlaceholderCount
        )
    }
}
