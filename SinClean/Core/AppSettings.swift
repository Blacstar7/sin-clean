import Foundation

/// 状态监测刷新档位（SC-5 二次返工 C-a：让「刷新间隔」档位真正生效）。
/// - `automatic`：自适应（**默认值与首次使用值**），基础间隔＝冻结的前台基础间隔（5 秒）；
/// - 固定档：所选间隔作为**基础间隔**参与「多条件取最宽」——
///   后台／锁屏／低电量／扫描的放宽**仍然生效**（例：固定 30 秒 ＋ 锁屏 → 120 秒）。
enum DashboardRefreshPreference: String, CaseIterable, Identifiable {
    case automatic
    case thirtySeconds
    case sixtySeconds
    case fiveMinutes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "自动（自适应）")
        case .thirtySeconds: String(localized: "30 秒")
        case .sixtySeconds: String(localized: "1 分钟")
        case .fiveMinutes: String(localized: "5 分钟")
        }
    }

    /// 该档位参与取最宽规则的基础间隔；自动档＝冻结语义的前台基础间隔。
    var baseInterval: TimeInterval {
        switch self {
        case .automatic: SystemHealthSemantics.foregroundSampleSeconds
        case .thirtySeconds: 30
        case .sixtySeconds: 60
        case .fiveMinutes: 300
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let autoRefreshDashboard = "settings.autoRefreshDashboard"
        static let dashboardRefreshSeconds = "settings.dashboardRefreshSeconds"
        static let dashboardRefreshPreference = "settings.dashboardRefreshPreference"
        static let includeSystemApplications = "settings.includeSystemApplications"
        static let includeUserApplications = "settings.includeUserApplications"
        static let analyzeAssociatedComponents = "settings.analyzeAssociatedComponents"
        static let measurementConcurrency = "settings.measurementConcurrency"
        static let spaceChangeRecordingEnabled = "settings.spaceChangeRecordingEnabled"
    }

    /// 供预览与验证工具直接读写的档位键（与 `Key.dashboardRefreshPreference` 同一存储）。
    static let dashboardRefreshPreferenceKey = "settings.dashboardRefreshPreference"

    @Published var autoRefreshDashboard: Bool {
        didSet { store.set(autoRefreshDashboard, forKey: Key.autoRefreshDashboard) }
    }

    /// 刷新档位（C-a）。旧键 `dashboardRefreshSeconds`（30/60/300）从未被任何采样代码消费、
    /// 未形成用户预期，首次启动新版本时**一律迁移为「自动」**并清除旧键。
    @Published var dashboardRefreshPreference: DashboardRefreshPreference {
        didSet { store.set(dashboardRefreshPreference.rawValue, forKey: Key.dashboardRefreshPreference) }
    }

    /// 当前档位参与取最宽规则的基础间隔（供采样循环绑定）。
    var refreshBaseInterval: TimeInterval { dashboardRefreshPreference.baseInterval }

    @Published private(set) var includeSystemApplications: Bool {
        didSet { store.set(includeSystemApplications, forKey: Key.includeSystemApplications) }
    }
    @Published private(set) var includeUserApplications: Bool {
        didSet { store.set(includeUserApplications, forKey: Key.includeUserApplications) }
    }
    @Published var analyzeAssociatedComponents: Bool {
        didSet { store.set(analyzeAssociatedComponents, forKey: Key.analyzeAssociatedComponents) }
    }
    @Published var measurementConcurrency: Int {
        didSet { store.set(Self.validConcurrency(measurementConcurrency), forKey: Key.measurementConcurrency) }
    }

    /// SC-PD2：空间变化记录开关（默认开启）。关闭只停止新增记录，不删除既有记录；
    /// 开关变更只写本键，不触发扫描（work/SC-PD2-frozen-semantics.md §9.1／§11.5）。
    @Published var spaceChangeRecordingEnabled: Bool {
        didSet { store.set(spaceChangeRecordingEnabled, forKey: Key.spaceChangeRecordingEnabled) }
    }

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        autoRefreshDashboard = Self.boolValue(
            in: store,
            key: Key.autoRefreshDashboard,
            defaultValue: true
        )

        // C-a 旧值迁移：旧档位从未生效，一律迁移为「自动」；迁移后清除旧键（幂等）。
        if store.object(forKey: Key.dashboardRefreshSeconds) != nil,
           store.string(forKey: Key.dashboardRefreshPreference) == nil {
            store.set(DashboardRefreshPreference.automatic.rawValue, forKey: Key.dashboardRefreshPreference)
            store.removeObject(forKey: Key.dashboardRefreshSeconds)
        }
        dashboardRefreshPreference = store.string(forKey: Key.dashboardRefreshPreference)
            .flatMap(DashboardRefreshPreference.init(rawValue:)) ?? .automatic

        #if DEBUG
        // 预览专用：仅在本实例内覆盖档位（init 内赋值不触发 didSet，不写入存储）。
        let previewArguments = ProcessInfo.processInfo.arguments
        if previewArguments.contains("--sc5-preview-refresh-fixed30") {
            dashboardRefreshPreference = .thirtySeconds
        } else if previewArguments.contains("--sc5-preview-refresh-fixed60") {
            dashboardRefreshPreference = .sixtySeconds
        }
        #endif

        var storedSystemApplications = Self.boolValue(
            in: store,
            key: Key.includeSystemApplications,
            defaultValue: true
        )
        let storedUserApplications = Self.boolValue(
            in: store,
            key: Key.includeUserApplications,
            defaultValue: true
        )
        if !storedSystemApplications && !storedUserApplications {
            storedSystemApplications = true
            store.set(true, forKey: Key.includeSystemApplications)
        }
        includeSystemApplications = storedSystemApplications
        includeUserApplications = storedUserApplications
        analyzeAssociatedComponents = Self.boolValue(
            in: store,
            key: Key.analyzeAssociatedComponents,
            defaultValue: true
        )
        measurementConcurrency = Self.validConcurrency(
            store.object(forKey: Key.measurementConcurrency) as? Int ?? 4
        )
        spaceChangeRecordingEnabled = Self.boolValue(
            in: store,
            key: Key.spaceChangeRecordingEnabled,
            defaultValue: true
        )
    }

    var scanConfiguration: ApplicationScanConfiguration {
        ApplicationScanConfiguration(
            includeSystemApplications: includeSystemApplications,
            includeUserApplications: includeUserApplications,
            analyzeAssociatedComponents: analyzeAssociatedComponents,
            measurementConcurrency: Self.validConcurrency(measurementConcurrency)
        )
    }

    /// 档位变化会改变该标识，从而重启采样循环，使新档位立即生效。
    var dashboardRefreshTaskID: String {
        "\(autoRefreshDashboard)-\(dashboardRefreshPreference.rawValue)"
    }

    func setIncludeSystemApplications(_ isIncluded: Bool) {
        guard isIncluded || includeUserApplications else { return }
        includeSystemApplications = isIncluded
    }

    func setIncludeUserApplications(_ isIncluded: Bool) {
        guard isIncluded || includeSystemApplications else { return }
        includeUserApplications = isIncluded
    }

    func reset() {
        autoRefreshDashboard = true
        dashboardRefreshPreference = .automatic
        includeSystemApplications = true
        includeUserApplications = true
        analyzeAssociatedComponents = true
        measurementConcurrency = 4
        spaceChangeRecordingEnabled = true
    }

    private static func boolValue(
        in store: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        store.object(forKey: key) == nil ? defaultValue : store.bool(forKey: key)
    }

    private static func validConcurrency(_ value: Int) -> Int {
        [2, 4, 6].contains(value) ? value : 4
    }
}
