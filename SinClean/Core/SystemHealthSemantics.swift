import Foundation

// SC-4 冻结语义载体：阈值、档位、措辞与刷新间隔表。
// 口径见 work/SC-4-frozen-semantics.md。本文件只描述语义：不采样、不读写任何文件。

enum SystemHealthSemantics {
    /// §2 CPU 持续窗口：60 秒，最少 6 个有效样本，其中 ≥80% 超阈值才判定「持续」。
    static let sustainedWindowSeconds: TimeInterval = 60
    static let sustainedMinimumSamples = 6
    static let sustainedSampleRatio = 0.80
    static let sustainedLoadThreshold = 0.80

    /// §5 短期趋势环形缓冲长度与磁盘趋势上限。
    static let shortTermSampleLimit = 60
    static let diskTrendRetentionDays = 30
    static let diskTrendIntervalSeconds: TimeInterval = 6 * 60 * 60
    static let trendMinimumPoints = 3

    /// §6 自适应刷新间隔表。
    static let foregroundSampleSeconds: TimeInterval = 5
    static let backgroundSampleSeconds: TimeInterval = 30
    static let lockedSampleSeconds: TimeInterval = 120
    static let lowPowerSampleSeconds: TimeInterval = 30
    static let scanningSampleSeconds: TimeInterval = 60

    /// §3 存储压力阈值。
    static let storageAmpleThreshold = 0.20
    static let storageLowThreshold = 0.10

    /// §7 提醒持续条件与冷却。
    static let diskReminderFreeRatio = 0.10
    static let diskReminderDuration: TimeInterval = 10 * 60
    static let cpuReminderDuration: TimeInterval = 5 * 60
    static let memoryReminderDuration: TimeInterval = 3 * 60
    static let batteryReminderLevel = 0.20
    static let reminderCooldown: TimeInterval = 30 * 60
}

// MARK: - 内存压力（§1）

/// 档位**只**由系统内存压力事实决定；占用率与压缩量只作证据展示。
enum MemoryPressureLevel: String, CaseIterable, Sendable {
    case normal
    case warning
    case critical
    case unavailable

    /// `sysctl kern.memorystatus_vm_pressure_level`：1 正常、2 偏高、4 严重。
    static func from(kernelValue: Int32?) -> MemoryPressureLevel {
        switch kernelValue {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: .unavailable
        }
    }

    var title: String {
        switch self {
        case .normal: String(localized: "内存压力正常")
        case .warning: String(localized: "内存压力偏高")
        case .critical: String(localized: "内存压力严重")
        case .unavailable: String(localized: "内存压力数据不可得")
        }
    }

    var note: String {
        switch self {
        case .normal: String(localized: "系统当前未报告内存压力。")
        case .warning: String(localized: "内存压力偏高，系统已开始压缩内存。")
        case .critical: String(localized: "内存压力严重，建议关闭占用较大的应用。")
        case .unavailable: String(localized: "无法读取系统内存压力事实，本轮不作任何内存档位判断。")
        }
    }

    var isElevated: Bool { self == .warning || self == .critical }
}

// MARK: - CPU 持续状态（§2）

enum SustainedLoadState: Equatable, Sendable {
    /// 窗口内样本不足，尚不足以判断持续状态。
    case sampling
    case steady
    case sustained

    var title: String {
        switch self {
        case .sampling: String(localized: "采样中")
        case .steady: String(localized: "负载平稳")
        case .sustained: String(localized: "持续高负载")
        }
    }

    var note: String {
        switch self {
        case .sampling: String(localized: "采样中，尚不足以判断持续状态。")
        case .steady: String(localized: "最近窗口内没有持续高负载。")
        case .sustained: String(localized: "最近窗口内多数样本负载偏高，属持续状态。")
        }
    }

