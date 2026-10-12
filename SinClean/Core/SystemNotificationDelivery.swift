import Combine
import Foundation
import UserNotifications

// SC-7 通知权限生产接线（work/SC-7-notification-wiring-rework-20261001/）。
// 冻结口径：SC-5 §3.2（仅当用户开启任一提醒类别且尚未授权时才申请）、§3.4（申请前三句说明）、
// §4.2（状态永远来自查询）、§8.2（不保留任何「已授权」假状态）；SC-4 §7（持续条件、冷却、
// 落点全部由提醒引擎冻结，本文件不重新判定、不改判定）。
//
// 边界：requestAuthorization 与 UNNotificationRequest 全工程只允许出现在本文件；
// 启动路径与首次使用不调用本文件的任何申请入口；查询（notificationSettings）不构成申请。

/// 授权决策四态（返工要求：尚未决定／已拒绝／已授权／不可确认分别处理）。
enum NotificationAuthorizationDecision: Equatable, Sendable {
    case granted
    case notDetermined
    case denied
    case unknown

    init(status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral: self = .granted
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        @unknown default: self = .unknown
        }
    }
}

/// 开关分流（纯函数）：已授权直接开启；尚未决定先说明再申请；
/// 已拒绝解释限制并提供系统设置入口（不再触发系统申请，避免循环弹窗）；
/// 不可确认如实说明，不申请、不跳转。
enum ReminderNotificationGate: Equatable, Sendable {
    case enableDirectly
    case explainBeforeRequest
    case explainDeniedRestriction
    case explainUnconfirmed
    /// 申请后仍未取得决定（申请窗口被关闭且系统未记录选择）：
    /// 如实说明「尚未完成选择」，本次不自动再申请、不跳转系统设置。
    case explainUndecidedAfterRequest

    static func step(for decision: NotificationAuthorizationDecision) -> ReminderNotificationGate {
        switch decision {
        case .granted: .enableDirectly
        case .notDetermined: .explainBeforeRequest
        case .denied: .explainDeniedRestriction
        case .unknown: .explainUnconfirmed
        }
    }

    /// 申请后分流（真实界面回调必须使用本映射）：只有明确拒绝才呈现已拒绝；
    /// 未取得决定与不可确认各自如实呈现，不得一律渲染为已拒绝。
    static func afterRequest(_ decision: NotificationAuthorizationDecision) -> ReminderNotificationGate {
        switch decision {
        case .granted: .enableDirectly
        case .denied: .explainDeniedRestriction
        case .unknown: .explainUnconfirmed
        case .notDetermined: .explainUndecidedAfterRequest
        }
    }
}

/// 通知中心抽象：生产实现包裹系统通知中心；夹具注入用于断言申请纪律。
protocol SystemNotificationScheduling: Sendable {
    /// 只查询，不申请。
    func authorizationDecision() async -> NotificationAuthorizationDecision
    /// 真实申请；返回申请后的实际系统状态（不以下调布尔值推断）。
    func requestAuthorization() async -> NotificationAuthorizationDecision
    /// 投递一条真实系统通知；成功与否如实返回。
    func deliverReminderNotification(id: String, title: String, body: String) async -> Bool
}

/// 生产实现：全工程唯一的真实申请与投递接线点。
struct UserNotificationScheduler: SystemNotificationScheduling {
    func authorizationDecision() async -> NotificationAuthorizationDecision {
        NotificationAuthorizationDecision(
            status: await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        )
    }

    func requestAuthorization() async -> NotificationAuthorizationDecision {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        // 授权状态以申请后的真实系统查询为准；未决（用户未作选择）不当作拒绝。
        return NotificationAuthorizationDecision(
            status: await center.notificationSettings().authorizationStatus
        )
    }

    func deliverReminderNotification(id: String, title: String, body: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }
}

