import AppKit
import SwiftUI

extension ApplicationSignatureState {
    var localizedName: String {
        switch self {
        case .valid: String(localized: "签名有效")
        case .unsigned: String(localized: "未签名")
        case .invalid: String(localized: "签名异常")
        case .unavailable: String(localized: "无法读取")
        }
    }

    var symbol: String {
        switch self {
        case .valid: "checkmark.seal.fill"
        case .unsigned: "signature"
        case .invalid: "exclamationmark.triangle.fill"
        case .unavailable: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .valid: AppTheme.healthy
        case .unsigned, .unavailable: AppTheme.warning
        case .invalid: AppTheme.danger
        }
    }
}

extension AppResidueKind {
    var localizedName: String {
        switch self {
        case .cache: String(localized: "缓存")
        case .logs: String(localized: "日志")
        case .preferences: String(localized: "偏好设置")
        case .savedState: String(localized: "保存状态")
        case .applicationSupport: String(localized: "应用支持数据")
        case .container: String(localized: "沙盒容器")
        case .httpStorage: String(localized: "网络存储")
        case .webKit: String(localized: "网页数据")
        case .applicationScripts: String(localized: "应用脚本")
        }
    }

    var symbol: String {
        switch self {
        case .cache: "externaldrive.badge.timemachine"
        case .logs: "doc.text"
        case .preferences: "slider.horizontal.3"
        case .savedState: "clock.arrow.circlepath"
        case .applicationSupport: "folder.badge.gearshape"
        case .container: "shippingbox"
        case .httpStorage: "network"
        case .webKit: "safari"
        case .applicationScripts: "applescript"
        }
    }
}

struct UninstallerView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject private var ignoreList: IgnoreListStore
    @StateObject private var viewModel: UninstallerViewModel
    @State private var searchText = ""
    @State private var sortOption: ApplicationSortOption = .name
    @State private var showsConfirmation = false
    @State private var exportFeedback: OperationPlanExportFeedback?

    init(
        ignoreList: IgnoreListStore,
        historyStore: any UninstallHistoryStoring = UninstallHistoryStore()
    ) {
        self.ignoreList = ignoreList
        _viewModel = StateObject(wrappedValue: UninstallerViewModel(
            historyStore: historyStore,
            ignoreList: ignoreList
        ))
    }

    #if DEBUG
    init(previewViewModel: UninstallerViewModel, ignoreList: IgnoreListStore) {
        self.ignoreList = ignoreList
        _viewModel = StateObject(wrappedValue: previewViewModel)
    }
    #endif

    var body: some View {
        // SC-Rework-UI-Visual R1（P1 审计发现）：页面级滚动兜底——本页固定最小高之和
        // （header＋banner＋browser minHeight 500，合计约 652pt+）确定性超过 590pt 窗口下限，
        // 无滚动时左列底部「重新扫描」等主操作被宿主 .clipped() 裁剪不可达；OBS-003 同构，
        // 修法与 RootView 空间分析页一致（整页 ScrollView，内部结构保持原缩进以最小化 diff）。
        ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            FeatureHeader(
                eyebrow: String(localized: "精确关联 · 可恢复"),
                title: String(localized: "APP 深度卸载"),
                description: String(localized: "核对应用与残留；确认后移入废纸篓。"),
                symbol: "shippingbox.fill",
                tint: Color.indigo
            )

            switch viewModel.scanPhase {
            case .idle:
                UninstallerIntroduction(startAction: startScan)
            case .scanning:
                ApplicationScanProgressCard(
                    progress: viewModel.scanProgress,
                    cancelAction: viewModel.cancelScan
                )
            case .completed:
                completedContent
            case .cancelled:
                UninstallerStatusCard(
                    title: String(localized: "应用扫描已取消"),
                    message: String(localized: "没有移动或修改任何应用与文件。"),
                    symbol: "xmark.circle.fill",
                    tint: AppTheme.warning,
                    actionTitle: String(localized: "重新扫描"),
                    action: startScan
                )
            case .failed(let message):
                UninstallerStatusCard(
                    title: String(localized: "应用扫描未完成"),
                    message: message,
                    symbol: "exclamationmark.triangle.fill",
                    tint: AppTheme.danger,
                    actionTitle: String(localized: "重试"),
                    action: startScan
                )
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: 1_080, maxHeight: .infinity, alignment: .topLeading)
        } // ScrollView 关闭（SC-Rework-UI-Visual R1）
        .background(.clear)
        .confirmationDialog(
            String(localized: "确认卸载 \(viewModel.selectedApplication?.name ?? String(localized: "所选应用"))？"),
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                viewModel.startUninstall()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .onChange(of: ignoreList.rules) { _, _ in
            viewModel.reconcileIgnoredSelection()
        }
    }

    @ViewBuilder
    private var completedContent: some View {
        switch viewModel.executionPhase {
        case .idle:
            ApplicationBrowser(
                viewModel: viewModel,
                ignoreList: ignoreList,
                searchText: $searchText,
                sortOption: $sortOption,
                restartAction: startScan,
                exportAction: preparePlanExport,
                exportFeedback: exportFeedback,
                uninstallAction: { showsConfirmation = true },
                manageIgnoreListAction: { navigation.request(.settings) }
            )
        case .running:
            UninstallProgressCard(
                progress: viewModel.executionProgress,
                cancelAction: viewModel.cancelUninstall
            )
        case .completed:
            if let receipt = viewModel.lastExecutionReceipt {
                UninstallCompletionCard(
                    receipt: receipt,
                    applicationName: viewModel.lastExecutionReport?.applicationName ?? String(localized: "应用"),
                    historySaveWarning: viewModel.historySaveWarning,
                    returnAction: viewModel.returnToSelection,
                    rescanAction: startScan
                )
                if viewModel.lastExecutionReport?.applicationMoved == true {
                    UninstallRecheckPanel(
                        canRunRecheck: viewModel.canRunPostUninstallRecheck,
                        isRunning: viewModel.postUninstallRecheckRunning,
                        report: viewModel.postUninstallRecheck,
                        receiptMovedBytes: viewModel.lastExecutionReport?.movedBytes,
                        runAction: viewModel.runPostUninstallRecheck
                    )
                }
            } else if let error = viewModel.executionReceiptBuildError {
                ExecutionReceiptFailureView(
                    error: error,
                    primaryTitle: String(localized: "重新扫描应用"),
                    primaryAction: startScan
                )
            }
        }
    }

    private var confirmationMessage: String {
        String(localized: "应用本体 + \(viewModel.selectedResidueCount.formatted()) 项已勾选残留，共约 \(SystemFormatters.bytes.string(fromByteCount: viewModel.selectedTotalBytes))。路径摘要：\(viewModel.confirmationPathSummary)。应用本体失败时，关联文件会全部保留。")
    }

    private func startScan() {
        exportFeedback = nil
        viewModel.startScan(configuration: settings.scanConfiguration)
    }

    private func preparePlanExport() {
        do {
            let snapshot = try viewModel.makeOperationPlanExport()
            exportFeedback = nil
            OperationPlanExportUI.presentSavePanel(
                document: OperationPlanTextFileDocument(text: snapshot.text),
                suggestedFilename: snapshot.suggestedFilename,
                completion: handlePlanExport
            )
        } catch {
            exportFeedback = OperationPlanExportFeedback(
                message: String(localized: "无法生成卸载计划：\(error.localizedDescription)"),
                kind: .failure
            )
        }
    }

    private func handlePlanExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            exportFeedback = OperationPlanExportFeedback(
                message: String(localized: "卸载计划已导出。残留选择、忽略规则和执行状态均未改变。"),
                kind: .success
            )
        case .failure(let error) where OperationPlanExportUI.isCancellation(error):
            exportFeedback = OperationPlanExportFeedback(
                message: String(localized: "已取消导出，没有创建计划文件或更改残留选择。"),
                kind: .cancelled
            )
        case .failure(let error):
            exportFeedback = OperationPlanExportFeedback(
                message: String(localized: "卸载计划未能导出：\(error.localizedDescription)。"),
                kind: .failure
            )
        }
    }
}

