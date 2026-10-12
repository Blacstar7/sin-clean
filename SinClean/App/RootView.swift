import Combine
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case cleanup
    case uninstaller
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: String(localized: "Mac 状态")
        case .cleanup: String(localized: "空间清理")
        case .uninstaller: String(localized: "深度卸载")
        case .settings: String(localized: "设置")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: String(localized: "健康概览")
        case .cleanup: String(localized: "项目与分析")
        case .uninstaller: String(localized: "应用与残留")
        case .settings: String(localized: "偏好与权限")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cleanup: "internaldrive"
        case .uninstaller: "shippingbox"
        case .settings: "gearshape.2"
        }
    }

    var index: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

enum SpaceCleanupPage: String, CaseIterable, Identifiable {
    case cleanableItems
    case spaceAnalysis

    var id: Self { self }

    var title: String {
        switch self {
        case .cleanableItems: String(localized: "可清理项目")
        case .spaceAnalysis: String(localized: "空间分析")
        }
    }

    var symbol: String {
        switch self {
        case .cleanableItems: "sparkle.magnifyingglass"
        case .spaceAnalysis: "chart.bar.doc.horizontal"
        }
    }
}

@MainActor
final class AppNavigationState: ObservableObject {
    @Published private(set) var requestedSection: AppSection = .overview
    @Published private(set) var spaceCleanupPage: SpaceCleanupPage = .cleanableItems
    @Published private(set) var requestRevision: UInt64 = 0

    func request(_ section: AppSection) {
        requestedSection = section
        if section == .cleanup {
            spaceCleanupPage = .cleanableItems
        }
        requestRevision &+= 1
    }

