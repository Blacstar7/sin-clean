import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension CleanupRisk {
    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "questionmark.diamond.fill"
        case .caution: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .safe: AppTheme.healthy
        case .review: AppTheme.warning
        case .caution: AppTheme.danger
        }
    }
}

struct CleanupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject private var ignoreList: IgnoreListStore
    @StateObject private var viewModel: CleanupViewModel
    @StateObject private var candidateActions = CandidateFileActionCoordinator()
    @State private var reviewedResult: CleanupScanResult?
    @State private var showsCleanupConfirmation = false
    @State private var exportFeedback: OperationPlanExportFeedback?

    init(
        ignoreList: IgnoreListStore,
        historyStore: any CleanupHistoryStoring = CleanupHistoryStore()
    ) {
        self.ignoreList = ignoreList
        _viewModel = StateObject(wrappedValue: CleanupViewModel(
            historyStore: historyStore,
            ignoreList: ignoreList
        ))
    }

    #if DEBUG
    init(previewViewModel: CleanupViewModel, ignoreList: IgnoreListStore) {
        self.ignoreList = ignoreList
        _viewModel = StateObject(wrappedValue: previewViewModel)
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                FeatureHeader(
                    eyebrow: String(localized: "安全清理 · 可恢复"),
                    title: String(localized: "可清理项目"),
                    description: String(localized: "扫描后逐项选择；确认后移入废纸篓。"),
                    symbol: "internaldrive.fill",
                    tint: AppTheme.accent
                )

                phaseContent
                    .id(presentationKey)
            }
            .padding(AppTheme.Spacing.xl)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .background(.clear)
        .sheet(item: $reviewedResult) { result in
            CandidateReviewSheet(
                result: result,
                viewModel: viewModel,
                actionCoordinator: candidateActions,
                ignoreList: ignoreList
            )
            .frame(minWidth: 760, idealWidth: 1_020, minHeight: 590, idealHeight: 700)
        }
        .confirmationDialog(
            "确认将所选文件移到废纸篓？",
            isPresented: $showsCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                viewModel.startCleanup()
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
    private var phaseContent: some View {
        switch viewModel.phase {
        case .idle:
            ScanIntroduction(startAction: startScan)
        case .scanning:
            ScanProgressCard(progress: viewModel.progress, cancelAction: viewModel.cancelScan)
        case .completed:
            completedContent
        case .cancelled:
            ScanStatusCard(
                title: String(localized: "扫描已取消"),
                message: String(localized: "未保存不完整结果，也没有更改任何文件。"),
                symbol: "xmark.circle.fill",
                tint: AppTheme.warning,
                actionTitle: String(localized: "重新扫描"),
                action: viewModel.startScan
            )
        case .failed(let message):
            ScanStatusCard(
                title: String(localized: "扫描未完成"),
                message: message,
                symbol: "exclamationmark.triangle.fill",
                tint: AppTheme.danger,
                actionTitle: String(localized: "重试"),
                action: viewModel.startScan
            )
        }
    }

    @ViewBuilder
    private var completedContent: some View {
        switch viewModel.cleanupPhase {
        case .idle:
            ScanResults(
                viewModel: viewModel,
                ignoreList: ignoreList,
                reviewAction: { reviewedResult = $0 },
                exportAction: preparePlanExport,
                exportFeedback: exportFeedback,
                cleanupAction: { showsCleanupConfirmation = true },
                restartAction: startScan,
                manageIgnoreListAction: { navigation.request(.settings) }
            )
        case .running:
            CleanupProgressCard(progress: viewModel.cleanupProgress, cancelAction: viewModel.cancelCleanup)
        case .completed:
            if let receipt = viewModel.lastExecutionReceipt {
                CleanupCompletionCard(
                    receipt: receipt,
                    historySaveWarning: viewModel.historySaveWarning,
                    rescanAction: startScan
                )
            } else if let error = viewModel.executionReceiptBuildError {
                ExecutionReceiptFailureView(
                    error: error,
                    primaryTitle: String(localized: "重新扫描"),
                    primaryAction: startScan
                )
            }
        }
    }

    private var confirmationMessage: String {
        var message = String(localized: "共 \(viewModel.selectedFileCount.formatted()) 个文件，预计 \(SystemFormatters.bytes.string(fromByteCount: viewModel.selectedBytes))。路径摘要：\(viewModel.selectedPathSummary)。执行前会再次核对路径、文件类型和扫描时的文件身份。")
        if viewModel.selectedReviewFileCount > 0 {
            message += String(localized: " 其中 \(viewModel.selectedReviewFileCount.formatted()) 个属于建议确认项目。")
        }
        return message
    }

    private func startScan() {
        exportFeedback = nil
        viewModel.startScan()
    }

    private var presentationKey: String {
        switch viewModel.phase {
        case .idle: "idle"
        case .scanning: "scanning"
        case .cancelled: "cancelled"
        case .failed: "failed"
        case .completed:
            switch viewModel.cleanupPhase {
            case .idle: "results"
            case .running: "cleaning"
            case .completed: "completion"
            }
        }
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
                message: String(localized: "无法生成清理计划：\(error.localizedDescription)"),
                kind: .failure
            )
        }
    }

    private func handlePlanExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            exportFeedback = OperationPlanExportFeedback(
                message: String(localized: "清理计划已导出。选择、忽略规则和执行状态均未改变。"),
                kind: .success
            )
        case .failure(let error) where OperationPlanExportUI.isCancellation(error):
            exportFeedback = OperationPlanExportFeedback(
                message: String(localized: "已取消导出，没有创建计划文件或更改选择。"),
                kind: .cancelled
            )
        case .failure(let error):
            exportFeedback = OperationPlanExportFeedback(
                message: String(localized: "清理计划未能导出：\(error.localizedDescription)。"),
                kind: .failure
            )
        }
    }

}

