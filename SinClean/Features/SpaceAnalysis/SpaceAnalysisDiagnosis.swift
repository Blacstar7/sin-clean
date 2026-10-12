import Foundation

// SC-PD1 存储去向诊断：只读派生层。
// 只消费同一轮 SpaceAnalysisScanOutcome，不调用扫描器、不做 I/O、不持久化；
// 分类规则、排他优先级、守恒与状态机的冻结值见 work/SC-PD1-frozen-semantics.md。

// MARK: - 类别（§1.1，顺序即类别 ID 字典序，供 tie-breaker）

enum SpaceAnalysisDiagnosisCategoryID: String, CaseIterable, Hashable, Sendable {
    case appsAndAppData
    case cachesAndLogs
    case communicationsAndContent
    case devicesAndDevelopment
    case installersAndArchives
    case otherScannedContent
    case userFiles

    var displayName: String {
        switch self {
        case .appsAndAppData: String(localized: "应用与应用数据")
        case .cachesAndLogs: String(localized: "缓存与日志")
        case .communicationsAndContent: String(localized: "通信与内容")
        case .devicesAndDevelopment: String(localized: "设备与开发")
        case .installersAndArchives: String(localized: "安装包与归档")
        case .otherScannedContent: String(localized: "其他已扫描内容")
        case .userFiles: String(localized: "用户文件")
        }
    }

    /// 冻结动作等级（§2）。
    var actionLevel: SpaceAnalysisDiagnosisActionLevel {
        switch self {
        case .userFiles, .installersAndArchives: .reviewInSinClean
        case .appsAndAppData, .cachesAndLogs, .communicationsAndContent, .devicesAndDevelopment: .manageInOriginApp
        case .otherScannedContent: .systemManaged
        }
    }

    /// 建议动作文案（只描述与指引，不生成候选、不自动勾选、不执行）。
    var actionAdvice: String {
        switch self {
        case .userFiles:
            String(localized: "这类是您自己保存的内容。可在下方「大文件」列表与「手动处理」面板逐项查看；默认不勾选，只有您逐项选择的项目才会被处理。")
        case .installersAndArchives:
            String(localized: "安装包与压缩归档通常是您主动下载的文件。可在下方「大文件」列表与「手动处理」面板逐项审阅；默认不勾选。")
        case .cachesAndLogs:
            String(localized: "缓存与日志由 macOS 与应用自行再生。建议在原应用或系统内管理；Sin Clean 不会代为清理。")
        case .communicationsAndContent:
            String(localized: "邮件与信息数据建议在「邮件」「信息」原应用内管理。此处只做容量归类与来源说明。")
        case .devicesAndDevelopment:
            String(localized: "设备备份与开发工具数据（如 Xcode、模拟器、Docker、虚拟机）建议在对应原工具内管理。此处只做容量归类。")
        case .appsAndAppData:
            String(localized: "应用本体与应用数据建议通过应用自身的卸载或设置管理。此处只做容量归类，不建议手动处理。")
        case .otherScannedContent:
            String(localized: "规则无法确认这些内容的归属（多位于系统管理的区域内）。不建议手动处理。")
        }
    }
}

// MARK: - 规则（§1.2，ruleID 冻结）

enum SpaceAnalysisDiagnosisRuleID: String, CaseIterable, Hashable, Sendable {
    // P1 缓存与日志
    case cacheDir = "cache-dir"
    case logsDir = "logs-dir"
    case crashDir = "crash-dir"
    // P2 通信与内容
    case mailLibrary = "mail-library"
    case messagesLibrary = "messages-library"
    // P3 设备与开发
    case mobilesyncDir = "mobilesync-dir"
    case deriveddataDir = "deriveddata-dir"
    case coresimulatorDir = "coresimulator-dir"
    case dockerContainerDir = "docker-container-dir"
    case xcodeDevDir = "xcode-dev-dir"
    case vmDiskExt = "vm-disk-ext"
    // P4 应用与应用数据
    case applicationsDir = "applications-dir"
    case appsupportDir = "appsupport-dir"
    case containersDir = "containers-dir"
    case packageBundle = "package-bundle"
    // P5 安装包与归档
    case installerArchiveExt = "installer-archive-ext"
    // P6 用户文件
    case userContent = "user-content"
    // P7 兜底
    case fallbackOther = "fallback-other"