/// 夹具与预览用：不申请、不投递、不触碰系统；决策恒为不可确认。
struct InertNotificationScheduler: SystemNotificationScheduling {
    func authorizationDecision() async -> NotificationAuthorizationDecision { .unknown }
    func requestAuthorization() async -> NotificationAuthorizationDecision { .unknown }
    func deliverReminderNotification(id: String, title: String, body: String) async -> Bool { false }
}

/// 投递协调器：订阅仪表盘提醒流，把到期提醒原样投递为系统通知。
/// - 授权判定每次实时查询；未授权或不可确认时跳过系统投递（应用内提醒面板仍照常显示）；
/// - 去重按（类别，触发时间），忽略按钮不影响投递判据；
/// - 不缓存授权结论：lastDecision 只是最近一次真实查询的只读呈现。
@MainActor
final class SystemNotificationDelivery: ObservableObject {
    @Published private(set) var lastDecision: NotificationAuthorizationDecision = .unknown

    private let scheduler: any SystemNotificationScheduling
    private var subscription: AnyCancellable?
    private var deliveredKeys: Set<String> = []

    init(scheduler: any SystemNotificationScheduling = UserNotificationScheduler()) {
        self.scheduler = scheduler
    }

    /// 订阅共享仪表盘视图模型的提醒流；幂等。启动路径只订阅，不查询、不申请——
    /// 第一次授权查询发生在用户开启提醒或首条到期提醒投递之前。
    /// 以发布者为参数（而非具体视图模型类型），保持 Core 不依赖界面层类型。
    func attach(reminders publisher: some Publisher<[SystemHealthReminder], Never>) {
        guard subscription == nil else { return }
        subscription = publisher.sink { [weak self] reminders in
            Task { @MainActor [weak self] in
                await self?.deliverNewReminders(reminders)
            }
        }
    }

    /// 消费到期提醒（与生产投递同一条路径；夹具与专项断言直接调用）。
    func deliverNewReminders(_ reminders: [SystemHealthReminder]) async {
        for reminder in reminders {
            let key = Self.deliveryKey(for: reminder)
            guard !deliveredKeys.contains(key) else { continue }
            deliveredKeys.insert(key)
            // 授权判定来自实时查询；未授权或不可确认时静默跳过系统投递。
            let decision = await scheduler.authorizationDecision()
            lastDecision = decision
            guard decision == .granted else { continue }
            _ = await scheduler.deliverReminderNotification(
                id: "sinclean-reminder-\(key)",
                title: reminder.title,
                body: reminder.message + "\n" + String(localized: "落点：\(reminder.target.title)")
            )
        }
    }

    /// 开关路径：只查询（每次开关动作都重查，不缓存、不把开关当授权事实）。
    func currentDecision() async -> NotificationAuthorizationDecision {
        let decision = await scheduler.authorizationDecision()
        lastDecision = decision
        return decision
    }

    /// 真实申请：只在用户读过三句说明并确认后由界面调用。
    func requestAuthorizationForReminders() async -> NotificationAuthorizationDecision {
        let decision = await scheduler.requestAuthorization()
        lastDecision = decision
        return decision
    }

    private static func deliveryKey(for reminder: SystemHealthReminder) -> String {
        reminder.kind.rawValue + "@" + String(Int(reminder.raisedAt.timeIntervalSince1970))
    }

    #if DEBUG
    /// SC-7 验证入口（仅 DEBUG 构建；最终 Release 不存在本方法，交付时以二进制检索复核）。
    /// 注入一条与生产同构的到期提醒，走与生产完全相同的投递路径（实时授权查询＋系统通知请求）；
    /// 不构造真实高负载／低磁盘条件，也不替代生产权限流程。
    func deliverFixtureReminderForVerification() async {
        let kind = SystemHealthReminderKind.diskPressure
        await deliverNewReminders([
            SystemHealthReminder(
                kind: kind,
                title: kind.title,
                message: String(localized: "验证入口投递（仅调试构建）：此通知由人工注入产生，用于验证生产投递路径；不改变任何判定。"),
                target: kind.target,
                raisedAt: Date()
            )
        ])
    }
    #endif
}
