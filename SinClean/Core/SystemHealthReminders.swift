import Foundation

// SC-4 克制型提醒（§7）。
//
// 边界（work/SC-4-frozen-semantics.md B6）：提醒只能由**用户**开启或关闭；
// 任何省电、降载或后台策略都不得静默关闭已开启的提醒，也不得降低其级别。
// 本文件因此只提供 `setEnabled(_:for:)` 一个变更入口，且不提供任何「按电量/后台批量关闭」的接口。

struct SystemHealthReminderPreferences: Equatable, Sendable {
    private var enabled: Set<SystemHealthReminderKind>

    /// 默认全部关闭（克制型）。
    static let `default` = SystemHealthReminderPreferences(enabled: [])

    init(enabled: Set<SystemHealthReminderKind>) {
        self.enabled = enabled
    }

    func isEnabled(_ kind: SystemHealthReminderKind) -> Bool { enabled.contains(kind) }

    var enabledKinds: [SystemHealthReminderKind] {
        SystemHealthReminderKind.allCases.filter { enabled.contains($0) }
    }

    /// 唯一变更入口：由用户操作触发。
    mutating func setEnabled(_ value: Bool, for kind: SystemHealthReminderKind) {
        if value { enabled.insert(kind) } else { enabled.remove(kind) }
    }
}

/// 提醒偏好的持久化（注入式，便于夹具断言「只写用户选择」）。
protocol SystemHealthReminderPreferenceStoring: Sendable {
    func load() -> SystemHealthReminderPreferences
    func save(_ preferences: SystemHealthReminderPreferences)
}

final class UserDefaultsSystemHealthReminderPreferenceStore: SystemHealthReminderPreferenceStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "settings.systemHealthReminders"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SystemHealthReminderPreferences {
        guard let raw = defaults.array(forKey: Self.key) as? [String] else { return .default }
        let kinds = raw.compactMap { SystemHealthReminderKind(rawValue: $0) }
        return SystemHealthReminderPreferences(enabled: Set(kinds))
    }

    func save(_ preferences: SystemHealthReminderPreferences) {
        defaults.set(preferences.enabledKinds.map(\.rawValue), forKey: Self.key)
    }
}

final class InMemorySystemHealthReminderPreferenceStore: SystemHealthReminderPreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences: SystemHealthReminderPreferences
    private var saveCount = 0

    init(preferences: SystemHealthReminderPreferences = .default) {
        self.preferences = preferences
    }

    func load() -> SystemHealthReminderPreferences {
        lock.lock()
        defer { lock.unlock() }
        return preferences
    }

    func save(_ preferences: SystemHealthReminderPreferences) {
        lock.lock()
        defer { lock.unlock() }
        self.preferences = preferences
        saveCount += 1
    }

    func saves() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return saveCount
    }
}

/// 提醒判定引擎：只看**持续状态**与用户偏好，不看单次样本。
actor SystemHealthReminderEngine {
    private let store: any SystemHealthReminderPreferenceStoring
    private var preferences: SystemHealthReminderPreferences
    private var history: [SystemHealthSample] = []
    private var lastRaised: [SystemHealthReminderKind: Date] = [:]

    private let historyLimit = 240

    init(store: any SystemHealthReminderPreferenceStoring = UserDefaultsSystemHealthReminderPreferenceStore()) {
        self.store = store
        self.preferences = store.load()
    }

    func currentPreferences() -> SystemHealthReminderPreferences { preferences }

    /// 用户操作入口。降载/省电路径不得调用本方法，也不存在其他变更入口。
    func setEnabled(_ value: Bool, for kind: SystemHealthReminderKind) {
        preferences.setEnabled(value, for: kind)
        store.save(preferences)
    }

    func ingest(_ sample: SystemHealthSample) -> [SystemHealthReminder] {
        history.append(sample)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        guard !preferences.enabledKinds.isEmpty else { return [] }
        return preferences.enabledKinds.compactMap { kind in
            guard conditionHolds(kind, now: sample.capturedAt) else { return nil }
            if let last = lastRaised[kind], sample.capturedAt.timeIntervalSince(last) < kind.cooldown {
                return nil
            }
            lastRaised[kind] = sample.capturedAt
            return SystemHealthReminder(
                kind: kind,
                title: kind.title,
                message: message(for: kind),
                target: kind.target,
                raisedAt: sample.capturedAt
            )
        }
    }

    // MARK: - 持续条件

    func conditionHolds(_ kind: SystemHealthReminderKind, now: Date) -> Bool {
        switch kind {
        case .diskPressure:
            return sustainedSpan(
                now: now,
                duration: kind.requiredDuration
            ) { sample in
                guard let ratio = sample.volumeFreeRatio else { return false }
                return ratio < SystemHealthSemantics.diskReminderFreeRatio
            }
        case .sustainedCPU:
            return sustainedSpan(
                now: now,
                duration: kind.requiredDuration
            ) { sample in
                sample.cpuLoad >= SystemHealthSemantics.sustainedLoadThreshold
            }
        case .memoryPressure:
            return sustainedSpan(
                now: now,
                duration: kind.requiredDuration
            ) { sample in
                sample.memoryPressure.isElevated
            }
        case .battery:
            guard let battery = history.last?.battery else { return false }
            return !battery.isCharging && battery.level < SystemHealthSemantics.batteryReminderLevel
        }
    }

    /// 条件在整段时长内持续成立，且历史确实覆盖了这段时长。
    private func sustainedSpan(
        now: Date,
        duration: TimeInterval,
        predicate: (SystemHealthSample) -> Bool
    ) -> Bool {
        let windowStart = now.addingTimeInterval(-duration)
        // 覆盖要求：必须从窗口开始之前就在观察，否则不足以声称「持续了整段时长」。
        guard let observationStart = history.first?.capturedAt, observationStart <= windowStart else {
            return false
        }
        let window = history.filter { $0.capturedAt >= windowStart }
        guard !window.isEmpty else { return false }
        // 窗口内每一条观测都必须成立；任何一条不成立都不得称为持续。
        return window.allSatisfy(predicate)
    }

    private func message(for kind: SystemHealthReminderKind) -> String {
        switch kind {
        case .diskPressure:
            String(localized: "可用容量低于 10% 已持续 10 分钟。可在「空间清理」中查看统计后再决定是否处理。")
        case .sustainedCPU:
            String(localized: "CPU 负载持续偏高已超过 5 分钟。可在「Mac 状态」证据卡查看持续状态的判断依据。")
        case .memoryPressure:
            String(localized: "系统内存压力偏高已持续 3 分钟。可在「Mac 状态」证据卡查看判断依据与建议。")
        case .battery:
            String(localized: "电量低于 20% 且未充电。请查看电源状态说明。")
        }
    }
}