    func selectSpaceCleanupPage(_ page: SpaceCleanupPage) {
        spaceCleanupPage = page
    }
}

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var navigation: AppNavigationState
    @EnvironmentObject private var ignoreList: IgnoreListStore
    /// SC-7：共享投递协调器——只订阅提醒流；申请与投递的入口都不在启动路径上。
    @EnvironmentObject private var notificationDelivery: SystemNotificationDelivery
    @State private var selection = AppSection.overview
    @State private var highlightedSection = AppSection.overview
    @State private var transitionDirection: CGFloat = 1
    @State private var sweepProgress: CGFloat = 1
    @State private var sweepOpacity = 0.0
    @State private var showsOperationHistory = false
    @Namespace private var navigationGlass
    private let operationHistoryStore: OperationHistoryStore
    @ObservedObject private var healthViewModel: SystemHealthDashboardViewModel

    init(
        healthViewModel: SystemHealthDashboardViewModel,
        operationHistoryStore: OperationHistoryStore = OperationHistoryStore()
    ) {
        _healthViewModel = ObservedObject(wrappedValue: healthViewModel)
        self.operationHistoryStore = operationHistoryStore
    }

    @EnvironmentObject private var onboarding: OnboardingViewModel

    var body: some View {
        ZStack {
            AuroraBackground()

            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 218, ideal: 232, max: 258)
            } detail: {
                ZStack(alignment: .topLeading) {
                    detail

                    SectionTransitionSweep(
                        progress: sweepProgress,
                        opacity: sweepOpacity,
                        direction: transitionDirection
                    )
                }
                .frame(minWidth: 760, minHeight: 590)
                .clipped()
            }
            .navigationSplitViewStyle(.balanced)
        }
        .tint(AppTheme.accent)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            selection = navigation.requestedSection
            highlightedSection = navigation.requestedSection
        }
        // SC-7 通知权限生产接线：把共享仪表盘提醒流接到投递协调器（幂等）。
        // 这里只订阅，不查询、不申请——授权动作只发生在用户开启提醒之后。
        .task {
            notificationDelivery.attach(reminders: healthViewModel.$reminders)
            #if DEBUG
            // SC-7 验证入口（仅调试构建；最终 Release 不含）：注入一条与生产同构的
            // 到期提醒，走与生产一致的投递路径，用于在不诱发真实高负载／低磁盘
            // 条件的前提下取得真实投递证据。
            if ProcessInfo.processInfo.arguments.contains("--sc7-notification-delivery-preview") {
                await notificationDelivery.deliverFixtureReminderForVerification()
            }
            #endif
        }
        .onChange(of: navigation.requestRevision) { _, _ in
            select(navigation.requestedSection)
        }
        // SC-5：首次使用引导只自动出现一次（完成标记存在时不再出现）；
        // 引导本身不申请任何权限。
        .overlay {
            if onboarding.isPresented {
                ZStack {
                    AppTheme.obsidian.opacity(0.72)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                    OnboardingView(viewModel: onboarding)
                        .padding(AppTheme.Spacing.xl)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: 12) {
                // SC-Rework-UI-Visual R2 补完：品牌标识位改用 WEB-B2 冻结品牌 AppIcon 渲染。
                // 手册 §5.3 禁止品牌标识添加投影/发光/额外渐变；§4.2 遮罩由使用方自施加
                // （冻结 renders 为无遮罩方图，故此处自施加连续圆角）。40pt 下 mark 约 17pt ≥ 最小 16px。
                Image("BrandMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                // SC-Rework-UI-Visual R2 补完：移除副标题「曜石极光」——皮肤/主题内部命名
                // 不属于面向用户的品牌信息，界面仅保留产品名。
                Text("Sin Clean")
                    .font(.headline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            VStack(spacing: 6) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        navigation.request(section)
                    } label: {
                        ZStack {
                            if highlightedSection == section && !showsOperationHistory {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                AppTheme.accent.opacity(0.17),
                                                AppTheme.violet.opacity(0.12),
                                                Color.white.opacity(0.035)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(height: 54)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(
                                                LinearGradient(
                                                    colors: [.white.opacity(0.25), AppTheme.accent.opacity(0.18), .clear],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                ),
                                                lineWidth: 1
                                            )
                                    }
                                    .shadow(color: AppTheme.accent.opacity(0.08), radius: 7, y: 3)
                                    .matchedGeometryEffect(id: "navigation-lens", in: navigationGlass)
                            }

                            HStack(spacing: 12) {
                                Image(systemName: section.symbol)
                                    .font(.system(size: 17, weight: .medium))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 24)
                                    .symbolEffect(.bounce, value: highlightedSection == section && !showsOperationHistory)
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.title)
                                        .font(.body.weight(.semibold))
                                    Text(section.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(highlightedSection == section && !showsOperationHistory ? .secondary : .tertiary)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 13)
                            .frame(height: 54)
                        }
                        .frame(height: 54)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(section.title)，\(section.subtitle)")
                    .accessibilityAddTraits(highlightedSection == section && !showsOperationHistory ? .isSelected : [])
                }
            }

            Spacer(minLength: AppTheme.Spacing.md)
            Button {
                showsOperationHistory = true
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("操作记录")
                            .font(.callout.weight(.semibold))
                        Text("清理与卸载 · 只读")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .frame(height: 46)
                .background(showsOperationHistory ? AppTheme.accent.opacity(0.12) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("操作记录，清理与卸载只读记录")
            .accessibilityAddTraits(showsOperationHistory ? .isSelected : [])
            PrivacyNotice()
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .background(AppTheme.obsidian.opacity(0.22))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.14), AppTheme.accent.opacity(0.08), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if showsOperationHistory {
            OperationHistoryView(store: operationHistoryStore)
        } else {
            switch selection {
            case .overview:
                DashboardView(viewModel: healthViewModel)
            case .cleanup:
                SpaceCleanupView {
                    CleanupView(
                        ignoreList: ignoreList,
                        historyStore: CleanupOperationHistoryAdapter(store: operationHistoryStore)
                    )
                }
            case .uninstaller:
                UninstallerView(
                    ignoreList: ignoreList,
                    historyStore: UninstallOperationHistoryAdapter(store: operationHistoryStore)
                )
            case .settings:
                SettingsView(healthViewModel: healthViewModel, embedded: true)
            }
        }
    }

    private func select(_ section: AppSection) {
        if showsOperationHistory {
            showsOperationHistory = false
            selection = section
            highlightedSection = section
            return
        }
        guard section != selection else { return }
        transitionDirection = section.index > selection.index ? 1 : -1

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection = section
            sweepProgress = 0
            sweepOpacity = reduceMotion ? 0 : 1
        }

        guard !reduceMotion else {
            highlightedSection = section
            return
        }

        withAnimation(reduceMotion ? .linear(duration: 0.01) : AppTheme.Motion.selection) {
            highlightedSection = section
        }
        withAnimation(AppTheme.Motion.sectionSweep) {
            sweepProgress = 1
            sweepOpacity = 0
        }
    }
}