private struct UninstallerIntroduction: View {
    let startAction: () -> Void
    private let steps = [
        (String(localized: "应用本体"), String(localized: "扫描 /Applications 与 ~/Applications"), "app.badge.checkmark"),
        (String(localized: "身份信息"), String(localized: "读取版本、Bundle Identifier 与代码签名"), "checkmark.seal"),
        (String(localized: "关联残留"), String(localized: "只检查 Bundle Identifier 完全一致的固定路径"), "point.3.connected.trianglepath.dotted"),
        (String(localized: "后台关联"), String(localized: "只读核对登录项、代理、辅助工具与安装收据"), "gearshape.2"),
        (String(localized: "可恢复卸载"), String(localized: "二次确认后移到废纸篓，不永久删除"), "trash")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("扫描已安装应用")
                        .font(.title2.bold())
                    Text("读取身份与固定关联；选择应用后再决定残留。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppTheme.Spacing.md)
                Button("开始扫描", systemImage: "magnifyingglass", action: startAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .cardSurface()

            SafetyBanner(
                title: String(localized: "拒绝模糊匹配"),
                message: String(localized: "不会因为文件名含有应用名称就判定为残留；所有残留默认不勾选。"),
                symbol: "checkmark.shield.fill"
            )

            InformationDisclosure(
                title: String(localized: "查看扫描与卸载流程"),
                summary: String(localized: "身份核对、精确残留、后台关联和可恢复卸载"),
                symbol: "list.number",
                tint: Color.indigo
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: AppTheme.Spacing.md) {
                            Image(systemName: step.2)
                                .font(.title3)
                                .foregroundStyle(Color.indigo)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                Text(step.0).font(.body.weight(.medium))
                                Text(step.1).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(AppTheme.recessedSurface)
                                .clipShape(Circle())
                        }
                        .padding(.vertical, AppTheme.Spacing.sm)
                        .accessibilityElement(children: .combine)
                        if index < steps.count - 1 { Divider() }
                    }
                    Text("扫描只读取应用包和关联路径的元数据。大型应用的容量统计可能需要几秒钟。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, AppTheme.Spacing.sm)
                }
            }
        }
    }
}