private struct ScanIntroduction: View {
    let startAction: () -> Void

    private let scopes = [
        (String(localized: "用户与应用缓存"), "~/Library/Caches", CleanupRisk.safe),
        (String(localized: "用户日志"), "~/Library/Logs", CleanupRisk.safe),
        (String(localized: "崩溃报告"), "~/Library/Application Support/CrashReporter", CleanupRisk.safe),
        (String(localized: "下载的安装包"), String(localized: "~/Downloads 中的 DMG、PKG、ZIP、XIP、ISO"), CleanupRisk.review)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("扫描 4 个位置")
                        .font(.title2.bold())
                    Text("只读检查文件信息；扫描完成后再逐项选择。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppTheme.Spacing.md)
                Button("开始扫描", systemImage: "sparkle.magnifyingglass", action: startAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                    .accessibilityHint("只读取四个用户目录中的文件元数据")
            }
            .cardSurface()

            SafetyBanner(
                title: String(localized: "默认不勾选，清理可恢复"),
                message: String(localized: "扫描只读取元数据。扫描后由您逐项勾选，并在二次确认后移到废纸篓；不会永久删除。"),
                symbol: "hand.raised.fill"
            )

            InformationDisclosure(
                title: String(localized: "查看扫描范围"),
                summary: String(localized: "缓存、日志、崩溃报告和下载的安装包"),
                symbol: "folder.badge.gearshape",
                tint: AppTheme.accent
            ) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    ForEach(Array(scopes.enumerated()), id: \.offset) { _, scope in
                        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                            Image(systemName: scope.2.symbol)
                                .foregroundStyle(scope.2.tint)
                                .font(.title3)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                Text(scope.0).font(.body.weight(.medium))
                                Text(scope.1)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            RiskBadge(risk: scope.2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text("扫描时间取决于缓存和下载目录中的文件数量。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ScanProgressCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: CleanupScanProgress
    let cancelAction: () -> Void

    private var stageText: String {
        guard progress.totalLocations > 0 else { return String(localized: "正在准备") }
        return String(localized: "第 \(min(progress.completedLocations + 1, progress.totalLocations)) / \(progress.totalLocations) 项")
    }

    private var locationFraction: Double {
        guard progress.totalLocations > 0 else { return 0 }
        return min(1, Double(progress.completedLocations) / Double(progress.totalLocations))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(spacing: AppTheme.Spacing.lg) {
                ScanFocusOrb(
                    fraction: locationFraction,
                    reduceMotion: reduceMotion
                )

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("正在扫描：\(progress.currentLocation)").font(.title2.bold())
                    Text(stageText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消扫描", systemImage: "xmark", action: cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: AppTheme.Spacing.md) {
                ScanMetric(title: String(localized: "已检查文件"), value: progress.inspectedFileCount.formatted(), symbol: "doc.text.magnifyingglass")
                ScanMetric(title: String(localized: "发现候选空间"), value: SystemFormatters.bytes.string(fromByteCount: progress.candidateBytes), symbol: "externaldrive.badge.checkmark")
            }

            ProgressView(value: locationFraction)
                .tint(AppTheme.accent)
                .accessibilityLabel("扫描位置进度")
                .accessibilityValue("\(Int(locationFraction * 100))%")
                .animation(.easeOut(duration: 0.2), value: locationFraction)

            Text("可随时取消；扫描不会改动磁盘内容。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardSurface()
    }
}

private struct ScanFocusOrb: View {
    let fraction: Double
    let reduceMotion: Bool
    @State private var isRotating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [AppTheme.violet.opacity(0.20), AppTheme.accent.opacity(0.055), .clear],
                        center: .center,
                        startRadius: 2,
                        endRadius: 46
                    )
                )

            Circle()
                .stroke(.white.opacity(0.09), lineWidth: 5)

            Circle()
                .trim(from: 0, to: max(0.055, min(1, fraction)))
                .stroke(
                    AngularGradient(
                        colors: [AppTheme.accent, AppTheme.violet, AppTheme.accent],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.34, dampingFraction: 0.88), value: fraction)

            Circle()
                .trim(from: 0.03, to: 0.20)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.16), AppTheme.accent, .white.opacity(0.16)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(isRotating ? 360 : 0))

            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 26, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppTheme.accent)
        }
        .frame(width: 92, height: 92)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                isRotating = true
            }
        }
        .onDisappear {
            isRotating = false
        }
        .accessibilityHidden(true)
    }
}