    /// 单次峰值**不得**产生持续判定：只有样本数足够且超阈值比例达标才算持续。
    static func evaluate(
        samples: [Double],
        threshold: Double = SystemHealthSemantics.sustainedLoadThreshold,
        minimumSamples: Int = SystemHealthSemantics.sustainedMinimumSamples,
        requiredRatio: Double = SystemHealthSemantics.sustainedSampleRatio
    ) -> SustainedLoadState {
        guard samples.count >= minimumSamples else { return .sampling }
        let elevated = samples.filter { $0 >= threshold }.count
        let ratio = Double(elevated) / Double(samples.count)
        return ratio >= requiredRatio ? .sustained : .steady
    }
}

// MARK: - 存储压力（§3）

enum StoragePressureLevel: String, CaseIterable, Sendable {
    case ample
    case low
    case tight
    case unavailable

    static func evaluate(freeRatio: Double?) -> StoragePressureLevel {
        guard let freeRatio else { return .unavailable }
        if freeRatio < SystemHealthSemantics.storageLowThreshold { return .tight }
        if freeRatio < SystemHealthSemantics.storageAmpleThreshold { return .low }
        return .ample
    }

    var title: String {
        switch self {
        case .ample: String(localized: "存储充足")
        case .low: String(localized: "存储偏低")
        case .tight: String(localized: "存储紧张")
        case .unavailable: String(localized: "存储容量不可得")
        }
    }

    var note: String {
        switch self {
        case .ample: String(localized: "可用容量充足。")
        case .low: String(localized: "可用容量偏低，可先查看空间分析的统计结果。")
        case .tight: String(localized: "可用容量紧张，建议先做一次只读空间分析再决定是否处理。")
        case .unavailable: String(localized: "无法读取卷容量事实，本轮不作存储压力判断。")
        }
    }
}

/// 与空间分析的连接是**只读**的：只引用既有结果，不触发扫描、不触碰文件。
struct SpaceAnalysisLink: Equatable, Sendable {
    let hasResult: Bool
    let scannedTotalBytes: Int64
    let largeFileCount: Int
    let largeFileBytes: Int64
    let finishedAt: Date?

    static let none = SpaceAnalysisLink(
        hasResult: false,
        scannedTotalBytes: 0,
        largeFileCount: 0,
        largeFileBytes: 0,
        finishedAt: nil
    )

    /// 无结果时必须显式说明，不得用估算值填充。
    var note: String {
        guard hasResult else { return String(localized: "尚未进行空间分析，无法给出可清理估计。") }
        return String(localized: "最近一次空间分析统计到的大文件 \(largeFileCount.formatted()) 项，合计 \(SystemHealthFormatters.bytes(largeFileBytes))。")
    }
}

// MARK: - 证据卡（§4）

enum HealthToolTarget: String, Sendable {
    case spaceCleanup
    case evidenceCard
    case batteryStatus

    var title: String {
        switch self {
        case .spaceCleanup: String(localized: "空间清理")
        case .evidenceCard: String(localized: "Mac 状态证据卡")
        case .batteryStatus: String(localized: "电源状态说明")
        }
    }
}

struct HealthRecommendation: Equatable, Sendable {
    let action: String
    let canSolve: String
    let cannotSolve: String
    let target: HealthToolTarget

    var isComplete: Bool {
        !action.isEmpty && !canSolve.isEmpty && !cannotSolve.isEmpty
    }

    /// 推荐操作**不得**指向清缓存类动作。
    var isMisleading: Bool {
        let banned = ["清缓存", "清除缓存", "立即释放", "马上清理", "一键加速"]
        let text = action + canSolve + cannotSolve
        return banned.contains { text.contains($0) }
    }
}

struct HealthEvidence: Equatable, Sendable {
    let value: String
    let basis: String
    let duration: String
    let updatedAt: Date
    let recommendation: HealthRecommendation

    /// 五要素齐备（§4）：测量值、判断依据、持续时间、更新时间、推荐操作。
    var isComplete: Bool {
        !value.isEmpty && !basis.isEmpty && !duration.isEmpty && recommendation.isComplete
    }
}

// MARK: - 自适应刷新（§6）

struct RefreshContext: Equatable, Sendable {
    var isForeground: Bool
    var isScreenLocked: Bool
    var isLowPowerMode: Bool
    var isScanning: Bool