    /// 归类原因的人话解释（证据展开区展示；不参与逻辑判定）。
    var explanation: String {
        switch self {
        case .cacheDir: String(localized: "位于名为 Caches 的缓存目录内（按路径组件精确匹配）")
        case .logsDir: String(localized: "位于名为 Logs 的日志目录内（按路径组件精确匹配）")
        case .crashDir: String(localized: "位于名为 CrashReporter 的崩溃报告目录内")
        case .mailLibrary: String(localized: "位于个人资料库的 Mail（邮件）数据目录内")
        case .messagesLibrary: String(localized: "位于个人资料库的 Messages（信息）数据目录内")
        case .mobilesyncDir: String(localized: "位于 MobileSync（设备备份）目录内")
        case .deriveddataDir: String(localized: "位于 DerivedData（Xcode 构建产物）目录内")
        case .coresimulatorDir: String(localized: "位于 CoreSimulator（模拟器）目录内")
        case .dockerContainerDir: String(localized: "位于 Docker 数据容器目录（com.docker.docker）内")
        case .xcodeDevDir: String(localized: "位于 Xcode 的归档或设备支持目录内")
        case .vmDiskExt: String(localized: "虚拟机磁盘文件（按文件类型）")
        case .applicationsDir: String(localized: "位于 Applications（应用程序）目录内")
        case .appsupportDir: String(localized: "位于 Application Support（应用支持）目录内")
        case .containersDir: String(localized: "位于 Containers／Group Containers（应用容器）目录内")
        case .packageBundle: String(localized: "应用包（.app 等包类型条目）")
        case .installerArchiveExt: String(localized: "安装包或压缩归档文件（按扩展名）")
        case .userContent: String(localized: "位于您选择的范围内、系统管理目录之外")
        case .fallbackOther: String(localized: "规则无法确认归属")
        }
    }
}

// MARK: - 动作等级（§2）

enum SpaceAnalysisDiagnosisActionLevel: String, Hashable, Sendable {
    case reviewInSinClean = "可在 Sin Clean 审阅"
    case manageInOriginApp = "建议在原应用管理"
    case systemManaged = "系统管理"

    var localizedTitle: String {
        switch self {
        case .reviewInSinClean: String(localized: "可在 Sin Clean 审阅")
        case .manageInOriginApp: String(localized: "建议在原应用管理")
        case .systemManaged: String(localized: "系统管理")
        }
    }
}

// MARK: - 类别结果

struct SpaceAnalysisDiagnosisCategory: Hashable, Identifiable, Sendable {
    var id: SpaceAnalysisDiagnosisCategoryID { categoryID }

    let categoryID: SpaceAnalysisDiagnosisCategoryID
    let bytes: Int64
    let entryCount: Int
    /// 命中规则及其条目数（结构性证据，界面文案不参与逻辑）。
    let ruleCounts: [SpaceAnalysisDiagnosisRuleID: Int]
    /// 样本路径（≤ 冻结上限，来自当前内存中的本轮结果）。
    let samplePaths: [String]

    /// 占已统计容量的比例；分母为 0 时为 0（空结果态下不展示）。
    func fraction(of denominator: Int64) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(bytes) / Double(denominator)
    }

    /// 归类原因文本：按冻结规则序拼接命中规则的解释。
    var explanationText: String {
        let ordered = SpaceAnalysisDiagnosisRuleID.allCases.compactMap { rule -> String? in
            guard let count = ruleCounts[rule], count > 0 else { return nil }
            return "\(rule.explanation)×\(count.formatted())"
        }
        return ordered.joined(separator: String(localized: "；"))
    }
}

// MARK: - 状态机（§4）

enum SpaceAnalysisDiagnosisInconsistencyReason: String, Hashable, Sendable {
    case conservation
    case overflow
    case negative
}

enum SpaceAnalysisDiagnosisState: Equatable, Hashable, Sendable {
    case noData
    case emptyResult
    case inconsistent(reason: SpaceAnalysisDiagnosisInconsistencyReason)
    case cancelled
    case partial
    case complete

    var title: String {
        switch self {
        case .noData: String(localized: "尚未扫描")
        case .emptyResult: String(localized: "未统计到容量")
        case .inconsistent: String(localized: "诊断数据不一致")
        case .cancelled: String(localized: "已取消")
        case .partial: String(localized: "部分覆盖")
        case .complete: String(localized: "扫描完成")
        }
    }

    /// 不完整语义的状态不得出现「完整／全部」措辞。
    var isCompleteSemantics: Bool {
        if case .complete = self { return true }
        return false
    }
}

// MARK: - 诊断报告