private struct ScanResults: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var viewModel: CleanupViewModel
    @ObservedObject var ignoreList: IgnoreListStore
    @State private var isRevealed = false
    let reviewAction: (CleanupScanResult) -> Void
    let exportAction: () -> Void
    let exportFeedback: OperationPlanExportFeedback?
    let cleanupAction: () -> Void
    let restartAction: () -> Void
    let manageIgnoreListAction: () -> Void

    private var report: CleanupScanReport? { viewModel.report }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(spacing: AppTheme.Spacing.md) {
                SummaryMetric(title: String(localized: "发现候选空间"), value: SystemFormatters.bytes.string(fromByteCount: report?.totalBytes ?? 0))
                SummaryMetric(title: String(localized: "候选文件"), value: (report?.totalFileCount ?? 0).formatted())
                SummaryMetric(title: String(localized: "当前已勾选"), value: SystemFormatters.bytes.string(fromByteCount: viewModel.selectedBytes))
                SummaryMetric(title: String(localized: "已忽略"), value: viewModel.ignoredCandidateCount.formatted())
            }
            .cleanupReveal(index: 0, isRevealed: isRevealed, reduceMotion: reduceMotion)

            HStack {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("扫描结果").font(.title2.bold())
                    Text("默认不勾选。可整类选择，也可进入逐项复核。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("已选 \(viewModel.selectedFileCount.formatted()) 个")
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
            .cleanupReveal(index: 1, isRevealed: isRevealed, reduceMotion: reduceMotion)

            if report?.totalFileCount == 0 {
                EmptyScanResult()
                    .cleanupReveal(index: 2, isRevealed: isRevealed, reduceMotion: reduceMotion)
            } else {
                ForEach(viewModel.results) { result in
                    CleanupResultRow(
                        result: result,
                        selectedCount: viewModel.selectedCount(in: result),
                        visibleCount: viewModel.visibleCandidates(in: result).count,
                        ignoredCount: viewModel.ignoredCount(in: result),
                        selectionAction: { viewModel.setSelected($0, result: result) },
                        reviewAction: { reviewAction(result) }
                    )
                }
            }

            IgnoreListStatusBanner(
                loadState: ignoreList.loadState,
                ignoredCount: viewModel.ignoredCandidateCount,
                manageAction: manageIgnoreListAction
            )

            if let issueCount = report?.accessIssueCount, issueCount > 0 {
                Label(
                    "有 \(issueCount) 个位置因权限或文件状态变化未能读取；这些位置不会进入清理清单。",
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
                .font(.callout)
                .foregroundStyle(AppTheme.warning)
                .padding(AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.warning.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                .cleanupReveal(index: 7, isRevealed: isRevealed, reduceMotion: reduceMotion)
            }

            SafetyBanner(
                title: String(localized: "执行前再次复核"),
                message: String(localized: "仅允许处理扫描范围内、未经过符号链接且扫描后没有被替换或更改的普通文件。"),
                symbol: "lock.shield.fill"
            )
            .cleanupReveal(index: 8, isRevealed: isRevealed, reduceMotion: reduceMotion)

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

            HStack {
                Button("重新扫描", systemImage: "arrow.clockwise", action: restartAction)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                Button("导出计划", systemImage: "doc.badge.arrow.up", action: exportAction)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!viewModel.canExportOperationPlan)
                    .help(viewModel.canExportOperationPlan ? String(localized: "导出当前选择的只读清理计划，不执行清理") : String(localized: "请先完成扫描并勾选至少一个未忽略候选"))
                    .accessibilityLabel("导出磁盘清理计划")
                    .accessibilityHint("打开保存面板；只导出当前选择的只读快照，不会执行清理")
                Button("移到废纸篓", systemImage: "trash", action: cleanupAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.selectedFileCount == 0)
                    .help(viewModel.selectedFileCount == 0 ? String(localized: "请先勾选要处理的文件") : String(localized: "清理前会显示二次确认"))
            }
            .cleanupReveal(index: 9, isRevealed: isRevealed, reduceMotion: reduceMotion)
        }
        .onAppear {
            isRevealed = reduceMotion
            guard !reduceMotion else { return }
            withAnimation(AppTheme.Motion.scanReveal) {
                isRevealed = true
            }
        }
        .onDisappear {
            isRevealed = false
        }
    }
}