    static let foreground = RefreshContext(
        isForeground: true,
        isScreenLocked: false,
        isLowPowerMode: false,
        isScanning: false
    )
}

enum AdaptiveRefreshPolicy {
    /// 多条件叠加取**最宽**（最省）间隔。
    /// `baseInterval` 为基础间隔，默认＝冻结的前台基础 5 秒（自动档）。
    /// （SC-5 二次返工 C-a：固定档位把它参数化；各条件放宽值与取最宽逻辑取值不变。）
    static func interval(
        for context: RefreshContext,
        baseInterval: TimeInterval = SystemHealthSemantics.foregroundSampleSeconds
    ) -> TimeInterval {
        var interval = baseInterval
        if !context.isForeground { interval = max(interval, SystemHealthSemantics.backgroundSampleSeconds) }
        if context.isLowPowerMode { interval = max(interval, SystemHealthSemantics.lowPowerSampleSeconds) }
        if context.isScanning { interval = max(interval, SystemHealthSemantics.scanningSampleSeconds) }
        if context.isScreenLocked { interval = max(interval, SystemHealthSemantics.lockedSampleSeconds) }
        return interval
    }

    static func reason(for context: RefreshContext) -> String {
        if context.isScreenLocked { return String(localized: "屏幕已锁定，采样间隔放宽") }
        if context.isLowPowerMode { return String(localized: "低电量模式，采样间隔放宽") }
        if context.isScanning { return String(localized: "空间分析扫描进行中，采样间隔放宽") }
        if !context.isForeground { return String(localized: "应用在后台，采样间隔放宽") }
        return String(localized: "前台活跃，按基础间隔采样")
    }

    /// 降载只影响节奏，不改变已采集数据的语义。
    static let reducedCadenceKeepsDataSemantics = true
}

// MARK: - 提醒（§7）

enum SystemHealthReminderKind: String, CaseIterable, Identifiable, Sendable {
    case diskPressure
    case sustainedCPU
    case memoryPressure
    case battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diskPressure: String(localized: "存储压力提醒")
        case .sustainedCPU: String(localized: "持续高负载提醒")
        case .memoryPressure: String(localized: "内存压力提醒")
        case .battery: String(localized: "电池状态提醒")
        }
    }

    var detail: String {
        switch self {
        case .diskPressure: String(localized: "可用容量低于 10% 并持续 10 分钟时提醒。")
        case .sustainedCPU: String(localized: "负载持续偏高 5 分钟时提醒；单次峰值不会提醒。")
        case .memoryPressure: String(localized: "系统内存压力偏高或严重并持续 3 分钟时提醒。")
        case .battery: String(localized: "电量低于 20% 且未充电时提醒。")
        }
    }

    var requiredDuration: TimeInterval {
        switch self {
        case .diskPressure: SystemHealthSemantics.diskReminderDuration
        case .sustainedCPU: SystemHealthSemantics.cpuReminderDuration
        case .memoryPressure: SystemHealthSemantics.memoryReminderDuration
        case .battery: 0
        }
    }

    /// 落点必须指向正确工具，四类一律不得指向清缓存。
    var target: HealthToolTarget {
        switch self {
        case .diskPressure: .spaceCleanup
        case .sustainedCPU, .memoryPressure: .evidenceCard
        case .battery: .batteryStatus
        }
    }

    var cooldown: TimeInterval { SystemHealthSemantics.reminderCooldown }
}

struct SystemHealthReminder: Identifiable, Equatable, Sendable {
    var id: String { kind.rawValue }
    let kind: SystemHealthReminderKind
    let title: String
    let message: String
    let target: HealthToolTarget
    let raisedAt: Date
}

// MARK: - 格式化（与既有系统健康模块共用同一套口径）

enum SystemHealthFormatters {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: value)
    }

    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    static func duration(_ interval: TimeInterval) -> String {
        if interval < 60 { return String(localized: "\(Int(interval.rounded())) 秒") }
        if interval < 3600 { return String(localized: "\(Int((interval / 60).rounded())) 分钟") }
        return String(localized: "\(Int((interval / 3600).rounded())) 小时")
    }
}