struct SpaceAnalysisDiagnosisReport: Hashable, Sendable {
    let state: SpaceAnalysisDiagnosisState
    let denominatorBytes: Int64
    let scannedScopeCount: Int
    let unreadableDirectoryCount: Int
    let cancelled: Bool
    /// 全部呈现类别（bytes > 0 或 entryCount > 0），按冻结排序：字节降序、同值按类别 ID 字典序升序。
    let categories: [SpaceAnalysisDiagnosisCategory]
    /// 默认区 Top 3（§6；「其他已扫描内容」可正常进入，不隐藏）。
    let topCategories: [SpaceAnalysisDiagnosisCategory]
    /// 叠加标志：最大类别占比 ≥ 50%。
    let hasProminentSource: Bool
    let startedAt: Date?
    let finishedAt: Date?
    // 精度口径传播（SC-3.4 冻结措辞）
    let precisionNote: String
    let hardLinkNote: String?
    let datalessNote: String?
    let datalessPlaceholderCount: Int
    let capacityIsUpperBound: Bool

    /// 仅这三个主状态呈现类别数字（§4）。
    var presentsNumbers: Bool {
        switch state {
        case .complete, .partial, .cancelled: true
        default: false
        }
    }

    static let noData = SpaceAnalysisDiagnosisReport(
        state: .noData,
        denominatorBytes: 0,
        scannedScopeCount: 0,
        unreadableDirectoryCount: 0,
        cancelled: false,
        categories: [],
        topCategories: [],
        hasProminentSource: false,
        startedAt: nil,
        finishedAt: nil,
        precisionNote: SpaceAnalysisDeduplicationSummary.empty.precisionNote,
        hardLinkNote: nil,
        datalessNote: nil,
        datalessPlaceholderCount: 0,
        capacityIsUpperBound: false
    )
}

// MARK: - 引擎（纯函数，无 I/O、无扫描器依赖）

enum SpaceAnalysisDiagnosisEngine {
    /// 冻结常量（§4／§6）。
    static let prominentThreshold = 0.5
    static let sampleLimit = 3
    static let topLimit = 3

    /// P3 虚拟机磁盘扩展名（常规文件类型规则，非厂商猜测）。
    static let vmDiskExtensions: Set<String> = ["vmdk", "vdi", "qcow2", "vhd"]
    /// P5 安装包与归档扩展名。
    static let installerArchiveExtensions: Set<String> = [
        "dmg", "iso", "pkg", "mpkg", "xip", "zip", "rar", "7z",
        "tar", "gz", "tgz", "bz2", "xz", "tbz"
    ]
    /// P3 Xcode 目录的直接后继组件。
    static let xcodeDevFollowers: Set<String> = [
        "Archives", "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport"
    ]

    struct Classification: Hashable, Sendable {
        let category: SpaceAnalysisDiagnosisCategoryID
        let rule: SpaceAnalysisDiagnosisRuleID
    }

    /// 单条目分类：按冻结优先级取首个命中（§1.2）；path component 精确、大小写敏感。
    static func classify(_ entry: SpaceAnalysisEntry) -> Classification {
        let components = entry.path.split(separator: "/").map(String.init)
        func hasComponent(_ name: String) -> Bool { components.contains(name) }
        func hasAdjacentPair(_ first: String, _ second: String) -> Bool {
            guard components.count >= 2 else { return false }
            for index in 0..<(components.count - 1)
            where components[index] == first && components[index + 1] == second {
                return true
            }
            return false
        }
        func followsComponent(_ parent: String, _ candidates: Set<String>) -> Bool {
            guard components.count >= 2 else { return false }
            for index in 0..<(components.count - 1)
            where components[index] == parent && candidates.contains(components[index + 1]) {
                return true
            }
            return false
        }
        let extension_ = (entry.displayName as NSString).pathExtension.lowercased()

        // P1 缓存与日志
        if hasComponent("Caches") { return Classification(category: .cachesAndLogs, rule: .cacheDir) }
        if hasComponent("Logs") { return Classification(category: .cachesAndLogs, rule: .logsDir) }
        if hasComponent("CrashReporter") { return Classification(category: .cachesAndLogs, rule: .crashDir) }
        // P2 通信与内容
        if hasAdjacentPair("Library", "Mail") {
            return Classification(category: .communicationsAndContent, rule: .mailLibrary)
        }
        if hasAdjacentPair("Library", "Messages") {
            return Classification(category: .communicationsAndContent, rule: .messagesLibrary)
        }
        // P3 设备与开发
        if hasComponent("MobileSync") { return Classification(category: .devicesAndDevelopment, rule: .mobilesyncDir) }
        if hasComponent("DerivedData") { return Classification(category: .devicesAndDevelopment, rule: .deriveddataDir) }
        if hasComponent("CoreSimulator") { return Classification(category: .devicesAndDevelopment, rule: .coresimulatorDir) }
        if hasComponent("com.docker.docker") {
            return Classification(category: .devicesAndDevelopment, rule: .dockerContainerDir)
        }
        if followsComponent("Xcode", xcodeDevFollowers) {
            return Classification(category: .devicesAndDevelopment, rule: .xcodeDevDir)
        }
        if entry.kind == .regularFile, vmDiskExtensions.contains(extension_) {
            return Classification(category: .devicesAndDevelopment, rule: .vmDiskExt)
        }
        // P4 应用与应用数据
        if hasComponent("Applications") { return Classification(category: .appsAndAppData, rule: .applicationsDir) }
        // R1 修订：Application Support 是含空格的单个路径组件，按整组件精确匹配。
        if hasComponent("Application Support") {
            return Classification(category: .appsAndAppData, rule: .appsupportDir)
        }
        // R1 修订：Group Containers 同为单组件；Containers 与 Group Containers 分别整组件匹配。
        if hasComponent("Containers") || hasComponent("Group Containers") {
            return Classification(category: .appsAndAppData, rule: .containersDir)
        }
        if entry.kind == .package { return Classification(category: .appsAndAppData, rule: .packageBundle) }
        // P5 安装包与归档
        if entry.kind == .regularFile, installerArchiveExtensions.contains(extension_) {
            return Classification(category: .installersAndArchives, rule: .installerArchiveExt)
        }
        // P6 用户文件：未命中且路径不含 Library 组件
        if !hasComponent("Library") { return Classification(category: .userFiles, rule: .userContent) }
        // P7 兜底
        return Classification(category: .otherScannedContent, rule: .fallbackOther)
    }