struct SpaceCleanupView<CleanableContent: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var navigation: AppNavigationState
    @EnvironmentObject private var permissionStatus: PermissionStatusViewModel
    @EnvironmentObject private var spaceAnalysisResults: SpaceAnalysisResultsViewModel
    @ViewBuilder let cleanableContent: CleanableContent

    init(@ViewBuilder cleanableContent: () -> CleanableContent) {
        self.cleanableContent = cleanableContent()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("空间清理")
                        .font(.title2.bold())
                    Text("查看可清理项目，或配置空间分析范围。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: AppTheme.Spacing.lg)

                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(SpaceCleanupPage.allCases) { page in
                        Button {
                            navigation.selectSpaceCleanupPage(page)
                        } label: {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Label(page.title, systemImage: page.symbol)
                                if navigation.spaceCleanupPage == page {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, AppTheme.Spacing.md)
                            .frame(minHeight: 34)
                            .frame(maxWidth: .infinity)
                            .background(
                                navigation.spaceCleanupPage == page
                                    ? AppTheme.accent.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                                    .stroke(
                                        navigation.spaceCleanupPage == page
                                            ? AppTheme.accent.opacity(0.58)
                                            : Color.white.opacity(0.08),
                                        lineWidth: 1
                                    )
                            }
                            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(
                            page == .cleanableItems ? "1" : "2",
                            modifiers: [.command]
                        )
                        .help("切换到\(page.title)（⌘\(page == .cleanableItems ? "1" : "2")）")
                        .accessibilityLabel("\(page.title)，空间清理子页面")
                        .accessibilityValue(navigation.spaceCleanupPage == page ? "已选择" : "未选择")
                        .accessibilityHint("切换到\(page.title)，快捷键 Command \(page == .cleanableItems ? "1" : "2")")
                        .accessibilityAddTraits(navigation.spaceCleanupPage == page ? .isSelected : [])
                    }
                }
                .padding(3)
                .frame(width: 336)
                .background(
                    AppTheme.recessedSurface,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.control + 3, style: .continuous)
                )
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md)
            .background(
                reduceTransparency
                    ? AnyShapeStyle(AppTheme.obsidian)
                    : AnyShapeStyle(.ultraThinMaterial)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(height: 1)
                    .allowsHitTesting(false)
            }

            // 布局缺陷修复（2026-10-12 圣上报：非最大化窗口最上部分内容不可见）：
            // ZStack 需居中对齐——子视图最小高超出可用高时上下双向溢出，顶部被裁。
            // 改为 .top 对齐后任何溢出向下延展，顶部内容锚定在可是区。
            ZStack(alignment: .top) {
                cleanableContent
                    .frame(maxHeight: .infinity)
                    .opacity(navigation.spaceCleanupPage == .cleanableItems ? 1 : 0)
                    .allowsHitTesting(navigation.spaceCleanupPage == .cleanableItems)
                    .accessibilityHidden(navigation.spaceCleanupPage != .cleanableItems)

                // Rework（圣上拍板·左控右览）：左栏＝任务卡（范围＋扫描主操作＋权限条），
                // 右区＝结论条（诊断/变化）＋分段结果（概览/目录树/大文件含手动处理）。
                // 左栏包 ScrollView（内容 maxHeight 无穷保持高窗钉底观感）：
                // 消除左栏不可压的最小高度（矮窗口下曾把整页布局撑爆），
                // 矮窗口下主操作降级为滚动可达（OBS-003 语义：可达即不失联）。
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            SpaceAnalysisScopeView()
                                .padding(AppTheme.Spacing.lg)
                            Spacer(minLength: AppTheme.Spacing.md)
                            Divider()
                            // SC-5：权限与扫描覆盖状态显示在当前任务附近（左栏底部），
                            // 不埋在设置深处；只查询状态，不申请任何权限。
                            PermissionStatusStrip(viewModel: permissionStatus, openSettings: openPermissionSettings)
                                .padding(AppTheme.Spacing.md)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: 340)
                    .background(
                        reduceTransparency
                            ? AnyShapeStyle(AppTheme.obsidian.opacity(0.5))
                            : AnyShapeStyle(.ultraThinMaterial.opacity(0.35))
                    )
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(.white.opacity(0.10))
                            .frame(width: 1)
                            .allowsHitTesting(false)
                    }

                    // 右区可滚：只读结论（SC-PD1 诊断／SC-PD2 变化）在顶部，结果分段随其后。
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                            SpaceAnalysisDiagnosisView()
                            SpaceAnalysisChangeView()
                            SpaceAnalysisResultsView()
                        }
                        .padding(AppTheme.Spacing.xl)
                        .frame(maxWidth: 980, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .opacity(navigation.spaceCleanupPage == .spaceAnalysis ? 1 : 0)
                .allowsHitTesting(navigation.spaceCleanupPage == .spaceAnalysis)
                .accessibilityHidden(navigation.spaceCleanupPage != .spaceAnalysis)
            }
        }
        .accessibilityElement(children: .contain)
        .task { await permissionStatus.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // SC-5.2：用户去系统设置授权后回到本应用时重新查询状态，
            // 避免权限标签停留在过期值（只查询，不申请、不跳转）。
            Task { await permissionStatus.refresh() }
        }
        .onChange(of: spaceAnalysisResults.outcome?.summary) { _, newValue in
            // 覆盖事实来自真实扫描结果，而不是猜测；R4：连同取消标志一起观察
            // （同计数但完成态变化也要刷新覆盖结论）。
            permissionStatus.updateCoverage(
                hasScanResult: newValue != nil,
                unreadableDirectoryCount: max(0, newValue?.unreadableDirectoryCount ?? 0),
                scanCompleted: newValue?.cancelled == false
            )
            // SC-5.2：扫描完成后同步重新检测权限状态，使「重新扫描」指引与实际机制一致。
            Task { await permissionStatus.refresh() }
        }
    }

    /// 只在用户点击时打开系统设置；不会自动跳转，也不会自动申请。
    private func openPermissionSettings(_ kind: SystemPermissionKind) {
        guard let url = URL(string: PermissionGuidance.settingsURL(for: kind)) else { return }
        NSWorkspace.shared.open(url)
    }

}