private struct EmptyScanResult: View {
    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.healthy)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("当前扫描范围很干净")
                    .font(.headline)
                Text("没有发现符合安全规则的候选文件。您可以稍后重新扫描，无需进行清理。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .liquidGlassSurface(tint: AppTheme.healthy)
        .accessibilityElement(children: .combine)
    }
}

private struct CleanupResultRow: View {
    let result: CleanupScanResult
    let selectedCount: Int
    let visibleCount: Int
    let ignoredCount: Int
    let selectionAction: (Bool) -> Void
    let reviewAction: () -> Void
    @State private var isExpanded = false

    private var isAllSelected: Bool { visibleCount > 0 && selectedCount == visibleCount }
    private var selectionSymbol: String {
        if selectedCount == 0 { return "square" }
        if isAllSelected { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                Button {
                    selectionAction(!isAllSelected)
                } label: {
                    Image(systemName: selectionSymbol)
                        .font(.title3)
                        .foregroundStyle(selectedCount == 0 ? Color.secondary : AppTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(visibleCount == 0)
                .accessibilityLabel(isAllSelected ? String(localized: "取消选择 \(result.name)") : String(localized: "选择 \(result.name)"))

                Image(systemName: result.risk.symbol)
                    .foregroundStyle(result.risk.tint)
                    .font(.title3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(result.name).font(.headline)
                        RiskBadge(risk: result.risk)
                    }
                    Text(result.description).font(.callout).foregroundStyle(.secondary)
                    Text(result.sourcePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: AppTheme.Spacing.md)
                VStack(alignment: .trailing, spacing: AppTheme.Spacing.xs) {
                    Text(SystemFormatters.bytes.string(fromByteCount: result.totalBytes))
                        .font(.headline.monospacedDigit())
                    Text("已选 \(selectedCount.formatted()) / 可见 \(visibleCount.formatted())")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if ignoredCount > 0 {
                        Text("精确忽略 \(ignoredCount.formatted()) 项 · 原始候选 \(result.fileCount.formatted())")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AppTheme.accent)
                    }
                    Button("逐项复核", systemImage: "list.bullet.rectangle", action: reviewAction)
                        .buttonStyle(.bordered)
                        .disabled(visibleCount == 0)
                }
            }

            if !result.largestFiles.isEmpty || !result.accessIssues.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        if !result.largestFiles.isEmpty {
                            Text("占用最大的文件").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(result.largestFiles) { FileCandidateRow(file: $0) }
                        }
                        if !result.accessIssues.isEmpty {
                            Divider()
                            Text("未能读取").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.warning)
                            ForEach(Array(result.accessIssues.enumerated()), id: \.offset) { _, issue in
                                Text(issue).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, AppTheme.Spacing.sm)
                } label: {
                    Text(isExpanded ? String(localized: "收起详情") : String(localized: "查看详情")).font(.caption.weight(.medium))
                }
            }
        }
        .liquidGlassSurface(tint: result.risk.tint, interactive: true)
    }
}

struct CandidateReviewSheet: View {
    let result: CleanupScanResult
    @ObservedObject var viewModel: CleanupViewModel
    @ObservedObject var actionCoordinator: CandidateFileActionCoordinator
    @ObservedObject var ignoreList: IgnoreListStore
    var initialHighlightedCandidateID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var highlightedCandidateID: String?
    @State private var pendingIgnore: CleanupIgnoreRequest?