private struct ApplicationScanProgressCard: View {
    let progress: ApplicationScanProgress
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(spacing: AppTheme.Spacing.md) {
                ProgressView().controlSize(.large).accessibilityLabel("应用扫描进行中")
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("正在检查应用").font(.title2.bold())
                    Text(progress.currentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("取消扫描", systemImage: "xmark", action: cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: AppTheme.Spacing.md) {
                UninstallMetric(title: String(localized: "已发现应用"), value: progress.discoveredCount.formatted(), symbol: "square.grid.2x2")
                UninstallMetric(title: String(localized: "已统计容量"), value: progress.measuredCount.formatted(), symbol: "ruler")
            }

            Text("扫描不会启动、退出、移动或修改任何应用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardSurface()
    }
}

private struct ApplicationBrowser: View {
    @ObservedObject var viewModel: UninstallerViewModel
    @ObservedObject var ignoreList: IgnoreListStore
    @Binding var searchText: String
    @Binding var sortOption: ApplicationSortOption
    let restartAction: () -> Void
    let exportAction: () -> Void
    let exportFeedback: OperationPlanExportFeedback?
    let uninstallAction: () -> Void
    let manageIgnoreListAction: () -> Void

    private var filteredApplications: [InstalledApplication] {
        let filtered: [InstalledApplication]
        if searchText.isEmpty {
            filtered = viewModel.applications
        } else {
            filtered = viewModel.applications.filter { application in
            application.name.localizedCaseInsensitiveContains(searchText)
                || application.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) == true
            }
        }
        return sortOption.sort(filtered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if let issues = viewModel.scanReport?.accessIssues, !issues.isEmpty {
                ScanCoverageNotice(issues: issues)
            }

            IgnoreListStatusBanner(
                loadState: ignoreList.loadState,
                ignoredCount: viewModel.ignoredApplicationCount + viewModel.ignoredResidueCount,
                manageAction: manageIgnoreListAction
            )

            HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    Text("已安装应用").font(.headline)
                    Spacer()
                    Text(viewModel.applications.count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if viewModel.ignoredApplicationCount > 0 {
                    Text("精确忽略 \(viewModel.ignoredApplicationCount.formatted()) 个 · 原始扫描 \(viewModel.rawApplicationCount.formatted()) 个")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppTheme.accent)
                }

                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("搜索名称或 Bundle ID", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .frame(height: 32)
                .background(AppTheme.recessedSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))

                Picker("排序", selection: $sortOption) {
                    ForEach(ApplicationSortOption.allCases) { option in
                        Text(option.localizedName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("调整应用列表的排序方式")

                List(filteredApplications) { application in
                    ApplicationListRow(
                        application: application,
                        isSelected: viewModel.selectedApplicationID == application.id
                    ) {
                        viewModel.selectApplication(application.id)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if filteredApplications.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }

                Button("重新扫描", systemImage: "arrow.clockwise", action: restartAction)
                    .buttonStyle(.bordered)
            }
            .padding(AppTheme.Spacing.md)
            .frame(width: 310)
            .frame(minHeight: 500, maxHeight: .infinity)
            .background(AppTheme.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .stroke(.separator.opacity(0.45), lineWidth: 1)
            }

            if let application = viewModel.selectedApplication {
                ScrollView {
                    ApplicationDetail(
                        application: application,
                        viewModel: viewModel,
                        ignoreList: ignoreList,
                        exportAction: exportAction,
                        exportFeedback: exportFeedback,
                        uninstallAction: uninstallAction
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "请选择应用",
                    systemImage: "app.dashed",
                    description: Text("从左侧列表选择一个应用以检查身份和关联残留。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
        }
        .frame(minHeight: 500, maxHeight: .infinity)
    }
}

private struct ApplicationListRow: View {
    let application: InstalledApplication
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(application.version.map { String(localized: "版本 \($0)") } ?? String(localized: "版本未知"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.indigo)
                        .accessibilityLabel("已选择")
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.indigo.opacity(0.12) : Color.clear)
        .accessibilityLabel("\(application.name)，\(application.version ?? String(localized: "版本未知"))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ApplicationDetail: View {
    let application: InstalledApplication
    @ObservedObject var viewModel: UninstallerViewModel
    @ObservedObject var ignoreList: IgnoreListStore
    let exportAction: () -> Void
    let exportFeedback: OperationPlanExportFeedback?
    let uninstallAction: () -> Void
    @State private var presentedEvidence: UninstallEvidenceDetail?
    @State private var pendingIgnore: UninstallIgnoreRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(application.name).font(.title2.bold())
                    Text(versionText).font(.callout).foregroundStyle(.secondary)
                    Label(application.signatureState.localizedName, systemImage: application.signatureState.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(application.signatureState.tint)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: AppTheme.Spacing.sm) {
                    Text(SystemFormatters.bytes.string(fromByteCount: application.allocatedBytes))
                        .font(.title3.bold().monospacedDigit())
                    Button(applicationIgnoreButtonTitle, systemImage: "eye.slash") {
                        pendingIgnore = .application(application)
                    }
                    .buttonStyle(.bordered)
                    .help(applicationIgnoreHelp)
                    .accessibilityLabel(applicationIgnoreAccessibilityLabel)
                }
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                IdentityRow(title: "Bundle Identifier", value: application.bundleIdentifier ?? String(localized: "无法读取"))
                IdentityRow(title: String(localized: "签名者"), value: application.signer ?? String(localized: "无法读取"))
                IdentityRow(title: "Team Identifier", value: application.teamIdentifier ?? String(localized: "无"))
                IdentityRow(title: String(localized: "应用路径"), value: application.path)
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.recessedSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))

            Label(applicationIgnoreExplanation, systemImage: "scope")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)

            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "checkmark.square.fill")
                    .foregroundStyle(Color.indigo)
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("应用本体").font(.headline)
                    Text("卸载方案始终先处理应用本体；如果失败，关联文件会全部保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: AppTheme.Spacing.sm) {
                    Text(SystemFormatters.bytes.string(fromByteCount: application.allocatedBytes))
                        .font(.callout.monospacedDigit().weight(.semibold))
                    Button("查看应用本体证据", systemImage: "doc.text.magnifyingglass") {
                        presentedEvidence = UninstallEvidenceDetail(
                            application: application,
                            coverageRecords: viewModel.scanReport?.coverage ?? []
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("只读查看应用本体的扫描证据；不会改变残留选择或执行卸载")
                    .accessibilityLabel("查看应用本体证据")
                    .accessibilityHint("只读查看；不会选择、忽略、卸载或移动任何项目")
                }
            }
            .padding(AppTheme.Spacing.md)
            .background(Color.indigo.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))

            AppFootprintPanel(report: viewModel.footprintReport)

            residueSection

            associationSection

            if let bundleRestriction = ScanRules.bundleIdentifierRestriction(application.bundleIdentifier) {
                Label(
                    bundleIdentifierWarning(for: bundleRestriction),
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.callout)
                .foregroundStyle(AppTheme.warning)
                .accessibilityElement(children: .combine)
            }

            SafetyBanner(
                title: String(localized: "所有残留默认关闭"),
                message: String(localized: "只展示 Bundle Identifier 完全一致的固定路径。请确认不再需要登录状态、配置或本地数据后再勾选。"),
                symbol: "hand.raised.fill"
            )

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本次方案：应用本体 + \(viewModel.selectedResidueCount.formatted()) 项残留")
                        .font(.callout.weight(.semibold))
                    Text("预计移入废纸篓 \(SystemFormatters.bytes.string(fromByteCount: viewModel.selectedTotalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("导出计划", systemImage: "doc.badge.arrow.up", action: exportAction)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!viewModel.canExportOperationPlan)
                    .help(viewModel.canExportOperationPlan ? String(localized: "导出应用本体与已勾选残留的只读计划，不执行卸载") : String(localized: "请等待扫描完成并选择可卸载的应用"))
                    .accessibilityLabel("导出应用卸载计划")
                    .accessibilityHint("打开保存面板；只导出应用本体与已勾选残留，不会执行卸载")
                Button(
                    viewModel.selectedResidueCount == 0 ? String(localized: "仅卸载 APP") : String(localized: "卸载 APP 与所选残留"),
                    systemImage: "trash",
                    action: uninstallAction
                )
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.danger)
                .controlSize(.large)
                .disabled(!viewModel.canUninstall)
                .help("执行前会显示路径与容量的二次确认")
            }

            if let exportFeedback {
                Label(
                    exportFeedback.message,
                    systemImage: exportFeedback.kind == .failure
                        ? "exclamationmark.triangle.fill"
                        : (exportFeedback.kind == .cancelled ? "xmark.circle" : "checkmark.circle.fill")
                )
                .font(.caption)
                .foregroundStyle(
                    exportFeedback.kind == .failure
                        ? AppTheme.warning
                        : (exportFeedback.kind == .cancelled ? Color.secondary : AppTheme.healthy)
                )
                .accessibilityElement(children: .combine)
            }

            Text("提示：正在运行的应用会被拒绝卸载；系统权限不足时会保留原文件并显示原因。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $presentedEvidence) { detail in
            UninstallEvidenceSheet(
                detail: detail,
                closeAction: { presentedEvidence = nil },
                ignoreCandidateAction: { residue in
                    presentedEvidence = nil
                    pendingIgnore = .residueCandidate(residue)
                },
                ignorePathAction: { residue in
                    presentedEvidence = nil
                    pendingIgnore = .fixedPath(residue)
                }
            )
        }
        .confirmationDialog(
            pendingIgnore?.title ?? String(localized: "确认忽略范围"),
            isPresented: Binding(
                get: { pendingIgnore != nil },
                set: { if !$0 { pendingIgnore = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingIgnore {
                Button(pendingIgnore.actionTitle) {
                    let rule = pendingIgnore.rule
                    self.pendingIgnore = nil
                    Task {
                        _ = try? await ignoreList.add(rule)
                        viewModel.reconcileIgnoredSelection()
                    }
                }
            }
            Button("取消", role: .cancel) { pendingIgnore = nil }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(pendingIgnore?.message ?? "")
        }
        .alert(
            "忽略列表未能保存",
            isPresented: Binding(
                get: { ignoreList.persistenceError != nil },
                set: { if !$0 { ignoreList.dismissPersistenceError() } }
            )
        ) {
            Button("好") { ignoreList.dismissPersistenceError() }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(ignoreList.persistenceError ?? String(localized: "当前规则未改变，请稍后重试。"))
        }
    }

    @ViewBuilder
    private var associationSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("登录项与后台关联").font(.headline)
                Spacer()
                Label("只读", systemImage: "eye")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            switch viewModel.associationPhase {
            case .disabled:
                ContentUnavailableView(
                    "关联分析已在设置中关闭",
                    systemImage: "eye.slash",
                    description: Text("可按 Command + , 打开设置，并在下次扫描时启用。")
                )
                .frame(minHeight: 120)
            case .scanning:
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在核对结构化标识符和应用路径引用…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, AppTheme.Spacing.md)
            case .completed:
                if viewModel.associatedItems.isEmpty {
                    UninstallCoverageEmptyView(
                        summary: UninstallCoverageSummary(
                            records: viewModel.associationReport?.coverage ?? [],
                            emptyResultTitle: String(localized: "已完成核对，未发现明确关联项目")
                        ),
                        symbol: "eye.slash"
                    )
                    .frame(minHeight: 120)
                } else {
                    ForEach(viewModel.associatedItems) { item in
                        AssociationRow(item: item) {
                            presentedEvidence = UninstallEvidenceDetail(
                                association: item,
                                coverageRecords: viewModel.associationReport?.coverage ?? []
                            )
                        }
                    }
                }

                if let issues = viewModel.associationReport?.accessIssues, !issues.isEmpty {
                    DisclosureGroup("查看原有扫描提示（\((viewModel.associationReport?.accessIssueCount ?? 0).formatted())）") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, AppTheme.Spacing.sm)
                    }
                    .foregroundStyle(AppTheme.warning)
                }
            }

            Text("外部后台项目与安装收据不会被自动移除；内嵌登录项会随 APP 本体一起进入废纸篓。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var residueSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("精确关联的残留").font(.headline)
                Spacer()
                if viewModel.ignoredResidueCount > 0 {
                    Text("已忽略 \(viewModel.ignoredResidueCount.formatted()) 项")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.accent)
                }
                if !viewModel.residues.isEmpty {
                    Button("全部不选") { viewModel.setAllResiduesSelected(false) }
                        .disabled(viewModel.selectedResidueCount == 0)
                }
            }

            switch viewModel.residuePhase {
            case .idle, .scanning:
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在按 Bundle Identifier 检查固定路径…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, AppTheme.Spacing.md)
            case .completed:
                if viewModel.residues.isEmpty {
                    UninstallCoverageEmptyView(
                        summary: UninstallCoverageSummary(
                            records: viewModel.residueReport?.coverage ?? [],
                            emptyResultTitle: String(localized: "已完成核对，未发现精确路径残留")
                        ),
                        symbol: "checkmark.shield"
                    )
                    .frame(minHeight: 150)
                } else {
                    ForEach(viewModel.residues) { residue in
                        ResidueRow(
                            residue: residue,
                            isSelected: viewModel.isResidueSelected(residue),
                            selectionAction: { viewModel.setResidueSelected($0, candidate: residue) },
                            evidenceAction: {
                                presentedEvidence = UninstallEvidenceDetail(
                                    residue: residue,
                                    coverageRecords: viewModel.residueReport?.coverage ?? []
                                )
                            }
                        )
                    }
                }

                if let issues = viewModel.residueReport?.accessIssues, !issues.isEmpty {
                    DisclosureGroup("查看原有扫描提示（\((viewModel.residueReport?.accessIssueCount ?? 0).formatted())）") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .padding(.top, AppTheme.Spacing.sm)
                    }
                    .foregroundStyle(AppTheme.warning)
                }
            }
        }
    }

    private var versionText: String {
        var parts: [String] = []
        if let version = application.version { parts.append(String(localized: "版本 \(version)")) }
        if let build = application.buildNumber { parts.append(String(localized: "构建 \(build)")) }
        return parts.isEmpty ? String(localized: "版本信息无法读取") : parts.joined(separator: " · ")
    }

    private var usesBundleIdentifierIgnore: Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        return ScanRules.bundleIdentifierRestriction(bundleIdentifier) == nil
    }

    private var applicationIgnoreButtonTitle: String {
        usesBundleIdentifierIgnore ? String(localized: "忽略同 Bundle ID 应用") : String(localized: "忽略此应用路径")
    }

    private var applicationIgnoreHelp: String {
        usesBundleIdentifierIgnore
            ? String(localized: "只忽略 Bundle Identifier 完全相同的应用")
            : String(localized: "Bundle Identifier 缺失或无效，只能按精确应用路径忽略")
    }

    private var applicationIgnoreAccessibilityLabel: String {
        usesBundleIdentifierIgnore
            ? String(localized: "忽略 Bundle Identifier 完全相同的应用：\(application.bundleIdentifier ?? "")")
            : String(localized: "忽略精确应用路径：\(application.path)")
    }

    private var applicationIgnoreExplanation: String {
        usesBundleIdentifierIgnore
            ? String(localized: "忽略范围：仅 Bundle Identifier 与 \(application.bundleIdentifier ?? "") 完全相等的应用；不做前缀、后缀或大小写折叠。")
            : String(localized: "此应用的 Bundle Identifier 缺失或无效，忽略范围已退化为精确应用路径：\(application.path)。")
    }

    private func bundleIdentifierWarning(for restriction: RestrictionReason) -> String {
        switch restriction {
        case .missingBundleIdentifier:
            String(localized: "缺少 Bundle Identifier，无法进行可解释的残留与关联分析。可以继续查看应用信息，但卸载按钮已关闭。")
        case .invalidBundleIdentifier:
            String(localized: "Bundle Identifier 格式不符合固定规则，残留与关联范围已保留为结构化跳过记录。请修复应用元数据后重新扫描。")
        default:
            String(localized: "Bundle Identifier 无法用于本轮关联分析，请查看覆盖记录后重新扫描。")
        }
    }
}

