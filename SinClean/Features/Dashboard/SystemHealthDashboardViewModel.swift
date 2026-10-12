import AppKit
import Combine
import Foundation

// SC-4 Mac 状态证据卡与趋势的视图模型。
// 语义与阈值全部取自 work/SC-4-frozen-semantics.md；本文件不碰文件系统、不发起网络请求。

enum SystemHealthSamplingConsumer: Hashable, Sendable {
    case dashboard(UUID)
    case menuBar(UUID)
}

@MainActor
final class SystemHealthDashboardViewModel: ObservableObject {
    @Published private(set) var sample: SystemHealthSample?
    @Published private(set) var sustainedLoad: SustainedLoadState = .sampling
    @Published private(set) var storagePressure: StoragePressureLevel = .unavailable
    @Published private(set) var evidenceCards: [HealthEvidenceCard] = []
    @Published private(set) var trends: SystemHealthTrends = .empty
    @Published private(set) var reminders: [SystemHealthReminder] = []
    @Published private(set) var preferences: SystemHealthReminderPreferences = .default
    @Published private(set) var refreshInterval: TimeInterval = SystemHealthSemantics.foregroundSampleSeconds
    @Published private(set) var refreshReason = String(localized: "前台活跃，按基础间隔采样")
    @Published private(set) var isSampling = false
    @Published private(set) var storageLocation = "—"
    /// SC-4 R2：清空持久化失败后的可重试反馈态；数据保留在真实存储状态。
    @Published private(set) var trendClearFailed = false
    /// SC-4 R2：采样持久化失败的可观察降级态（不弹窗）；设置页趋势区块消费。
    @Published private(set) var trendPersistDegraded = false

    private let sampler: any SystemHealthSampling
    private let trendStore: SystemHealthTrendStore
    private let reminderEngine: SystemHealthReminderEngine
    private let loopSleep: @Sendable (TimeInterval) async -> Void
    private var spaceAnalysisLink: @MainActor () -> SpaceAnalysisLink
    private var isScanning: @MainActor () -> Bool

    /// SC-ARCH-R2-R1：界面类型与实例 token 共同标识消费者；同类多窗口分别登记。
    private var activeConsumers: Set<SystemHealthSamplingConsumer> = []
    private var appliedConfigurationID: String?
    private var automaticRefreshEnabled = false
    /// SC-5 C-a 冻结语义：档位仍只作为基础间隔参与「多条件取最宽」。
    private var preferredBaseInterval = SystemHealthSemantics.foregroundSampleSeconds
    private var loopTask: Task<Void, Never>?
    private var cpuWindow: [(Date, Double)] = []
    private var trendMutationGeneration = 0
    private var isClearingTrends = false

    init(
        sampler: any SystemHealthSampling = SystemHealthSampler(),
        trendStore: SystemHealthTrendStore = SystemHealthTrendStore(),
        reminderEngine: SystemHealthReminderEngine = SystemHealthReminderEngine(),
        spaceAnalysisLink: @escaping @MainActor () -> SpaceAnalysisLink = { .none },
        isScanning: @escaping @MainActor () -> Bool = { false },
        loopSleep: @escaping @Sendable (TimeInterval) async -> Void = { interval in
            try? await Task<Never, Never>.sleep(
                nanoseconds: UInt64(max(0, interval) * 1_000_000_000)
            )
        }
    ) {
        self.sampler = sampler
        self.trendStore = trendStore
        self.reminderEngine = reminderEngine
        self.spaceAnalysisLink = spaceAnalysisLink
        self.isScanning = isScanning
        self.loopSleep = loopSleep
    }

    #if DEBUG
    /// 所有通用预览共用的显式持久化隔离入口；不读写真实趋势或健康提醒偏好。
    static func isolatedPreview(
        sampler: any SystemHealthSampling = SystemHealthSampler()
    ) -> SystemHealthDashboardViewModel {
        SystemHealthDashboardViewModel(
            sampler: sampler,
            trendStore: SystemHealthTrendStore(access: InMemorySystemHealthDocumentAccess()),
            reminderEngine: SystemHealthReminderEngine(
                store: InMemorySystemHealthReminderPreferenceStore()
            )
        )
    }
    #endif

    /// 组合根在视图出现后绑定只读引用（空间分析结果与扫描状态）。
    func bind(
        spaceAnalysisLink: @escaping @MainActor () -> SpaceAnalysisLink,
        isScanning: @escaping @MainActor () -> Bool
    ) {
        self.spaceAnalysisLink = spaceAnalysisLink
        self.isScanning = isScanning
    }