    private var filteredCandidates: [CleanupFileCandidate] {
        let visible = viewModel.visibleCandidates(in: result)
        guard !searchText.isEmpty else { return visible }
        return visible.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredCandidateIDs: [String] { filteredCandidates.map(\.id) }

    private var highlightedCandidate: CleanupFileCandidate? {
        guard let highlightedCandidateID else { return nil }
        return filteredCandidates.first { $0.id == highlightedCandidateID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(result.name).font(.title2.bold())
                    Text("高亮用于查看证据，勾选才会进入清理确认；两者互不改变。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成", action: dismiss.callAsFunction)
                    .keyboardShortcut(.defaultAction)
                    .help("关闭候选详情；不会更改当前勾选")
                    .accessibilityLabel("完成候选详情检查")
            }
            .padding(AppTheme.Spacing.lg)

            Divider()

            HStack(spacing: 0) {
                candidateList
                    .frame(minWidth: 280, idealWidth: 330, maxWidth: 370)

                Divider()

                candidateInspector
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.obsidian)
        .accessibilityElement(children: .contain)
        .onAppear {
            highlightedCandidateID = CandidateReviewHighlight.reconciled(
                initialHighlightedCandidateID,
                visibleCandidateIDs: filteredCandidateIDs
            )
        }
        .onChange(of: filteredCandidateIDs) { _, candidateIDs in
            highlightedCandidateID = CandidateReviewHighlight.reconciled(
                highlightedCandidateID,
                visibleCandidateIDs: candidateIDs
            )
        }
        .onDisappear {
            actionCoordinator.endCandidateReview()
        }
        .alert(item: $actionCoordinator.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
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
            Text(ignoreList.persistenceError ?? String(localized: "请稍后重试。"))
        }
    }

    private var candidateList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    RiskBadge(risk: result.risk)
                    Spacer()
                    Text("已选 \(viewModel.selectedCount(in: result).formatted()) / 可见 \(viewModel.visibleCandidates(in: result).count.formatted())")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                TextField("搜索完整路径", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索候选文件完整路径")

                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("清除选择") { viewModel.setSelected(false, result: result) }
                        .disabled(viewModel.selectedCount(in: result) == 0)
                        .help("取消勾选本类别中的全部候选")
                        .accessibilityLabel("清除本类别全部清理选择")
                    Button("选择全部") { viewModel.setSelected(true, result: result) }
                        .disabled(filteredCandidates.isEmpty || viewModel.selectedCount(in: result) == viewModel.visibleCandidates(in: result).count)
                        .help("主动勾选本类别中的全部候选")
                        .accessibilityLabel("选择本类别全部候选用于清理")
                }
                .buttonStyle(.bordered)

                if !searchText.isEmpty {
                    Button("清除搜索", systemImage: "xmark.circle") {
                        searchText = ""
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .help("恢复显示全部候选")
                    .accessibilityLabel("清除候选路径搜索")
                }
            }
            .padding(AppTheme.Spacing.md)

            Divider()

            if filteredCandidates.isEmpty {
                ContentUnavailableView(
                    result.candidates.isEmpty ? String(localized: "没有候选") : String(localized: "没有匹配项"),
                    systemImage: result.candidates.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass",
                    description: Text(result.candidates.isEmpty ? String(localized: "本类别没有可供逐项检查的候选。") : String(localized: "请调整搜索内容。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $highlightedCandidateID) {
                    ForEach(filteredCandidates) { candidate in
                        CandidateReviewRow(
                            candidate: candidate,
                            isSelected: Binding(
                                get: { viewModel.isSelected(candidate) },
                                set: { viewModel.setSelected($0, candidate: candidate) }
                            )
                        )
                        .tag(candidate.id)
                    }
                }
                .listStyle(.inset)
                .accessibilityLabel("可清理项目候选列表")
            }
        }
        .background(AppTheme.recessedSurface.opacity(0.58))
    }

    private var candidateInspector: some View {
        VStack(spacing: 0) {
            CandidateDetailActionBar(
                candidate: highlightedCandidate,
                revealAction: { candidate in actionCoordinator.revealInFinder(candidate) },
                previewAction: { candidate in actionCoordinator.preview(candidate) },
                ignoreCandidateAction: { pendingIgnore = CleanupIgnoreRequest(candidate: $0, scope: .candidate) },
                ignorePathAction: { pendingIgnore = CleanupIgnoreRequest(candidate: $0, scope: .path) }
            )

            Divider()

            if let highlightedCandidate {
                ScrollView(.vertical) {
                    CandidateDetailInspector(
                        detail: CleanupCandidateDetail(
                            candidate: highlightedCandidate,
                            coverageRecords: result.coverage
                        ),
                        isSelectedForCleanup: viewModel.isSelected(highlightedCandidate)
                    )
                    .padding(AppTheme.Spacing.lg)
                }
            } else {
                ContentUnavailableView(
                    "选择一个候选查看证据",
                    systemImage: "sidebar.right",
                    description: Text("在左侧高亮候选不会自动勾选，也不会执行清理。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct CandidateReviewRow: View {
    let candidate: CleanupFileCandidate
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Toggle("选择 \(URL(fileURLWithPath: candidate.path).lastPathComponent) 用于清理", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("勾选此候选用于清理")

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(URL(fileURLWithPath: candidate.path).lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(candidate.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(SystemFormatters.bytes.string(fromByteCount: candidate.allocatedBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
        .accessibilityElement(children: .contain)
    }
}

private struct CandidateDetailActionBar: View {
    let candidate: CleanupFileCandidate?
    let revealAction: (CleanupFileCandidate) -> Void
    let previewAction: (CleanupFileCandidate) -> Void
    let ignoreCandidateAction: (CleanupFileCandidate) -> Void
    let ignorePathAction: (CleanupFileCandidate) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("在 Finder 中显示", systemImage: "folder") {
                if let candidate { revealAction(candidate) }
            }
            .buttonStyle(.bordered)
            .disabled(candidate == nil)
            .help(candidate == nil ? String(localized: "请先在左侧高亮一个候选") : String(localized: "复核扫描时身份后在 Finder 中定位"))
            .accessibilityLabel("在 Finder 中显示当前候选")

            Button("快速查看", systemImage: "eye") {
                if let candidate { previewAction(candidate) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(candidate == nil)
            .help(candidate == nil ? String(localized: "请先在左侧高亮一个候选") : String(localized: "复核扫描时身份后使用 Quick Look 预览"))
            .accessibilityLabel("快速查看当前候选")

            Menu {
                Button("仅忽略这个候选") {
                    if let candidate { ignoreCandidateAction(candidate) }
                }
                Button("忽略这个精确路径") {
                    if let candidate { ignorePathAction(candidate) }
                }
            } label: {
                Label("忽略…", systemImage: "eye.slash")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(candidate == nil)
            .help("选择精确忽略范围；不会清理或移动文件")
            .accessibilityLabel("选择当前候选的精确忽略范围")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
    }
}

private struct CleanupIgnoreRequest {
    enum Scope { case candidate, path }

    let candidate: CleanupFileCandidate
    let scope: Scope

    var title: String {
        switch scope {
        case .candidate: String(localized: "仅忽略这个清理候选？")
        case .path: String(localized: "忽略这个精确路径？")
        }
    }

    var actionTitle: String {
        switch scope {
        case .candidate: String(localized: "仅忽略这个候选")
        case .path: String(localized: "忽略这个精确路径")
        }
    }

    var message: String {
        switch scope {
        case .candidate:
            String(localized: "只匹配位置标识 \(candidate.locationID) 与完整路径同时相等的候选：\(candidate.path)。不会匹配父目录、子目录、相似名称或大小写差异。")
        case .path:
            String(localized: "只匹配统一格式后完整字符串相等的路径：\(candidate.path)。不会匹配父目录、子目录、相似名称，不解析符号链接。")
        }
    }

    var rule: IgnoreRule {
        switch scope {
        case .candidate: .cleanupCandidate(candidate)
        case .path: .fixedPath(candidate.path)
        }
    }
}

private struct CandidateDetailInspector: View {
    let detail: CleanupCandidateDetail
    let isSelectedForCleanup: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(detail.categoryName)
                        .font(.title3.bold())
                    Text(detail.categoryIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Label(isSelectedForCleanup ? String(localized: "已勾选清理") : String(localized: "仅查看，未勾选"), systemImage: isSelectedForCleanup ? "checkmark.square.fill" : "square")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelectedForCleanup ? AppTheme.accent : Color.secondary)
            }

            Label(
                "扫描证据解释候选为何出现，不代表删除授权或安全保证。",
                systemImage: "doc.text.magnifyingglass"
            )
            .font(.callout)
            .foregroundStyle(AppTheme.warning)
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))

            DetailSection(title: String(localized: "文件与扫描快照"), symbol: "doc") {
                DetailPath(label: String(localized: "完整路径"), value: detail.evidence.sourcePath)
                DetailValue(label: String(localized: "磁盘占用"), value: SystemFormatters.bytes.string(fromByteCount: detail.candidate.allocatedBytes))
                if detail.candidate.logicalBytes != detail.candidate.allocatedBytes {
                    DetailValue(label: String(localized: "逻辑大小"), value: SystemFormatters.bytes.string(fromByteCount: detail.candidate.logicalBytes))
                }
                DetailValue(
                    label: String(localized: "扫描时修改时间"),
                    value: detail.evidence.lastModifiedAt?.formatted(date: .numeric, time: .standard) ?? String(localized: "未取得")
                )
            }

            DetailSection(title: String(localized: "候选证据"), symbol: "checklist") {
                DetailPath(label: String(localized: "固定规则码"), value: detail.evidence.reasonCode.rawValue)
                DetailParagraph(label: String(localized: "判定依据"), value: detail.evidence.reasonText)
                DetailValue(label: String(localized: "影响级别"), value: detail.evidence.impactLevel.detailTitle)
                DetailParagraph(label: String(localized: "可能影响"), value: detail.evidence.impactText)
                DetailParagraph(label: String(localized: "恢复方式"), value: detail.evidence.recoverability.detailTitle)
                DetailPath(label: String(localized: "规则版本"), value: detail.evidence.ruleVersion)
            }

            DetailSection(title: String(localized: "扫描范围与覆盖"), symbol: "scope") {
                HStack(spacing: AppTheme.Spacing.sm) {
                    CoverageStatusBadge(status: detail.coverage?.status)
                    Text(detail.coverageExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let coverage = detail.coverage {
                    DetailPath(label: String(localized: "范围标识"), value: coverage.scope.id)
                    DetailPath(label: String(localized: "根路径"), value: coverage.scope.rootPath)
                    if let policySummary = detail.policySummary {
                        DetailParagraph(label: String(localized: "本轮策略"), value: policySummary)
                    }
                } else {
                    Text("未找到与 evidenceOrigin.context.id 和 scopeID 同时匹配的覆盖记录。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DetailSection(title: String(localized: "结构化问题"), symbol: "exclamationmark.bubble") {
                if let coverage = detail.coverage {
                    HStack(spacing: AppTheme.Spacing.lg) {
                        IssueMetric(title: String(localized: "问题总数"), value: coverage.issueCount)
                        IssueMetric(title: String(localized: "权限投影"), value: coverage.accessIssueCount)
                        IssueMetric(title: String(localized: "保留样本"), value: coverage.issues.count)
                        IssueMetric(title: String(localized: "省略数量"), value: coverage.omittedIssueCount)
                    }
                    if coverage.issues.isEmpty {
                        Text("本范围没有保留的结构化问题样本。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(coverage.issues.enumerated()), id: \.offset) { _, issue in
                            StructuredIssueRow(issue: issue)
                        }
                    }
                } else {
                    Text("覆盖记录未知，无法报告问题总数或样本；建议重新扫描。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
    }
}

private struct DetailValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.md) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct DetailPath: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DetailParagraph: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CoverageStatusBadge: View {
    let status: CoverageStatus?

    private var tint: Color {
        switch status {
        case .completed: return AppTheme.healthy
        case .partial, .notStarted, .inProgress: return AppTheme.warning
        case .inaccessible, .cancelled: return AppTheme.danger
        case .skipped, .notFound, .notSelected, nil: return .secondary
        }
    }

    var body: some View {
        Label(status?.detailTitle ?? String(localized: "覆盖状态未知"), systemImage: status == .completed ? "checkmark.circle.fill" : "info.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct IssueMetric: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.callout.monospacedDigit().weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct StructuredIssueRow: View {
    let issue: ScanIssue

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(issue.kind.detailTitle).font(.caption.weight(.semibold))
                Text(issue.kind.rawValue).font(.caption2.monospaced()).foregroundStyle(.secondary)
                if issue.projectsToLegacyAccessIssues {
                    Text("旧权限提示")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.warning)
                }
            }
            Text(issue.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }
}

private struct CleanupProgressCard: View {
    let progress: CleanupExecutionProgress
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
                    Text("已处理 \(progress.completedCount.formatted()) / \(progress.totalCount.formatted()) 个文件")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("停止后续处理", systemImage: "stop.fill", action: cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }

            ProgressView(value: fraction)
                .accessibilityLabel("清理进度")
                .accessibilityValue("\(Int(fraction * 100))%")

            HStack(spacing: AppTheme.Spacing.md) {
                ScanMetric(title: String(localized: "已移入废纸篓"), value: SystemFormatters.bytes.string(fromByteCount: progress.movedBytes), symbol: "trash.fill")
                ScanMetric(title: String(localized: "跳过或失败"), value: progress.failureCount.formatted(), symbol: "exclamationmark.shield")
            }

            Text(progress.currentPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Label("停止只会阻止后续文件；已经移入废纸篓的文件仍可在 Finder 中恢复。", systemImage: "arrow.uturn.backward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardSurface()
    }
}

private struct CleanupCompletionCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let receipt: ExecutionReceipt
    let historySaveWarning: String?
    let rescanAction: () -> Void
    @State private var isRevealed = false

    private var tint: Color {
        if receipt.count(for: .failed) > 0 { return AppTheme.danger }
        if receipt.wasUserAborted || receipt.count(for: .skipped) > 0 || receipt.count(for: .notExecuted) > 0 {
            return AppTheme.warning
        }
        return AppTheme.healthy
    }

    private var title: String {
        if receipt.wasUserAborted { return String(localized: "清理已按用户请求中止") }
        if receipt.succeededCount == 0 { return String(localized: "清理完成，没有项目成功处理") }
        if receipt.succeededCount < receipt.expectedItemCount { return String(localized: "清理完成，部分项目未处理") }
        return String(localized: "清理完成")
    }

    private var detail: String {
        if receipt.succeededCount == 0 {
            return String(localized: "没有项目移入废纸篓。下方收据逐项说明失败、跳过、中止或未执行原因。")
        }
        return String(localized: "计划 \(receipt.expectedItemCount.formatted()) 项，成功移入废纸篓 \(receipt.succeededCount.formatted()) 项。")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                CleanupCompletionEmblem(
                    symbol: receipt.wasUserAborted ? "stop.fill" : (receipt.succeededCount == receipt.expectedItemCount ? "checkmark" : "exclamationmark"),
                    tint: tint,
                    isRevealed: isRevealed,
                    reduceMotion: reduceMotion
                )
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(title)
                        .font(.title2.bold())
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .cleanupReveal(index: 0, isRevealed: isRevealed, reduceMotion: reduceMotion)

            ExecutionReceiptSummaryView(receipt: receipt)
            .cleanupReveal(index: 1, isRevealed: isRevealed, reduceMotion: reduceMotion)

            if let historySaveWarning {
                Label("本次结果已完成，但清理记录未能保存：\(historySaveWarning)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .cleanupReveal(index: 4, isRevealed: isRevealed, reduceMotion: reduceMotion)
            }

            HStack {
                Button("在 Finder 查看废纸篓", systemImage: "folder", action: openTrash)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(receipt.succeededCount == 0)
                Spacer()
                Button("重新扫描", systemImage: "arrow.clockwise", action: rescanAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .cleanupReveal(index: 6, isRevealed: isRevealed, reduceMotion: reduceMotion)
        }
        .liquidGlassSurface(tint: tint)
        .onAppear {
            isRevealed = reduceMotion
            guard !reduceMotion else { return }
            withAnimation(AppTheme.Motion.completion) {
                isRevealed = true
            }
        }
        .onDisappear {
            isRevealed = false
        }
        .accessibilityElement(children: .contain)
    }

    private func openTrash() {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".Trash", directoryHint: .isDirectory)
        NSWorkspace.shared.open(trashURL)
    }
}

private struct CleanupCompletionEmblem: View {
    let symbol: String
    let tint: Color
    let isRevealed: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.10))
            Circle()
                .trim(from: 0, to: isRevealed ? 1 : 0.02)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(tint)
                .scaleEffect(isRevealed ? 1 : 0.45)
                .opacity(isRevealed ? 1 : 0)
        }
        .frame(width: 72, height: 72)
        .shadow(color: tint.opacity(isRevealed ? 0.34 : 0), radius: 18)
        .animation(
            reduceMotion ? .linear(duration: 0.01) : AppTheme.Motion.completion,
            value: isRevealed
        )
        .accessibilityHidden(true)
    }
}

private struct ScanMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: symbol).foregroundStyle(AppTheme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.18), value: value)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.recessedSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FileCandidateRow: View {
    let file: CleanupFileCandidate

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "doc").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                if let modifiedAt = file.modifiedAt {
                    Text("修改于 \(modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            Text(SystemFormatters.bytes.string(fromByteCount: file.allocatedBytes))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RiskBadge: View {
    let risk: CleanupRisk

    var body: some View {
        Label(risk.localizedDisplayName, systemImage: risk.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(risk.tint)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(risk.tint.opacity(0.11))
            .clipShape(Capsule())
    }
}

private struct ScanStatusCard: View {
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

struct FeatureHeader: View {
    let eyebrow: String
    let title: String
    let description: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(eyebrow.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text(title).font(.largeTitle.bold())
                Text(description).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

struct SafetyBanner: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: symbol).foregroundStyle(AppTheme.healthy).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.healthy.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .stroke(AppTheme.healthy.opacity(0.3), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CleanupRevealModifier: ViewModifier {
    let index: Int
    let isRevealed: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isRevealed ? 1 : 0)
            .offset(y: isRevealed ? 0 : 7)
            .animation(
                reduceMotion
                    ? .linear(duration: 0.01)
                    : AppTheme.Motion.scanReveal.delay(Double(min(index, 5)) * 0.035),
                value: isRevealed
            )
    }
}

private extension View {
    func cleanupReveal(index: Int, isRevealed: Bool, reduceMotion: Bool) -> some View {
        modifier(CleanupRevealModifier(index: index, isRevealed: isRevealed, reduceMotion: reduceMotion))
    }
}

#Preview("可清理项目") {
    let ignoreList = IgnoreListStore(repository: InMemoryIgnoreRuleRepository(), autoload: false)
    CleanupView(ignoreList: ignoreList)
        .frame(width: 850, height: 760)
        .environmentObject(AppNavigationState())
}