private enum UninstallIgnoreRequest {
    case application(InstalledApplication)
    case residueCandidate(AppResidueCandidate)
    case fixedPath(AppResidueCandidate)

    var title: String {
        switch self {
        case .application(let application):
            if let bundleIdentifier = application.bundleIdentifier,
               ScanRules.bundleIdentifierRestriction(bundleIdentifier) == nil {
                return String(localized: "忽略 Bundle Identifier 完全相同的应用？")
            }
            return String(localized: "仅忽略这个精确应用路径？")
        case .residueCandidate:
            return String(localized: "仅忽略这个卸载残留候选？")
        case .fixedPath:
            return String(localized: "忽略这个精确固定路径？")
        }
    }

    var actionTitle: String {
        switch self {
        case .application(let application):
            if let bundleIdentifier = application.bundleIdentifier,
               ScanRules.bundleIdentifierRestriction(bundleIdentifier) == nil {
                return String(localized: "忽略同 Bundle ID 应用")
            }
            return String(localized: "忽略此应用路径")
        case .residueCandidate: return String(localized: "仅忽略这个残留候选")
        case .fixedPath: return String(localized: "忽略这个精确路径")
        }
    }

    var message: String {
        switch self {
        case .application(let application):
            if let bundleIdentifier = application.bundleIdentifier,
               ScanRules.bundleIdentifierRestriction(bundleIdentifier) == nil {
                return String(localized: "只匹配 Bundle Identifier 与 \(bundleIdentifier) 完全相等的应用；不匹配前缀、后缀、相似名称或大小写差异。原始应用路径记录为 \(application.path)。")
            }
            return String(localized: "Bundle Identifier 缺失或无效，因此只匹配统一格式后与 \(application.path) 完全相等的应用路径；不会扩大到父目录、子目录或相似名称。")
        case .residueCandidate(let residue):
            return String(localized: "只匹配 Bundle Identifier \(residue.bundleIdentifier)、残留类别 \(residue.kind.localizedName) 与完整路径同时相等的候选：\(residue.path)。")
        case .fixedPath(let residue):
            return String(localized: "只匹配统一格式后与 \(residue.path) 完全相等的路径；不会匹配父目录、子目录、相似名称，不解析符号链接。")
        }
    }

