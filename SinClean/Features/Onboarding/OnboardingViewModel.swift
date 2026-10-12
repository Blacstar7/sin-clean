import Foundation

// SC-5 首次使用视图模型。
// §1：三屏硬上限、可跳过可回看、完成后只写一个本地标记、可在设置中重看。
// §3/H1：本文件与引导流程**不申请任何权限**（不出现任何权限申请接口）。

protocol OnboardingCompletionStoring: Sendable {
    func isCompleted() -> Bool
    func markCompleted()
    func reset()
}

final class UserDefaultsOnboardingCompletionStore: OnboardingCompletionStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "onboarding.completed"
    private static let versionKey = "onboarding.completionMarkerVersion"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isCompleted() -> Bool {
        defaults.integer(forKey: Self.versionKey) >= OnboardingSemantics.completionMarkerVersion
            && defaults.bool(forKey: Self.key)
    }

    func markCompleted() {
        defaults.set(true, forKey: Self.key)
        defaults.set(OnboardingSemantics.completionMarkerVersion, forKey: Self.versionKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.versionKey)
    }
}

final class InMemoryOnboardingCompletionStore: OnboardingCompletionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Bool
    private var writes = 0

    init(completed: Bool = false) {
        self.completed = completed
    }

    func isCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func markCompleted() {
        lock.lock()
        defer { lock.unlock() }
        completed = true
        writes += 1
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        completed = false
        writes += 1
    }

    func writeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published private(set) var step: OnboardingStep = .readOnlyAndSelection
    @Published private(set) var isPresented: Bool
    @Published private(set) var hasCompleted: Bool

    /// 引导永不申请权限：该常量是契约的一部分，由专项断言与源码断言共同保证。
    static let requestsPermissions = false

    private let store: any OnboardingCompletionStoring

    init(store: any OnboardingCompletionStoring = UserDefaultsOnboardingCompletionStore()) {
        self.store = store
        let completed = store.isCompleted()
        self.hasCompleted = completed
        self.isPresented = !completed
    }

    var stepCount: Int { OnboardingSemantics.maximumStepCount }
    var isFirstStep: Bool { step == .readOnlyAndSelection }
    var isLastStep: Bool { step == .permissionsOnDemand }

    func next() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// 跳过直达末屏（不得跳过到「第四屏」）。
    func skipToLast() {
        step = .permissionsOnDemand
    }

    func finish() {
        store.markCompleted()
        hasCompleted = true
        isPresented = false
        step = .readOnlyAndSelection
    }

    /// 设置页入口：重看不改变完成标记以外的任何状态。
    func reopen() {
        step = .readOnlyAndSelection
        isPresented = true
    }

    func dismissWithoutCompleting() {
        isPresented = false
    }
}
