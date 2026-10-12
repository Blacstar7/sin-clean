import Foundation
import UserNotifications

// SC-5 权限按需语义载体（§3、§4）与硬要求 H1–H3。
// 口径见 work/SC-5-frozen-semantics.md：
// - 本工程只有两项可选权限；
// - 启动与首次使用都不申请；只有在具体操作触发时才申请；
// - 申请前三句说明齐备；拒绝不阻塞主流程；
// - 状态来自实时查询，不保留任何「已授权」假状态。

enum SystemPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case fullDiskAccess
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: String(localized: "读取受保护目录")
        case .notifications: String(localized: "发送提醒")
        }
    }

    /// 三句说明的第一句：为什么需要。
    var reason: String {
        switch self {
        case .fullDiskAccess:
            String(localized: "某些目录（如邮件、信息等受保护位置）默认不允许任何应用读取。")
        case .notifications:
            String(localized: "系统健康提醒需要在合适的时候通知您。")
        }
    }

    /// 第二句：用来做什么。
    var usage: String {
        switch self {
        case .fullDiskAccess:
            String(localized: "只用于把这些目录的容量统计进空间分析，让统计更接近真实占用。")
        case .notifications:
            String(localized: "只用于在磁盘紧张、持续高负载、内存压力或电量偏低时提醒您。")
        }
    }

    /// 第三句：不做会怎样。
    var ifNotGranted: String {
        switch self {
        case .fullDiskAccess:
            String(localized: "不授权也能正常使用：受保护目录不计入统计，界面会明确标注有几个目录未统计。")
        case .notifications:
            String(localized: "不授权也能正常使用：提醒不会弹出，但证据卡与趋势仍然照常更新。")
        }
    }

    var isExplainedCompletely: Bool {
        !reason.isEmpty && !usage.isEmpty && !ifNotGranted.isEmpty
    }

    /// 触发点（必须是具体操作，而不是启动）。
    var trigger: String {
        switch self {
        case .fullDiskAccess: String(localized: "在扫描结果中出现不可读目录、且您主动点击「了解如何授权」时")
        case .notifications: String(localized: "在设置中开启任一提醒类别、且系统尚未授权时")
        }
    }
}

enum PermissionStatus: String, CaseIterable, Sendable {
    case granted
    case denied
    case unknown

    var title: String {
        switch self {
        case .granted: String(localized: "已授权")
        case .denied: String(localized: "未授权")
        case .unknown: String(localized: "无法确认")
        }
    }
}

struct PermissionStatusSnapshot: Equatable, Sendable {
    let fullDiskAccess: PermissionStatus
    let notifications: PermissionStatus

    func status(of kind: SystemPermissionKind) -> PermissionStatus {
        switch kind {
        case .fullDiskAccess: fullDiskAccess
        case .notifications: notifications
        }
    }

    static let unknown = PermissionStatusSnapshot(fullDiskAccess: .unknown, notifications: .unknown)
}

/// 扫描覆盖事实（§4，R4 修订口径）：以「最近一次扫描的未统计目录数」表达覆盖情况。
/// 注意区分两件事：权限状态来自探针（只证明固定受保护路径可读）；覆盖事实来自扫描真实计数
/// （列举失败一律计数，原因不止权限——本模型不做归因，也不承诺重新扫描后归零）。
struct PermissionCoverage: Equatable, Sendable {
    let unreadableDirectoryCount: Int
    let hasScanResult: Bool
    /// 本次扫描是否完整完成（未取消）。「已全部统计」只在完成且实际未统计数为零时成立。
    var scanCompleted: Bool = true

    static let none = PermissionCoverage(unreadableDirectoryCount: 0, hasScanResult: false)

    var isFullyCovered: Bool { hasScanResult && scanCompleted && unreadableDirectoryCount == 0 }