    /// 全量诊断：只读消费同一轮扫描结果；守恒／溢出／负值校验失败时拒绝呈现数字（§7）。
    /// 修订 R2：有效性校验先于呈现态求值——数据损坏（负值／溢出／守恒失配）必须拒绝，
    /// 即使分母恰为 0，也不得伪装成「未统计到容量」的普通空结果。
    static func diagnose(outcome: SpaceAnalysisScanOutcome?) -> SpaceAnalysisDiagnosisReport {
        guard let outcome else { return .noData }
        let summary = outcome.summary

        var bytesByCategory: [SpaceAnalysisDiagnosisCategoryID: Int64] = [:]
        var countByCategory: [SpaceAnalysisDiagnosisCategoryID: Int] = [:]
        var ruleCountsByCategory: [SpaceAnalysisDiagnosisCategoryID: [SpaceAnalysisDiagnosisRuleID: Int]] = [:]
        var samplesByCategory: [SpaceAnalysisDiagnosisCategoryID: [(bytes: Int64, path: String)]] = [:]
        var seenLinkGroups = Set<String>()
        var recomputedTotal: Int64 = 0
        var detectedNegative = false
        var detectedOverflow = false

        func accumulate(_ value: Int64, into partial: inout Int64) -> Bool {
            let (sum, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else { return false }
            partial = sum
            return true
        }

        for entry in outcome.entries {
            guard entry.allocatedBytes >= 0 else
            { detectedNegative = true; break }
            let classification = classify(entry)

            // 计入口径（§3）：硬链接按首次出现只计一次；包计字节；符号链接与其他类型计 0。
            var contribution: Int64 = 0
            switch entry.kind {
            case .regularFile:
                if let group = entry.linkGroupID {
                    if seenLinkGroups.contains(group) {
                        contribution = 0
                    } else {
                        seenLinkGroups.insert(group)
                        contribution = entry.allocatedBytes
                    }
                } else {
                    contribution = entry.allocatedBytes
                }
            case .package:
                contribution = entry.allocatedBytes
            case .symbolicLink, .other, .directory:
                contribution = 0
            }

            var categoryBytes = bytesByCategory[classification.category] ?? 0
            guard accumulate(contribution, into: &categoryBytes),
                  accumulate(contribution, into: &recomputedTotal)
            else { detectedOverflow = true; break }
            bytesByCategory[classification.category] = categoryBytes
            countByCategory[classification.category, default: 0] += 1
            ruleCountsByCategory[classification.category, default: [:]][classification.rule, default: 0] += 1
            samplesByCategory[classification.category, default: []]
                .append((bytes: contribution, path: entry.path))
        }

        if detectedNegative {
            return inconsistentOrEmpty(outcome, forcedState: .inconsistent(reason: .negative), recomputed: recomputedTotal)
        }
        if detectedOverflow {
            return inconsistentOrEmpty(outcome, forcedState: .inconsistent(reason: .overflow), recomputed: recomputedTotal)
        }
        // 守恒律：重算总额必须与扫描分母一致（§7）。
        if recomputedTotal != summary.scannedTotalBytes {
            return inconsistentOrEmpty(outcome, forcedState: .inconsistent(reason: .conservation), recomputed: recomputedTotal)
        }
        // 有效性全部通过后，分母为 0 才是诚实的空结果（修订 R2）。
        guard summary.scannedTotalBytes > 0 else {
            return inconsistentOrEmpty(outcome, forcedState: .emptyResult, recomputed: recomputedTotal)
        }

        let categories = SpaceAnalysisDiagnosisCategoryID.allCases.compactMap { id -> SpaceAnalysisDiagnosisCategory? in
            let bytes = bytesByCategory[id] ?? 0
            let count = countByCategory[id] ?? 0
            guard bytes > 0 || count > 0 else { return nil }
            // 样本：计入字节降序 → 路径字典序升序，取前 N（§6.4）。
            let samples = (samplesByCategory[id] ?? [])
                .sorted {
                    if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                    return $0.path < $1.path
                }
                .prefix(sampleLimit)
                .map(\.path)
            return SpaceAnalysisDiagnosisCategory(
                categoryID: id,
                bytes: bytes,
                entryCount: count,
                ruleCounts: ruleCountsByCategory[id] ?? [:],
                samplePaths: Array(samples)
            )
        }
        .sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.categoryID.rawValue < rhs.categoryID.rawValue
        }

        let denominator = summary.scannedTotalBytes
        let topCategories = Array(categories.prefix(topLimit))
        let hasProminentSource = topCategories.first.map {
            $0.fraction(of: denominator) >= prominentThreshold
        } ?? false

        let state: SpaceAnalysisDiagnosisState
        if summary.cancelled {
            state = .cancelled
        } else if summary.unreadableDirectoryCount > 0 {
            state = .partial
        } else {
            state = .complete
        }

        return SpaceAnalysisDiagnosisReport(
            state: state,
            denominatorBytes: denominator,
            scannedScopeCount: Set(outcome.nodes.filter { $0.depth == 0 }.map(\.path)).count,
            unreadableDirectoryCount: summary.unreadableDirectoryCount,
            cancelled: summary.cancelled,
            categories: categories,
            topCategories: topCategories,
            hasProminentSource: hasProminentSource,
            startedAt: summary.startedAt,
            finishedAt: summary.finishedAt,
            precisionNote: outcome.deduplication.precisionNote,
            hardLinkNote: outcome.deduplication.hardLinkNote,
            datalessNote: outcome.deduplication.datalessNote,
            datalessPlaceholderCount: outcome.deduplication.datalessPlaceholderCount,
            capacityIsUpperBound: outcome.deduplication.capacityIsUpperBound
        )
    }