private struct SectionTransitionSweep: View {
    let progress: CGFloat
    let opacity: Double
    let direction: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let sweepWidth: CGFloat = 190
            let travel = proxy.size.width + sweepWidth * 2
            let leadingX = -sweepWidth + travel * progress
            let trailingX = proxy.size.width + sweepWidth - travel * progress

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, AppTheme.accent.opacity(0.08), AppTheme.violet.opacity(0.065), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: sweepWidth, height: proxy.size.height)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, AppTheme.accent.opacity(0.85), AppTheme.violet.opacity(0.50), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: sweepWidth, height: 2)
                    .padding(.top, 2)
            }
            .offset(x: direction >= 0 ? leadingX : trailingX)
            .opacity(opacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PrivacyNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "lock.shield")
                .foregroundStyle(AppTheme.healthy)
                .accessibilityHidden(true)
            Text("本机处理，不上传文件信息")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("主窗口") {
    RootView(healthViewModel: SystemHealthDashboardViewModel.isolatedPreview())
        .frame(width: 1_080, height: 720)
        .environmentObject(AppSettings())
        .environmentObject(AppNavigationState())
        .environmentObject(SystemNotificationDelivery(scheduler: InertNotificationScheduler()))
        .environmentObject(IgnoreListStore(repository: InMemoryIgnoreRuleRepository(), autoload: false))
        .environmentObject(SpaceAnalysisScopeViewModel())
}
#endif