    var summary: String {
        guard hasScanResult else { return String(localized: "尚未进行扫描，无法给出覆盖情况。") }
        if isFullyCovered { return String(localized: "已全部统计：本次扫描没有未能完成统计的目录。") }
        // R4：非零（或未完成）时如实显示真实数；授权后仍非零也照实显示。
        // 只说明可重新扫描、覆盖以实际结果为准，不承诺归零。
        if !scanCompleted {
            if unreadableDirectoryCount == 0 {
                return String(localized: "本次扫描未完成；重新扫描可获得完整覆盖情况。回到本应用时会自动重新检测权限状态（也可点「\(PermissionGuidance.recheckButtonTitle)」）。")
            }
            return String(localized: "本次扫描未完成，\(unreadableDirectoryCount.formatted()) 个目录未能完成统计；重新扫描可获得完整覆盖情况。回到本应用时会自动重新检测权限状态（也可点「\(PermissionGuidance.recheckButtonTitle)」）。")
        }
        return String(localized: "\(unreadableDirectoryCount.formatted()) 个目录未能完成统计；授权或调整访问条件后可重新扫描，覆盖情况以实际扫描结果为准。回到本应用时会自动重新检测权限状态（也可点「\(PermissionGuidance.recheckButtonTitle)」）。")
    }
}

protocol PermissionStatusProbing: Sendable {
    func snapshot() async -> PermissionStatusSnapshot
}

/// 生产实现：状态来自实时查询。
/// - 通知权限：系统通知设置接口。
/// - 完全磁盘访问：对固定系统受保护路径做**只读可读性探测**（只判断可读性，不读取任何内容）。
struct SystemPermissionProbe: PermissionStatusProbing {
    /// 只判断该路径是否可读；不读取其内容。
    static let probePath = "/Library/Application Support/com.apple.TCC"

    func snapshot() async -> PermissionStatusSnapshot {
        PermissionStatusSnapshot(
            fullDiskAccess: Self.fullDiskAccessStatus(),
            notifications: await Self.notificationStatus()
        )
    }

    static func fullDiskAccessStatus() -> PermissionStatus {
        let manager = FileManager.default
        guard manager.fileExists(atPath: probePath) else { return .unknown }
        return manager.isReadableFile(atPath: probePath) ? .granted : .denied
    }

    static func notificationStatus() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .denied
        @unknown default: return .unknown
        }
    }
}

/// 夹具与预览用：状态可注入，且记录是否发生过「申请」调用。
final class InjectedPermissionProbe: PermissionStatusProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotValue: PermissionStatusSnapshot
    private var requestCount = 0

    init(snapshot: PermissionStatusSnapshot = .unknown) {
        self.snapshotValue = snapshot
    }

    func snapshot() async -> PermissionStatusSnapshot {
        currentSnapshot()
    }

    /// 同步读取：NSLock 不得直接用于异步上下文。
    private func currentSnapshot() -> PermissionStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotValue
    }

    func setSnapshot(_ snapshot: PermissionStatusSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        snapshotValue = snapshot
    }

    /// 仅用于断言「引导与启动路径没有申请过权限」。
    func recordRequest() {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
    }

    func requests() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }
}

enum PermissionGuidance {
    /// 系统设置深链（只读跳转；引导本身不跳转，只在用户点击时使用）。
    static func settingsURL(for kind: SystemPermissionKind) -> String {
        switch kind {
        case .fullDiskAccess:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .notifications:
            "x-apple.systempreferences:com.apple.preference.notifications"
        }
    }

    static func requestButtonTitle(for kind: SystemPermissionKind) -> String {
        switch kind {
        case .fullDiskAccess: String(localized: "了解如何授权")
        case .notifications: String(localized: "开启提醒并申请通知权限")
        }
    }

    // SC-5.2「重新检测入口」：显式入口，只重新查询状态，不申请权限、不跳转系统设置。
    static let recheckButtonTitle = String(localized: "重新检测")
    static let recheckAccessibilityLabel = String(localized: "重新检测权限状态")
    static let recheckAccessibilityHint = String(localized: "只重新查询当前权限状态；不会申请权限，也不会打开系统设置")
    static let recheckHelp = String(localized: "重新查询当前权限状态（不会申请权限）")
}