    /// 空结果与不一致态的公共构造：不呈现任何类别数字。
    private static func inconsistentOrEmpty(
        _ outcome: SpaceAnalysisScanOutcome,
        forcedState: SpaceAnalysisDiagnosisState,
        recomputed: Int64
    ) -> SpaceAnalysisDiagnosisReport {
        let summary = outcome.summary
        return SpaceAnalysisDiagnosisReport(
            state: forcedState,
            denominatorBytes: summary.scannedTotalBytes,
            scannedScopeCount: Set(outcome.nodes.filter { $0.depth == 0 }.map(\.path)).count,
            unreadableDirectoryCount: summary.unreadableDirectoryCount,
            cancelled: summary.cancelled,
            categories: [],
            topCategories: [],
            hasProminentSource: false,
            startedAt: summary.startedAt,
            finishedAt: summary.finishedAt,
            precisionNote: outcome.deduplication.precisionNote,
            hardLinkNote: outcome.deduplication.hardLinkNote,
            datalessNote: outcome.deduplication.datalessNote,
            datalessPlaceholderCount: outcome.deduplication.datalessPlaceholderCount,
            capacityIsUpperBound: outcome.deduplication.capacityIsUpperBound
        )
    }

    /// 明细展示顺序（§6.3）：按冻结排序，但「其他已扫描内容」钉在末尾。
    static func detailOrder(_ categories: [SpaceAnalysisDiagnosisCategory]) -> [SpaceAnalysisDiagnosisCategory] {
        categories.filter { $0.categoryID != .otherScannedContent }
            + categories.filter { $0.categoryID == .otherScannedContent }
    }
}
