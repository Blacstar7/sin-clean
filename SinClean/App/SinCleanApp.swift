import SwiftUI
import Darwin

@main
enum SinCleanEntryPoint {
    @MainActor
    static func main() {
        guard UpdateRelaunchGate.enter() else { exit(64) }
        SinCleanApp.main()
    }
}

struct SinCleanApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var navigation = AppNavigationState()
    @StateObject private var spaceAnalysisScopes = SpaceAnalysisScopeViewModel()
    @StateObject private var spaceAnalysisResults: SpaceAnalysisResultsViewModel
    @StateObject private var spaceAnalysisTrash: SpaceAnalysisTrashViewModel
    @StateObject private var systemHealth: SystemHealthDashboardViewModel
    @StateObject private var onboarding: OnboardingViewModel
    @StateObject private var permissionStatus = PermissionStatusViewModel()
    /// SC-7 通知权限生产接线：应用级投递协调器（共享实例）；申请只由用户在设置页
    /// 开启提醒并确认说明后触发，启动与首次使用不申请。
    @StateObject private var notificationDelivery = SystemNotificationDelivery()
    @StateObject private var ignoreList: IgnoreListStore
    @Environment(\.openWindow) private var openWindow
    private let operationHistoryStore: OperationHistoryStore
    /// SC-PD2：空间变化历史存储（共享实例；主窗口面板与设置页清除入口共用同一状态）。
    private let spaceChangeHistory: SpaceChangeHistoryStore

    init() {
        operationHistoryStore = OperationHistoryStore()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let usesIsolatedHealthPersistence = arguments.contains { $0.contains("preview") }
        _systemHealth = StateObject(wrappedValue: usesIsolatedHealthPersistence
            ? SystemHealthDashboardViewModel.isolatedPreview()
            : SystemHealthDashboardViewModel())
        if ProcessInfo.processInfo.arguments.contains("--sc22-plan-export-preview")
            || ProcessInfo.processInfo.arguments.contains("--sc23-execution-receipt-preview")
            || ProcessInfo.processInfo.arguments.contains("--sc24-operation-history-preview")
            || ProcessInfo.processInfo.arguments.contains("--sc31-information-architecture-preview")
            || ProcessInfo.processInfo.arguments.contains("--sc32-space-analysis-preview")
            || ProcessInfo.processInfo.arguments.contains("--sc33-space-analysis-preview")
            || ProcessInfo.processInfo.arguments.contains("--sc35-space-analysis-trash-preview")
            || ProcessInfo.processInfo.arguments.contains("--scpd1-diagnosis-preview")
            || ProcessInfo.processInfo.arguments.contains("--scpd2-change-preview")
            || ProcessInfo.processInfo.arguments.contains("--scpd3-footprint-preview")
            || ProcessInfo.processInfo.arguments.contains("--sc4-system-health-preview")
            || ProcessInfo.processInfo.arguments.contains("--sc5-onboarding-preview") {
            // SC-PD2：任何 DEBUG 预览态一律使用内存历史存储（/Preview/ 假路径），
            // 防止渲染 SpaceCleanupView 的既有预览把 stub 扫描写进真实 Application Support。
            spaceChangeHistory = SpaceChangeHistoryStore(
                fileAccess: SCPD2IsolatedPreviewFileAccess(),
                paths: SpaceChangeStoragePaths(
                    baseDirectory: URL(fileURLWithPath: "/Preview/Storage", isDirectory: true)
                )
            )
            let store = IgnoreListStore(
                repository: InMemoryIgnoreRuleRepository(),
                autoload: false
            )
            _ignoreList = StateObject(wrappedValue: store)
            _spaceAnalysisResults = StateObject(wrappedValue: SpaceAnalysisResultsViewModel(ignoreList: store))
            _spaceAnalysisTrash = StateObject(wrappedValue: SpaceAnalysisTrashViewModel(ignoreList: store))
            _onboarding = StateObject(wrappedValue: OnboardingViewModel(
                store: InMemoryOnboardingCompletionStore(completed: true)
            ))
        } else {
            spaceChangeHistory = SpaceChangeHistoryStore()
            let store = IgnoreListStore()
            _ignoreList = StateObject(wrappedValue: store)
            _spaceAnalysisResults = StateObject(wrappedValue: SpaceAnalysisResultsViewModel(ignoreList: store))
            _spaceAnalysisTrash = StateObject(wrappedValue: SpaceAnalysisTrashViewModel(ignoreList: store))
            _onboarding = StateObject(wrappedValue: OnboardingViewModel())
        }
        #else
        _systemHealth = StateObject(wrappedValue: SystemHealthDashboardViewModel())
        spaceChangeHistory = SpaceChangeHistoryStore()
        let store = IgnoreListStore()
        _ignoreList = StateObject(wrappedValue: store)
        _spaceAnalysisResults = StateObject(wrappedValue: SpaceAnalysisResultsViewModel(ignoreList: store))
        _spaceAnalysisTrash = StateObject(wrappedValue: SpaceAnalysisTrashViewModel(ignoreList: store))
        _onboarding = StateObject(wrappedValue: OnboardingViewModel())
        #endif
    }

    private var presentsMenuPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--preview-menu-panel")
        #else
        false
        #endif
    }

    /// SC-5 二次返工（C-a）：设置页「刷新间隔」档位的真实界面预览。
    private var presentsRefreshSettingsPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc5-refresh-settings-preview")
        #else
        false
        #endif
    }

    private var presentsCandidateDetailPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc13-candidate-detail-preview")
        #else
        false
        #endif
    }

    private var presentsUninstallEvidencePreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc14-uninstall-evidence-preview")
        #else
        false
        #endif
    }

    private var presentsIgnoreListPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc15-ignore-preview")
        #else
        false
        #endif
    }

    private var presentsPlanExportPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc22-plan-export-preview")
        #else
        false
        #endif
    }

    private var presentsExecutionReceiptPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc23-execution-receipt-preview")
        #else
        false
        #endif
    }

    private var presentsOperationHistoryPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc24-operation-history-preview")
        #else
        false
        #endif
    }

    private var presentsInformationArchitecturePreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc31-information-architecture-preview")
        #else
        false
        #endif
    }

    private var presentsSpaceAnalysisScopePreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc32-space-analysis-preview")
        #else
        false
        #endif
    }

    private var presentsSpaceAnalysisResultsPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc33-space-analysis-preview")
        #else
        false
        #endif
    }

    private var presentsOnboardingPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc5-onboarding-preview")
        #else
        false
        #endif
    }

    private var presentsSystemHealthPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc4-system-health-preview")
        #else
        false
        #endif
    }

    private var presentsSpaceAnalysisTrashPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--sc35-space-analysis-trash-preview")
        #else
        false
        #endif
    }

    /// SC-PD1：存储去向诊断五态预览（完整／部分／无突出／取消／空结果）。
    private var presentsPD1DiagnosisPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--scpd1-diagnosis-preview")
        #else
        false
        #endif
    }

    /// SC-PD2：空间变化八态预览（首次／增长／缩小／无明显变化／不可比较／记录关闭／损坏／清除确认）。
    private var presentsPD2ChangePreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--scpd2-change-preview")
        #else
        false
        #endif
    }

    private var presentsPD3FootprintPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--scpd3-footprint-preview")
        #else
        false
        #endif
    }

    #if DEBUG
    private var candidateDetailPreviewMode: SC13CandidateDetailPreview.Mode {
        if ProcessInfo.processInfo.arguments.contains("--sc13-preview-empty") { return .empty }
        if ProcessInfo.processInfo.arguments.contains("--sc13-preview-stale") { return .stale }
        return .detail
    }

    private var spaceAnalysisScopePreviewMode: SC32SpaceAnalysisScopePreview.Mode {
        if ProcessInfo.processInfo.arguments.contains("--sc32-preview-selected") { return .selected }
        if ProcessInfo.processInfo.arguments.contains("--sc32-preview-conflict") { return .conflict }
        if ProcessInfo.processInfo.arguments.contains("--sc32-preview-duplicate") { return .duplicate }
        return .empty
    }

    private var spaceAnalysisResultsPreviewMode: SC33SpaceAnalysisPreview.Mode {
        if ProcessInfo.processInfo.arguments.contains("--sc33-preview-scanning") { return .scanning }
        if ProcessInfo.processInfo.arguments.contains("--sc33-preview-results") { return .results }
        if ProcessInfo.processInfo.arguments.contains("--sc33-preview-partial") { return .partial }
        if ProcessInfo.processInfo.arguments.contains("--sc33-preview-cancelled") { return .cancelled }
        if ProcessInfo.processInfo.arguments.contains("--sc34-preview-hardlink") { return .hardlink }
        if ProcessInfo.processInfo.arguments.contains("--sc34-preview-clone") { return .clone }
        if ProcessInfo.processInfo.arguments.contains("--sc34-preview-dataless") { return .dataless }
        if ProcessInfo.processInfo.arguments.contains("--sc34-preview-crossvolume") { return .crossVolume }
        return .idle
    }

    private var onboardingPreviewMode: SC5OnboardingPreview.Mode {
        if ProcessInfo.processInfo.arguments.contains("--sc5-preview-step2") { return .onboardingSecond }
        if ProcessInfo.processInfo.arguments.contains("--sc5-preview-step3") { return .onboardingThird }
        if ProcessInfo.processInfo.arguments.contains("--sc5-preview-denied") { return .permissionDenied }
        if ProcessInfo.processInfo.arguments.contains("--sc5-preview-visible") { return .permissionVisible }
        if ProcessInfo.processInfo.arguments.contains("--sc5-preview-privacy") { return .privacy }
        if ProcessInfo.processInfo.arguments.contains("--sc5-preview-revoked") { return .revoked }
        if ProcessInfo.processInfo.arguments.contains("--sc5-preview-recheck") { return .permissionRecheck }
        return .onboardingFirst
    }

    private var systemHealthPreviewMode: SC4SystemHealthPreview.Mode {
        if ProcessInfo.processInfo.arguments.contains("--sc4-preview-sustained") { return .evidenceSustained }
        if ProcessInfo.processInfo.arguments.contains("--sc4-preview-nodata") { return .evidenceNoData }
        // SC-4 R3（b14）：隔离故障注入预览——须先于 --sc4-preview-trend 判定（参数为其前缀超集）。
        if ProcessInfo.processInfo.arguments.contains("--sc4-preview-trend-failures") { return .trendFailures }
        if ProcessInfo.processInfo.arguments.contains("--sc4-preview-trend") { return .trendWithData }
        if ProcessInfo.processInfo.arguments.contains("--sc4-preview-trendnodata") { return .trendNoData }
        if ProcessInfo.processInfo.arguments.contains("--sc4-preview-settings") { return .reminderSettings }
        return .evidenceNormal
    }

    private var spaceAnalysisTrashPreviewMode: SC35SpaceAnalysisTrashPreview.Mode {
        if ProcessInfo.processInfo.arguments.contains("--sc35-preview-selected") { return .selected }
        if ProcessInfo.processInfo.arguments.contains("--sc35-preview-executing") { return .executing }
        if ProcessInfo.processInfo.arguments.contains("--sc35-preview-partial") { return .partialFailure }
        if ProcessInfo.processInfo.arguments.contains("--sc35-preview-succeeded") { return .succeeded }
        if ProcessInfo.processInfo.arguments.contains("--sc35-preview-cancelled") { return .cancelled }
        return .unselected
    }

    private var pd1DiagnosisPreviewMode: SCPD1SpaceAnalysisDiagnosisPreview.Mode {
        if ProcessInfo.processInfo.arguments.contains("--scpd1-preview-partial") { return .partial }
        if ProcessInfo.processInfo.arguments.contains("--scpd1-preview-none") { return .none }
        if ProcessInfo.processInfo.arguments.contains("--scpd1-preview-cancelled") { return .cancelled }
        if ProcessInfo.processInfo.arguments.contains("--scpd1-preview-empty") { return .empty }
        return .full
    }

    private var pd2ChangePreviewMode: SCPD2SpaceChangePreview.Mode {
        if ProcessInfo.processInfo.arguments.contains("--scpd2-preview-first") { return .first }
        if ProcessInfo.processInfo.arguments.contains("--scpd2-preview-shrink") { return .shrink }
        if ProcessInfo.processInfo.arguments.contains("--scpd2-preview-nochange") { return .noChange }
        if ProcessInfo.processInfo.arguments.contains("--scpd2-preview-notcomparable") { return .notComparable }
        if ProcessInfo.processInfo.arguments.contains("--scpd2-preview-disabled") { return .disabled }
        if ProcessInfo.processInfo.arguments.contains("--scpd2-preview-damaged") { return .damaged }
        if ProcessInfo.processInfo.arguments.contains("--scpd2-preview-clearconfirm") { return .clearConfirm }
        return .growth
    }

    private var pd3FootprintPreviewMode: SCPD3AppFootprintPreview.Mode {
        if ProcessInfo.processInfo.arguments.contains("--scpd3-preview-partial") { return .partial }
        if ProcessInfo.processInfo.arguments.contains("--scpd3-preview-cannotjudge") { return .cannotJudge }
        if ProcessInfo.processInfo.arguments.contains("--scpd3-preview-assocoff") { return .associationOff }
        if ProcessInfo.processInfo.arguments.contains("--scpd3-preview-bodyfailed") { return .bodyFailed }
        if ProcessInfo.processInfo.arguments.contains("--scpd3-preview-rechecknone") { return .recheckNone }
        if ProcessInfo.processInfo.arguments.contains("--scpd3-preview-recheckfound") { return .recheckFound }
        return .full
    }
    #endif

    var body: some Scene {
        WindowGroup("Sin Clean", id: "main") {
            Group {
                #if DEBUG
                if presentsOnboardingPreview {
                    SC5OnboardingPreview(mode: onboardingPreviewMode)
                } else if presentsSystemHealthPreview {
                    SC4SystemHealthPreview(mode: systemHealthPreviewMode)
                } else if presentsSpaceAnalysisTrashPreview {
                    SC35SpaceAnalysisTrashPreview(mode: spaceAnalysisTrashPreviewMode)
                } else if presentsPD1DiagnosisPreview {
                    SCPD1SpaceAnalysisDiagnosisPreview(mode: pd1DiagnosisPreviewMode)
                } else if presentsPD2ChangePreview {
                    SCPD2SpaceChangePreview(mode: pd2ChangePreviewMode)
                } else if presentsPD3FootprintPreview {
                    SCPD3AppFootprintPreview(mode: pd3FootprintPreviewMode)
                } else if presentsSpaceAnalysisResultsPreview {
                    SC33SpaceAnalysisPreview(mode: spaceAnalysisResultsPreviewMode)
                } else if presentsSpaceAnalysisScopePreview {
                    SC32SpaceAnalysisScopePreview(mode: spaceAnalysisScopePreviewMode)
                } else if presentsInformationArchitecturePreview {
                    SC31InformationArchitecturePreview()
                } else if presentsOperationHistoryPreview {
                    SC24OperationHistoryPreview()
                } else if presentsExecutionReceiptPreview {
                    SC23ExecutionReceiptPreview()
                } else if presentsPlanExportPreview {
                    SC22PlanExportPreview()
                } else if presentsIgnoreListPreview {
                    SC15IgnoreListPreview()
                } else if presentsUninstallEvidencePreview {
                    SC14UninstallEvidencePreview()
                } else if presentsCandidateDetailPreview {
                    SC13CandidateDetailPreview(mode: candidateDetailPreviewMode)
                } else if presentsRefreshSettingsPreview {
                    SC5RefreshSettingsPreview()
                } else if presentsMenuPreview {
                    MenuBarPanelView(viewModel: systemHealth)
                } else {
                    RootView(
                        healthViewModel: systemHealth,
                        operationHistoryStore: operationHistoryStore
                    )
                }
                #else
                if presentsMenuPreview {
                    MenuBarPanelView(viewModel: systemHealth)
                } else {
                    RootView(
                        healthViewModel: systemHealth,
                        operationHistoryStore: operationHistoryStore
                    )
                }
                #endif
            }
            .environmentObject(settings)
            .environmentObject(navigation)
            .environmentObject(ignoreList)
            .environmentObject(spaceAnalysisScopes)
            .environmentObject(spaceAnalysisResults)
            .environmentObject(spaceAnalysisTrash)
            .environmentObject(onboarding)
            .environmentObject(permissionStatus)
            .environmentObject(notificationDelivery)
            .environmentObject(spaceChangeHistory)
        }
        .defaultSize(
            width: presentsOperationHistoryPreview ? 1_320 : (presentsExecutionReceiptPreview ? 1_300 : (presentsPlanExportPreview ? 1_260 : (presentsIgnoreListPreview ? 1_420 : (presentsCandidateDetailPreview ? 1_020 : (presentsSystemHealthPreview ? 1_340 : (presentsMenuPreview ? 452 : 1_180)))))),
            // SC-4 预览需要完整展示证据卡、趋势与提醒区，故使用更高的窗口；
            // 真实应用窗口仍为默认尺寸并可滚动。
            height: presentsOperationHistoryPreview ? 900 : (presentsExecutionReceiptPreview ? 900 : (presentsPlanExportPreview ? 860 : (presentsIgnoreListPreview ? 860 : (presentsCandidateDetailPreview ? 700 : (presentsSystemHealthPreview ? 1_720 : 760)))))
        )
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // SC-6 正式包装（冻结语义 §6.2）：替换标准 About 命令，打开关于窗口。
            CommandGroup(replacing: .appInfo) {
                Button("关于 Sin Clean") {
                    openWindow(id: "about")
                }
            }
        }

        Window("关于 Sin Clean", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(healthViewModel: systemHealth)
                .environmentObject(settings)
                .environmentObject(ignoreList)
                .environmentObject(onboarding)
                .environmentObject(notificationDelivery)
                .environmentObject(spaceChangeHistory)
        }

        MenuBarExtra {
            MenuBarPanelView(viewModel: systemHealth)
                .environmentObject(settings)
                .environmentObject(navigation)
        } label: {
            // SC-Rework-UI-Visual I2：冻结品牌菜单栏模板符号（WEB-B2，22/44pt，template 由系统随菜单栏明暗自适应）
            Image("MenuBarSymbol")
                .accessibilityLabel("Sin Clean")
        }
        .menuBarExtraStyle(.window)
    }
}

#if DEBUG
/// SC-PD2 预览隔离：DEBUG 预览态共享的内存文件访问（/Preview/ 假路径），任何预览
/// 都不会读写真实 Application Support 的空间变化历史（ERR-20260920-090 同类隔离）。
final class SCPD2IsolatedPreviewFileAccess: SpaceChangeFileAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data]

    init(seeded: [String: Data] = [:]) {
        storage = seeded
    }

    func fileExists(at url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[url.path] != nil
    }

    func readData(from url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data = storage[url.path] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    func createDirectoryIfNeeded(at url: URL) throws {}

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[url.path] = data
    }
}
#endif