#if DEBUG
@MainActor
struct SC31InformationArchitecturePreview: View {
    @StateObject private var navigation = AppNavigationState()
    @StateObject private var ignoreList: IgnoreListStore
    @StateObject private var cleanupViewModel: CleanupViewModel

    init() {
        let ignoreList = IgnoreListStore(
            repository: InMemoryIgnoreRuleRepository(),
            autoload: false
        )
        _ignoreList = StateObject(wrappedValue: ignoreList)
        _cleanupViewModel = StateObject(wrappedValue: CleanupViewModel(
            scanner: SC31DisabledDiskScanner(),
            executor: SC31DisabledCleanupExecutor(),
            historyStore: SC31InMemoryCleanupHistoryStore(),
            ignoreList: ignoreList
        ))
    }

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: 0) {
                HStack(spacing: AppTheme.Spacing.md) {
                    Label("SC-3.1 纯内存导航预览", systemImage: "checkmark.shield")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.healthy)
                    Spacer()
                    Text("导航请求 \(navigation.requestRevision.formatted())")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("模拟菜单栏：进入可清理项目", systemImage: "menubar.rectangle") {
                        navigation.request(.cleanup)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("使用与菜单栏完全相同的共享导航状态返回空间清理默认页")
                }
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.vertical, AppTheme.Spacing.sm)

                SpaceCleanupView {
                    CleanupView(
                        previewViewModel: cleanupViewModel,
                        ignoreList: ignoreList
                    )
                }
            }
        }
        .tint(AppTheme.accent)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .environmentObject(navigation)
        .environmentObject(SpaceAnalysisScopeViewModel(
            homeDirectory: URL(fileURLWithPath: "/SC31Preview/Home", isDirectory: true),
            validator: SC31DisabledScopeValidator(),
            directoryChooser: SC31CancelledDirectoryChooser()
        ))
    }
}

private struct SC31DisabledDiskScanner: DiskScanning {
    func scan(
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> CleanupScanReport {
        throw SC31PreviewError.disabled
    }
}

private actor SC31DisabledCleanupExecutor: CleanupExecuting {
    func moveToTrash(
        candidates: [CleanupFileCandidate],
        progress: @escaping @Sendable (CleanupExecutionProgress) async -> Void
    ) async -> CleanupExecutionReport {
        CleanupExecutionReport(
            requestedCount: candidates.count,
            requestedBytes: 0,
            movedCount: 0,
            movedBytes: 0,
            failures: [],
            cancelled: true,
            finishedAt: Date()
        )
    }
}

private actor SC31InMemoryCleanupHistoryStore: CleanupHistoryStoring {
    func load() async -> [CleanupHistoryEntry] { [] }
    func append(_ entry: CleanupHistoryEntry) async throws {}
}

private enum SC31PreviewError: LocalizedError {
    case disabled

    var errorDescription: String? {
        "SC-3.1 DEBUG 预览已禁用磁盘扫描。"
    }
}

private struct SC31DisabledScopeValidator: SpaceAnalysisScopeValidating {
    func validate(
        _ candidate: SpaceAnalysisScopeCandidate,
        existingScopes: [SpaceAnalysisScope]
    ) -> SpaceAnalysisScopeValidationResult {
        .rejected(.inaccessible(path: candidate.path, errorCode: EPERM))
    }
}

@MainActor
private struct SC31CancelledDirectoryChooser: SpaceAnalysisDirectoryChoosing {
    func chooseDirectories() -> SpaceAnalysisDirectoryChoice { .cancelled }
}
#endif