    // MARK: - 生命周期

    /// 激活一个采样消费者。同一消费者或同一全局配置重复提交均为 no-op。
    func activate(
        _ consumer: SystemHealthSamplingConsumer,
        configurationID: String,
        automaticRefreshEnabled: Bool,
        preferredBaseInterval: TimeInterval
    ) async {
        activeConsumers.insert(consumer)
        guard appliedConfigurationID != configurationID else { return }

        stopAutomaticLoop()
        appliedConfigurationID = configurationID
        self.automaticRefreshEnabled = automaticRefreshEnabled
        self.preferredBaseInterval = preferredBaseInterval
        await loadPreferences()
        await tick()

        guard !Task.isCancelled,
              !activeConsumers.isEmpty,
              appliedConfigurationID == configurationID,
              automaticRefreshEnabled else { return }
        startAutomaticLoop(configurationID: configurationID)
    }

    /// 只移除调用方自身；最后一个消费者退出时才停止并清除配置身份。
    func deactivate(_ consumer: SystemHealthSamplingConsumer) {
        guard activeConsumers.remove(consumer) != nil else { return }
        guard activeConsumers.isEmpty else { return }
        stopAutomaticLoop()
        appliedConfigurationID = nil
        automaticRefreshEnabled = false
    }

    var activeConsumerCount: Int { activeConsumers.count }
    var hasActiveSamplingLoop: Bool { loopTask != nil }
    var appliedRefreshConfigurationID: String? { appliedConfigurationID }