    var rule: IgnoreRule {
        switch self {
        case .application(let application): .application(application)
        case .residueCandidate(let residue): .residueCandidate(residue)
        case .fixedPath(let residue): .fixedPath(residue.path)
        }
    }
}

private struct ResidueRow: View {
    let residue: AppResidueCandidate
    let isSelected: Bool
    let selectionAction: @MainActor @Sendable (Bool) -> Void
    let evidenceAction: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Toggle(
                "选择 \(residue.kind.localizedName) 残留",
                isOn: Binding(
                    get: { isSelected },
                    set: { newValue in selectionAction(newValue) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel("选择 \(residue.kind.localizedName) 残留")
            .accessibilityHint("默认不选；勾选后会在确认卸载且执行复验通过时随应用本体移到废纸篓")

            Image(systemName: residue.kind.symbol)
                .foregroundStyle(AppTheme.warning)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(residue.kind.localizedName).font(.body.weight(.medium))
                    Text(residue.matchReason)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.healthy)
                }
                Text(residue.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            VStack(alignment: .trailing, spacing: AppTheme.Spacing.sm) {
                Text(SystemFormatters.bytes.string(fromByteCount: residue.allocatedBytes))
                    .font(.caption.monospacedDigit().weight(.semibold))
                Button("查看证据", systemImage: "doc.text.magnifyingglass", action: evidenceAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("查看此残留的扫描证据；不会改变勾选状态")
                    .accessibilityLabel("查看 \(residue.kind.localizedName) 残留证据")
                    .accessibilityHint("只读查看，不改变卸载选择")
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct AssociationRow: View {
    let item: AppAssociatedItem
    let evidenceAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(item.kind.localizedName).font(.body.weight(.medium))
                    Text(item.isInsideApplicationBundle ? String(localized: "随 APP 移动") : String(localized: "仅供核对"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.isInsideApplicationBundle ? AppTheme.healthy : AppTheme.accent)
                }
                Text(item.relationship.localizedName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            Button("查看证据", systemImage: "doc.text.magnifyingglass", action: evidenceAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("查看此只读关联项目的扫描证据")
                .accessibilityLabel("查看 \(item.kind.localizedName) 关联证据")
                .accessibilityHint("只读查看；该项目没有复选框，也不会加入卸载执行清单")
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct UninstallCoverageEmptyView: View {
    let summary: UninstallCoverageSummary
    let symbol: String

    var body: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint(for: summary.status))
                .accessibilityHidden(true)
            Text(summary.title)
                .font(.headline)
            Text(summary.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if summary.issueCount > 0 {
                Text("结构化问题 \(summary.issueCount.formatted()) · 权限提示投影 \(summary.accessIssueCount.formatted()) · 保留样本 \(summary.sampledIssueCount.formatted()) · 省略 \(summary.omittedIssueCount.formatted())")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.recessedSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func tint(for status: CoverageStatus?) -> Color {
        switch status {
        case .completed: AppTheme.healthy
        case .partial, .inaccessible, .skipped, .cancelled: AppTheme.warning
        default: AppTheme.accent
        }
    }
}

private struct UninstallEvidenceSheet: View {
    let detail: UninstallEvidenceDetail
    let closeAction: () -> Void
    let ignoreCandidateAction: (AppResidueCandidate) -> Void
    let ignorePathAction: (AppResidueCandidate) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                Image(systemName: detail.isReadOnlyAssociation ? "eye.fill" : "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(detail.isReadOnlyAssociation ? AppTheme.accent : AppTheme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("扫描证据")
                        .font(.title2.bold())
                    Text(detail.presentationSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", systemImage: "xmark", action: closeAction)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .help("关闭证据详情")
                    .accessibilityLabel("关闭证据详情")
            }
            .padding(AppTheme.Spacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    if let residue {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Button("仅忽略这个残留候选", systemImage: "eye.slash") {
                                ignoreCandidateAction(residue)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("仅忽略这个残留候选")
                            .accessibilityHint("同时精确匹配 Bundle Identifier、残留类别和完整路径")

                            Button("忽略这个精确路径", systemImage: "folder.badge.minus") {
                                ignorePathAction(residue)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("忽略这个残留的精确路径")
                            .accessibilityHint("只匹配统一格式后的完整路径字符串")
                        }
                    }

                    EvidenceSection(title: String(localized: "项目身份"), symbol: "tag") {
                        EvidenceValueRow(title: String(localized: "类别"), value: detail.categoryName)
                        EvidenceValueRow(title: String(localized: "类别标识"), value: detail.categoryIdentifier, monospaced: true)
                        EvidenceValueRow(title: String(localized: "完整路径"), value: detail.path, monospaced: true)
                        EvidenceValueRow(title: detail.bundleIdentifierLabel, value: detail.parentBundleIdentifier, monospaced: true)
                        if let itemIdentifier = detail.itemIdentifier {
                            EvidenceValueRow(title: String(localized: "项目自身 identifier"), value: itemIdentifier, monospaced: true)
                        }
                        if let relationship = detail.relationship {
                            EvidenceValueRow(title: String(localized: "关系类型"), value: relationship.localizedName)
                        }
                        if let residueMatchReason = detail.residueMatchReason {
                            EvidenceValueRow(title: String(localized: "扫描器匹配说明"), value: residueMatchReason)
                        }
                    }

                    EvidenceSection(title: String(localized: "规则依据"), symbol: "checklist") {
                        EvidenceValueRow(title: String(localized: "固定 reasonCode"), value: detail.reasonCode, monospaced: true)
                        EvidenceValueRow(title: "reasonText", value: detail.reasonText)
                        EvidenceValueRow(title: String(localized: "实际匹配值"), value: detail.matchedValue ?? "未单独记录", monospaced: true)
                        EvidenceValueRow(title: String(localized: "规则版本"), value: detail.ruleVersion, monospaced: true)
                    }

                    EvidenceSection(title: String(localized: "影响与恢复"), symbol: "arrow.uturn.backward.circle") {
                        if let allocatedBytes = detail.allocatedBytes,
                           let logicalBytes = detail.logicalBytes {
                            EvidenceValueRow(
                                title: String(localized: "磁盘占用"),
                                value: SystemFormatters.bytes.string(fromByteCount: allocatedBytes)
                            )
                            EvidenceValueRow(
                                title: String(localized: "逻辑大小"),
                                value: SystemFormatters.bytes.string(fromByteCount: logicalBytes)
                            )
                            if allocatedBytes != logicalBytes {
                                Text("磁盘占用与逻辑大小不同；两者均来自本轮扫描快照。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        EvidenceValueRow(
                            title: String(localized: "扫描时修改时间"),
                            value: detail.lastModifiedAt?.formatted(date: .abbreviated, time: .standard) ?? String(localized: "未记录")
                        )
                        EvidenceValueRow(title: String(localized: "影响级别"), value: detail.impactLevel.uninstallEvidenceTitle)
                        EvidenceValueRow(title: String(localized: "可能影响"), value: detail.impactText)
                        EvidenceValueRow(title: String(localized: "恢复方式"), value: detail.recoverability.uninstallEvidenceText)
                        if let restriction = detail.restrictionReason {
                            EvidenceValueRow(title: String(localized: "处理限制"), value: restriction.uninstallEvidenceText)
                        }
                    }

                    EvidenceSection(title: String(localized: "扫描覆盖"), symbol: "scope") {
                        Label(detail.coverageTitle, systemImage: coverageSymbol)
                            .font(.headline)
                            .foregroundStyle(coverageTint)
                        Text(detail.coverageExplanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let coverage = detail.coverage {
                            EvidenceValueRow(title: String(localized: "扫描上下文"), value: coverage.context.id.uuidString, monospaced: true)
                            EvidenceValueRow(title: "scopeID", value: coverage.scope.id, monospaced: true)
                            EvidenceValueRow(title: String(localized: "扫描器 / 阶段"), value: "\(coverage.scope.scanner.uninstallEvidenceTitle) / \(coverage.scope.phase.uninstallEvidenceTitle)")
                            EvidenceValueRow(title: String(localized: "根路径"), value: coverage.scope.rootPath, monospaced: true)
                            if let targetPath = coverage.scope.targetPath {
                                EvidenceValueRow(title: String(localized: "目标路径"), value: targetPath, monospaced: true)
                            }
                            EvidenceValueRow(title: String(localized: "开始时间"), value: coverage.startedAt?.formatted(date: .abbreviated, time: .standard) ?? "未开始")
                            EvidenceValueRow(title: String(localized: "结束时间"), value: coverage.finishedAt?.formatted(date: .abbreviated, time: .standard) ?? "未结束")

                            HStack(spacing: AppTheme.Spacing.sm) {
                                EvidenceMetric(title: String(localized: "问题总数"), value: coverage.issueCount)
                                EvidenceMetric(title: String(localized: "权限投影"), value: coverage.accessIssueCount)
                                EvidenceMetric(title: String(localized: "保留样本"), value: coverage.issues.count)
                                EvidenceMetric(title: String(localized: "省略"), value: coverage.omittedIssueCount)
                            }

                            if coverage.issues.isEmpty {
                                Text("本条覆盖记录没有保留结构化问题样本。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                    Text("结构化问题样本").font(.subheadline.weight(.semibold))
                                    ForEach(Array(coverage.issues.enumerated()), id: \.offset) { _, issue in
                                        EvidenceIssueRow(issue: issue)
                                    }
                                }
                            }
                        } else {
                            Label("未借用同类项目、父应用或其他扫描轮次的覆盖状态。", systemImage: "exclamationmark.shield")
                                .font(.caption)
                                .foregroundStyle(AppTheme.warning)
                        }
                    }

                    SafetyBanner(
                        title: String(localized: "处理边界"),
                        message: detail.processingBoundary,
                        symbol: detail.isReadOnlyAssociation ? "eye.fill" : "hand.raised.fill"
                    )

                    Text("扫描证据用于说明本轮固定规则及覆盖情况，不构成删除授权或安全保证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("扫描证据不构成删除授权或安全保证")
                }
                .padding(AppTheme.Spacing.lg)
            }
        }
        .frame(width: 760, height: 720)
        .background(AppTheme.obsidian)
    }

    private var residue: AppResidueCandidate? {
        guard case .residue(let residue) = detail.source else { return nil }
        return residue
    }

    private var coverageSymbol: String {
        switch detail.coverageStatus {
        case .completed: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .inaccessible: "lock.trianglebadge.exclamationmark"
        case .notFound: "questionmark.folder"
        case .skipped: "forward.end.circle"
        case .notSelected: "minus.circle"
        case .cancelled: "xmark.circle"
        case .notStarted: "circle.dashed"
        case .inProgress: "progress.indicator"
        case nil: "questionmark.circle"
        }
    }

    private var coverageTint: Color {
        switch detail.coverageStatus {
        case .completed: AppTheme.healthy
        case .partial, .inaccessible, .skipped, .cancelled: AppTheme.warning
        default: AppTheme.accent
        }
    }
}

private struct EvidenceSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct EvidenceValueRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct EvidenceMetric: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value.formatted()).font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.recessedSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct EvidenceIssueRow: View {
    let issue: ScanIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(issue.kind.uninstallEvidenceTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(issue.projectsToLegacyAccessIssues ? String(localized: "进入原有权限提示") : String(localized: "仅结构化记录"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(issue.projectsToLegacyAccessIssues ? AppTheme.warning : AppTheme.accent)
            }
            if let path = issue.path {
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(issue.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let restriction = issue.restrictionReason {
                Text("限制：\(restriction.uninstallEvidenceText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let domain = issue.underlyingErrorDomain, let code = issue.underlyingErrorCode {
                Text("\(domain) · \(code)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.recessedSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
    }
}

private extension ScannerKind {
    var uninstallEvidenceTitle: String {
        switch self {
        case .disk: String(localized: "磁盘扫描")
        case .application: String(localized: "应用扫描")
        case .residue: String(localized: "残留扫描")
        case .association: String(localized: "关联扫描")
        }
    }
}

private extension ScanPhase {
    var uninstallEvidenceTitle: String {
        switch self {
        case .discover: String(localized: "发现")
        case .measure: String(localized: "测量")
        case .inspect: String(localized: "核对")
        case .associate: String(localized: "关联")
        }
    }
}

extension ApplicationSortOption {
    var localizedName: String {
        switch self {
        case .name: String(localized: "名称")
        case .size: String(localized: "占用空间")
        case .modified: String(localized: "最近修改")
        }
    }
}

extension AppAssociationRelationship {
    var localizedName: String {
        switch self {
        case .insideApplication: String(localized: "位于应用包内部")
        case .exactLabel: String(localized: "配置标签与 Bundle Identifier 精确同源")
        case .applicationPathReference: String(localized: "配置明确引用应用路径")
        case .exactNamespace: String(localized: "标识符属于 Bundle Identifier 命名空间")
        }
    }
}

extension AppAssociationKind {
    var localizedName: String {
        switch self {
        case .embeddedLoginItem: String(localized: "内嵌登录项")
        case .userLaunchAgent: String(localized: "用户登录代理")
        case .systemLaunchAgent: String(localized: "系统登录代理")
        case .systemLaunchDaemon: String(localized: "系统守护进程")
        case .privilegedHelper: String(localized: "特权辅助工具")
        case .packageReceipt: String(localized: "安装收据")
        }
    }

    var symbol: String {
        switch self {
        case .embeddedLoginItem: "rectangle.stack.badge.play"
        case .userLaunchAgent: "person.crop.circle.badge.clock"
        case .systemLaunchAgent: "gearshape.2"
        case .systemLaunchDaemon: "bolt.horizontal.circle"
        case .privilegedHelper: "lock.shield"
        case .packageReceipt: "doc.badge.gearshape"
        }
    }
}

private struct IdentityRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 116, alignment: .leading)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UninstallProgressCard: View {
    let progress: UninstallProgress
    let cancelAction: () -> Void

    private var fraction: Double {
        guard progress.totalCount > 0 else { return 0 }
        return Double(progress.completedCount) / Double(progress.totalCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("正在移到废纸篓").font(.title2.bold())
                    Text("已处理 \(progress.completedCount.formatted()) / \(progress.totalCount.formatted()) 项")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("停止后续处理", systemImage: "stop.fill", action: cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }

            ProgressView(value: fraction)
                .accessibilityLabel("卸载进度")
                .accessibilityValue("\(Int(fraction * 100))%")

            HStack(spacing: AppTheme.Spacing.md) {
                UninstallMetric(title: String(localized: "已移入废纸篓"), value: SystemFormatters.bytes.string(fromByteCount: progress.movedBytes), symbol: "trash.fill")
                UninstallMetric(title: String(localized: "跳过或失败"), value: progress.failureCount.formatted(), symbol: "exclamationmark.shield")
            }

            Text(progress.currentPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Label("停止只阻止后续项目；已经移动的内容仍可从废纸篓恢复。", systemImage: "arrow.uturn.backward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardSurface()
    }
}

private struct UninstallCompletionCard: View {
    let receipt: ExecutionReceipt
    let applicationName: String
    let historySaveWarning: String?
    let returnAction: () -> Void
    let rescanAction: () -> Void

    private var applicationMoved: Bool {
        receipt.items.first?.status == .succeeded
    }

    private var tint: Color {
        if receipt.count(for: .failed) > 0 { return AppTheme.danger }
        if receipt.wasUserAborted || receipt.succeededCount < receipt.expectedItemCount { return AppTheme.warning }
        return AppTheme.healthy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                Image(systemName: applicationMoved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(applicationMoved ? String(localized: "\(applicationName) 已移到废纸篓") : String(localized: "应用本体已保留"))
                        .font(.title2.bold())
                    Text("计划 \(receipt.expectedItemCount.formatted()) 项，成功移入废纸篓 \(receipt.succeededCount.formatted()) 项。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ExecutionReceiptSummaryView(receipt: receipt)

            if let historySaveWarning {
                Label("处理已完成，但本地记录保存失败：\(historySaveWarning)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
            }

            HStack {
                Spacer()
                if !applicationMoved {
                    Button("返回所选应用", systemImage: "arrow.backward", action: returnAction)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Button("重新扫描应用", systemImage: "arrow.clockwise", action: rescanAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .cardSurface()
    }
}

private struct ScanCoverageNotice: View {
    let issues: [String]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("如确实需要读取受保护位置，可在设置中查看完全磁盘访问权限说明。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, AppTheme.Spacing.sm)
        } label: {
            Label(
                "扫描完成，但有 \(issues.count.formatted()) 个位置未能读取",
                systemImage: "lock.trianglebadge.exclamationmark"
            )
            .font(.callout.weight(.semibold))
        }
        .foregroundStyle(AppTheme.warning)
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
    }
}

private struct UninstallMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: symbol).foregroundStyle(Color.indigo).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline.monospacedDigit())
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.recessedSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct UninstallerStatusCard: View {
    let title: String
    let message: String
    let symbol: String
    let tint: Color
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                Image(systemName: symbol).font(.title2).foregroundStyle(tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(title).font(.title2.bold())
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
            }
            Button(actionTitle, systemImage: "arrow.clockwise", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .cardSurface()
    }
}

#Preview("深度卸载") {
    let ignoreList = IgnoreListStore(repository: InMemoryIgnoreRuleRepository(), autoload: false)
    UninstallerView(ignoreList: ignoreList)
        .frame(width: 1_000, height: 760)
        .environmentObject(AppSettings())
        .environmentObject(AppNavigationState())
}