    private func startAutomaticLoop(configurationID: String) {
        guard loopTask == nil,
              automaticRefreshEnabled,
              !activeConsumers.isEmpty else { return }
        let sleep = loopSleep
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.currentInterval()
                await sleep(interval)
                guard !Task.isCancelled,
                      self.automaticRefreshEnabled,
                      !self.activeConsumers.isEmpty,
                      self.appliedConfigurationID == configurationID else { return }
                await self.tick()
            }
        }
    }

    private func stopAutomaticLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refreshNow() async {
        await tick()
    }

    /// 只读加载偏好与趋势，不采样。设置页用它避免重复启动采样循环。
    func loadPersistedState() async {
        await loadPreferences()
    }

    private func loadPreferences() async {
        preferences = await reminderEngine.currentPreferences()
        storageLocation = await trendStore.storageLocation
        let storedTrends = await trendStore.current()
        if !isClearingTrends {
            trends = storedTrends
        }
    }

    private func currentInterval() -> TimeInterval {
        let context = RefreshContext(
            isForeground: NSApplication.shared.isActive,
            isScreenLocked: sample?.screenLocked ?? false,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isScanning: isScanning()
        )
        // C-a：用户档位作为基础间隔参与取最宽；未绑定（自动档）时为冻结的前台基础间隔。
        return AdaptiveRefreshPolicy.interval(for: context, baseInterval: preferredBaseInterval)
    }

    private func tick() async {
        guard !isSampling, !isClearingTrends else { return }
        isSampling = true
        defer { isSampling = false }
        let trendGenerationAtStart = trendMutationGeneration

        let context = RefreshContext(
            isForeground: NSApplication.shared.isActive,
            isScreenLocked: false,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isScanning: isScanning()
        )
        let captured = await sampler.sample()
        guard !Task.isCancelled else { return }
        let effectiveContext = RefreshContext(
            isForeground: context.isForeground,
            isScreenLocked: captured.screenLocked,
            isLowPowerMode: context.isLowPowerMode,
            isScanning: context.isScanning
        )
        // 缺陷 G 修复（三次返工）：显示值与 currentInterval() 同源——同样传入用户档位基础间隔，
        // 否则固定档下界面会按默认 5 秒显示而实际按档位采样。
        refreshInterval = AdaptiveRefreshPolicy.interval(for: effectiveContext, baseInterval: preferredBaseInterval)
        refreshReason = AdaptiveRefreshPolicy.reason(for: effectiveContext)

        sample = captured
        cpuWindow.append((captured.capturedAt, captured.cpuLoad))
        cpuWindow.removeAll { $0.0 < captured.capturedAt.addingTimeInterval(-SystemHealthSemantics.sustainedWindowSeconds) }
        sustainedLoad = SustainedLoadState.evaluate(samples: cpuWindow.map(\.1))
        storagePressure = StoragePressureLevel.evaluate(freeRatio: captured.volumeFreeRatio)

        if trendGenerationAtStart == trendMutationGeneration, !isClearingTrends {
            await trendStore.record(captured)
            if trendGenerationAtStart == trendMutationGeneration, !isClearingTrends {
                let storedTrends = await trendStore.current()
                trendPersistDegraded = await trendStore.currentPersistFailure() != nil
                if trendGenerationAtStart == trendMutationGeneration, !isClearingTrends {
                    trends = storedTrends
                }
            } else {
                // 清空可能在 actor 写入等待期间发生；再次清空，禁止旧采样在存储层复活。
                do {
                    _ = try await trendStore.clear()
                } catch {
                    // SC-4 R2：复活防护清空失败不得伪装成功——置可重试反馈；
                    // 真实数据状态由在途清空任务自身的失败分支按 generation 守卫恢复。
                    trendClearFailed = true
                }
            }
        }
        let due = await reminderEngine.ingest(captured)
        if !due.isEmpty { reminders.append(contentsOf: due) }
        evidenceCards = makeEvidenceCards(for: captured)
    }

    // MARK: - 评分（SC-4.1：运行时间与核心数退出扣分；CPU 与内存按持续/压力事实扣分）

    /// 扣分只来自四类事实：存储压力、持续高负载、内存压力、网络未连接。
    /// **不**由单次 CPU 峰值、内存占用率、运行时间或核心数产生扣分。
    var healthScore: Int {
        guard let sample else { return 96 }
        var score = 96
        switch storagePressure {
        case .tight: score -= 18
        case .low: score -= 8
        case .ample, .unavailable: break
        }
        if sustainedLoad == .sustained { score -= 12 }
        switch sample.memoryPressure {
        case .warning: score -= 8
        case .critical: score -= 16
        case .normal, .unavailable: break
        }
        if !sample.network.isConnected { score -= 5 }
        return max(35, score)
    }

    var healthTitle: String {
        switch healthScore {
        case 90...: String(localized: "状态出色")
        case 70..<90: String(localized: "状态良好")
        default: String(localized: "需要关注")
        }
    }

    /// 评分依据必须可读：逐条列出实际生效的扣分项。
    var scoreBasis: String {
        guard let sample else { return String(localized: "尚未采样") }
        var parts: [String] = []
        switch storagePressure {
        case .tight: parts.append(String(localized: "存储紧张 −18"))
        case .low: parts.append(String(localized: "存储偏低 −8"))
        case .ample, .unavailable: break
        }
        if sustainedLoad == .sustained { parts.append(String(localized: "持续高负载 −12")) }
        switch sample.memoryPressure {
        case .warning: parts.append(String(localized: "内存压力偏高 −8"))
        case .critical: parts.append(String(localized: "内存压力严重 −16"))
        case .normal, .unavailable: break
        }
        if !sample.network.isConnected { parts.append(String(localized: "网络未连接 −5")) }
        if parts.isEmpty { return String(localized: "当前没有生效的扣分项") }
        return String(localized: "评分依据：\(parts.joined(separator: String(localized: "、")))；单次峰值、内存占用率、运行时间与核心数均不参与扣分。")
    }

    // MARK: - 证据卡（五要素齐备）

    private func makeEvidenceCards(for sample: SystemHealthSample) -> [HealthEvidenceCard] {
        [
            memoryCard(sample),
            cpuCard(sample),
            storageCard(sample),
            batteryCard(sample)
        ]
    }

    private func memoryCard(_ sample: SystemHealthSample) -> HealthEvidenceCard {
        let pressure = sample.memoryPressure
        let value = String(localized: "\(pressure.title)（原始档位 \(sample.memoryPressureRawValue.map(String.init) ?? String(localized: "不可得"))）")
        let basis = String(localized: "判据为系统内存压力事实 kern.memorystatus_vm_pressure_level；占用率 \(SystemHealthFormatters.percent(sample.memoryUsedRatio)) 与压缩 \(SystemHealthFormatters.bytes(Int64(sample.compressorBytes))) 仅作证据，不参与档位判定。")
        let duration = String(localized: "本档位自最近一次采样起生效；窗口 \(SystemHealthFormatters.duration(SystemHealthSemantics.sustainedWindowSeconds))")
        let recommendation: HealthRecommendation
        switch pressure {
        case .normal:
            recommendation = HealthRecommendation(
                action: String(localized: "无需操作"),
                canSolve: String(localized: "说明当前没有系统级内存压力。"),
                cannotSolve: String(localized: "不能解释个别应用自身的内存占用感受。"),
                target: .evidenceCard
            )
        case .warning, .critical:
            recommendation = HealthRecommendation(
                action: String(localized: "关闭暂时不用的重型应用后再次查看证据卡"),
                canSolve: String(localized: "减少系统内存压力，让压缩与交换回落。"),
                cannotSolve: String(localized: "不会清理磁盘空间，也不会删除任何文件。"),
                target: .evidenceCard
            )
        case .unavailable:
            recommendation = HealthRecommendation(
                action: String(localized: "暂不判断，稍后重试采样"),
                canSolve: String(localized: "避免在数据不可得时给出错误结论。"),
                cannotSolve: String(localized: "无法在此状态下给出任何内存档位。"),
                target: .evidenceCard
            )
        }
        return HealthEvidenceCard(
            id: "memory",
            category: String(localized: "内存压力"),
            symbol: "memorychip",
            evidence: HealthEvidence(
                value: value,
                basis: basis,
                duration: duration,
                updatedAt: sample.capturedAt,
                recommendation: recommendation
            )
        )
    }

    private func cpuCard(_ sample: SystemHealthSample) -> HealthEvidenceCard {
        let state = sustainedLoad
        let value = String(localized: "当前负载 \(SystemHealthFormatters.percent(sample.cpuLoad)) · \(state.title)")
        let basis = String(localized: "持续判据：窗口 \(SystemHealthFormatters.duration(SystemHealthSemantics.sustainedWindowSeconds)) 内至少 \(SystemHealthSemantics.sustainedMinimumSamples) 个样本、其中 ≥\(Int(SystemHealthSemantics.sustainedSampleRatio * 100))% 达到 \(SystemHealthFormatters.percent(SystemHealthSemantics.sustainedLoadThreshold))；单次峰值不参与判定。")
        let duration = String(localized: "窗口内有效样本 \(cpuWindow.count) 个（核心数 \(sample.processorCount) 不参与健康扣分）")
        let recommendation: HealthRecommendation
        switch state {
        case .sampling:
            recommendation = HealthRecommendation(
                action: String(localized: "继续采样，暂不判断"),
                canSolve: String(localized: "避免用单个样本推断持续状态。"),
                cannotSolve: String(localized: "采样完成前不能给出持续负载结论。"),
                target: .evidenceCard
            )
        case .steady:
            recommendation = HealthRecommendation(
                action: String(localized: "无需操作"),
                canSolve: String(localized: "说明最近窗口内没有持续高负载。"),
                cannotSolve: String(localized: "不能代表更长时段或单个应用的表现。"),
                target: .evidenceCard
            )
        case .sustained:
            recommendation = HealthRecommendation(
                action: String(localized: "在活动监视器中确认具体进程"),
                canSolve: String(localized: "定位是哪个应用造成持续负载。"),
                cannotSolve: String(localized: "不会结束任何进程，也不会清理缓存。"),
                target: .evidenceCard
            )
        }
        return HealthEvidenceCard(
            id: "cpu",
            category: String(localized: "CPU 持续状态"),
            symbol: "cpu",
            evidence: HealthEvidence(
                value: value,
                basis: basis,
                duration: duration,
                updatedAt: sample.capturedAt,
                recommendation: recommendation
            )
        )
    }

    private func storageCard(_ sample: SystemHealthSample) -> HealthEvidenceCard {
        let link = spaceAnalysisLink()
        let freeRatio = sample.volumeFreeRatio
        let value = String(localized: "\(storagePressure.title) · 可用 \(SystemHealthFormatters.bytes(sample.volumeFreeBytes)) / 共 \(SystemHealthFormatters.bytes(sample.volumeTotalBytes))") + (freeRatio.map { String(localized: "（\(SystemHealthFormatters.percent($0))）") } ?? String(localized: "（比例不可得）"))
        let basis = String(localized: "判据为卷可用容量比例：≥20% 充足、10%–20% 偏低、<10% 紧张。空间分析结果只作**只读**引用，不触发扫描。\(link.note)")
        let duration = String(localized: "容量为即时读数；\(link.hasResult ? String(localized: "空间分析结果时间 \(link.finishedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "未知"))") : String(localized: "尚无空间分析结果"))")
        let recommendation: HealthRecommendation
        switch storagePressure {
        case .ample:
            recommendation = HealthRecommendation(
                action: String(localized: "无需操作"),
                canSolve: String(localized: "说明可用容量充足。"),
                cannotSolve: String(localized: "不能预测未来的容量变化。"),
                target: .spaceCleanup
            )
        case .low, .tight:
            recommendation = HealthRecommendation(
                action: link.hasResult ? String(localized: "在「空间清理」查看统计结果后逐项决定") : String(localized: "先在「空间清理」做一次只读分析"),
                canSolve: String(localized: "先把事实看清楚，再决定是否处理个别项目。"),
                cannotSolve: String(localized: "不会自动删除任何文件；本应用只把逐项确认的项目移入废纸篓。"),
                target: .spaceCleanup
            )
        case .unavailable:
            recommendation = HealthRecommendation(
                action: String(localized: "暂不判断，稍后重试采样"),
                canSolve: String(localized: "避免在容量不可得时给出错误结论。"),
                cannotSolve: String(localized: "无法在此状态下给出存储压力档位。"),
                target: .evidenceCard
            )
        }
        return HealthEvidenceCard(
            id: "storage",
            category: String(localized: "存储压力"),
            symbol: "internaldrive",
            evidence: HealthEvidence(
                value: value,
                basis: basis,
                duration: duration,
                updatedAt: sample.capturedAt,
                recommendation: recommendation
            )
        )
    }

    private func batteryCard(_ sample: SystemHealthSample) -> HealthEvidenceCard {
        let battery = sample.battery
        let value: String
        if let battery {
            value = String(localized: "\(SystemHealthFormatters.percent(battery.level)) · \(battery.isCharging ? String(localized: "正在充电") : String(localized: "未充电"))")
        } else {
            value = String(localized: "电池状态不可得（本机可能为台式机）")
        }
        let basis = String(localized: "判据为电源状态接口读取的电量与充电状态；低电量模式\(sample.lowPowerModeEnabled ? String(localized: "已开启") : String(localized: "未开启"))。")
        let duration = battery == nil ? String(localized: "无电池数据") : String(localized: "即时读数")
        let recommendation = HealthRecommendation(
            action: battery == nil ? String(localized: "无需操作") : String(localized: "按需接通电源"),
            canSolve: battery == nil ? String(localized: "说明本机没有可读取的电池。") : String(localized: "补充电量，避免中途断电。"),
            cannotSolve: String(localized: "不会改变系统电源策略，也不会清理任何数据。"),
            target: .batteryStatus
        )
        return HealthEvidenceCard(
            id: "battery",
            category: String(localized: "电池状态"),
            symbol: "battery.50",
            evidence: HealthEvidence(
                value: value,
                basis: basis,
                duration: duration,
                updatedAt: sample.capturedAt,
                recommendation: recommendation
            )
        )
    }

    // MARK: - 趋势与提醒

    func series(_ series: SystemHealthTrendSeries) -> [SystemHealthTrendPoint] {
        trends.points(for: series)
    }

    func hasEnoughPoints(for series: SystemHealthTrendSeries) -> Bool {
        trends.hasEnoughPoints(for: series)
    }

    func setReminderEnabled(_ value: Bool, for kind: SystemHealthReminderKind) {
        Task { [weak self] in
            guard let self else { return }
            await reminderEngine.setEnabled(value, for: kind)
            preferences = await reminderEngine.currentPreferences()
        }
    }

    func clearTrends() {
        trendMutationGeneration &+= 1
        let generation = trendMutationGeneration
        isClearingTrends = true
        trendClearFailed = false
        trends = .empty
        Task { [weak self] in
            guard let self else { return }
            do {
                let cleared = try await self.trendStore.clear()
                guard generation == self.trendMutationGeneration else { return }
                self.trends = cleared
                self.trendPersistDegraded = false
                self.isClearingTrends = false
            } catch {
                guard generation == self.trendMutationGeneration else { return }
                // SC-4 R2：持久化失败不得伪装成功——恢复真实存储状态并给出可重试反馈。
                self.trends = await self.trendStore.current()
                self.trendClearFailed = true
                self.isClearingTrends = false
            }
        }
    }

    func dismissReminder(_ reminder: SystemHealthReminder) {
        reminders.removeAll { $0.id == reminder.id }
    }
}

struct HealthEvidenceCard: Identifiable, Equatable {
    let id: String
    let category: String
    let symbol: String
    let evidence: HealthEvidence
}
