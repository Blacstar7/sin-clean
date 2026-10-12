import AppKit
import SwiftUI

struct WorkspaceTrashOpener: TrashOpening {
    @MainActor
    func openTrash() -> Bool {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".Trash", directoryHint: .isDirectory)
        return NSWorkspace.shared.open(trashURL)
    }
}

@MainActor
final class OperationHistoryViewModel: ObservableObject {
    enum FeedbackKind: Equatable { case success, failure }
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var entries: [OperationHistoryRecord] = []
    @Published private(set) var notices: [String] = []
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var feedback: String?
    @Published private(set) var feedbackKind: FeedbackKind = .success
    @Published var selectedID: UUID?

    private let store: any OperationHistoryReading
    private let trashOpener: any TrashOpening

    init(store: any OperationHistoryReading, trashOpener: any TrashOpening) {
        self.store = store
        self.trashOpener = trashOpener
    }

    var selectedEntry: OperationHistoryRecord? {
        entries.first { $0.id == selectedID }
    }

    func load() {
        guard loadState != .loading else { return }
        loadState = .loading
        feedback = nil
        Task { [weak self, store] in
            do {
                let outcome = try await store.load()
                guard !Task.isCancelled else { return }
                self?.entries = outcome.entries
                self?.notices = outcome.notices
                self?.selectedID = outcome.entries.first?.id
                self?.loadState = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self?.entries = []
                self?.notices = []
                self?.selectedID = nil
                self?.loadState = .failed(error.localizedDescription)
            }
        }
    }

    func clearConfirmed() {
        feedback = nil
        Task { [weak self, store] in
            do {
                try await store.clear()
                let outcome = try await store.load()
                guard !Task.isCancelled else { return }
                self?.entries = outcome.entries
                self?.notices = outcome.notices
                self?.selectedID = outcome.entries.first?.id
                self?.loadState = .loaded
                self?.feedbackKind = .success
                self?.feedback = String(localized: "操作记录已清空。迁移标记已保留，旧版文件不会在下次启动时重新导入。")
            } catch {
                guard !Task.isCancelled else { return }
                self?.feedbackKind = .failure
                self?.feedback = String(localized: "操作记录未能清空：\(error.localizedDescription)")
            }
        }
    }

    func openTrash() {
        let opened = trashOpener.openTrash()
        feedbackKind = opened ? .success : .failure
        feedback = opened
            ? String(localized: "已请求 Finder 打开废纸篓。")
            : String(localized: "未能打开废纸篓，请在 Finder 中手动打开。")
    }
}

struct OperationHistoryView: View {
    @StateObject private var viewModel: OperationHistoryViewModel
    @State private var showsClearConfirmation = false

    init(store: any OperationHistoryReading, trashOpener: any TrashOpening = WorkspaceTrashOpener()) {
        _viewModel = StateObject(wrappedValue: OperationHistoryViewModel(
            store: store,
            trashOpener: trashOpener
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header

            if let feedback = viewModel.feedback {
                Label(feedback, systemImage: viewModel.feedbackKind == .failure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(viewModel.feedbackKind == .failure ? AppTheme.warning : AppTheme.healthy)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.clear)
        .confirmationDialog(
            viewModel.entries.isEmpty ? String(localized: "清空无法读取的操作记录？") : String(localized: "清空全部操作记录？"),
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认清空", role: .destructive) {
                viewModel.clearConfirmed()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作只删除 Sin Clean 本机保存的历史摘要与只读详情，不会移动或删除废纸篓中的文件。取消或按 Escape 不会改变任何记录。")
        }
        .task {
            if viewModel.loadState == .idle { viewModel.load() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            FeatureHeader(
                eyebrow: String(localized: "本机记录 · 只读审阅"),
                title: String(localized: "操作记录"),
                description: String(localized: "统一查看磁盘清理与应用卸载的完成记录。历史只用于审阅，不能据此执行任何操作或恢复旧选择。"),
                symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                tint: AppTheme.accent
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: AppTheme.Spacing.sm) {
                Button("打开废纸篓", systemImage: "trash", action: viewModel.openTrash)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint("在 Finder 中打开废纸篓；不会修改任何操作记录")
                Button("清空历史", systemImage: "trash.slash") {
                    showsClearConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint("打开确认对话框；确认前不会删除记录")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            ProgressView("正在读取本机操作记录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("正在读取本机操作记录")
        case .failed(let message):
            OperationHistoryLoadFailure(
                message: message,
                loadAction: viewModel.load,
                clearAction: { showsClearConfirmation = true }
            )
        case .loaded:
            if viewModel.entries.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    migrationNotices
                    ContentUnavailableView {
                        Label("暂无操作记录", systemImage: "clock.badge.questionmark")
                    } description: {
                        Text("完成磁盘清理或应用卸载后，只读记录会保存在这台 Mac 上。")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                historyBrowser
            }
        }
    }

    private var historyBrowser: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                migrationNotices

                List(selection: $viewModel.selectedID) {
                    ForEach(viewModel.entries) { entry in
                        OperationHistoryRow(entry: entry)
                            .tag(entry.id)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel("操作记录列表，共 \(viewModel.entries.count.formatted()) 条")
            }
            .frame(minWidth: 290, idealWidth: 330, maxWidth: 370)

            Divider()

            Group {
                if let entry = viewModel.selectedEntry {
                    OperationHistoryDetail(entry: entry)
                        .id(entry.id)
                } else {
                    ContentUnavailableView("选择一条记录", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }

    private var migrationNotices: some View {
        ForEach(viewModel.notices, id: \.self) { notice in
            Label(
                notice,
                systemImage: Self.isCorruptionNotice(notice)
                    ? "exclamationmark.triangle.fill"
                    : "arrow.triangle.2.circlepath"
            )
            .font(.caption)
            .foregroundStyle(Self.isCorruptionNotice(notice) ? AppTheme.warning : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .accessibilityElement(children: .combine)
        }
    }

    private static func isCorruptionNotice(_ notice: String) -> Bool {
        ["损坏", "損壞", "corrupt"].contains { notice.localizedCaseInsensitiveContains($0) }
    }
}

private struct OperationHistoryLoadFailure: View {
    let message: String
    let loadAction: () -> Void
    let clearAction: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(AppTheme.danger)
                .accessibilityHidden(true)
            Text("操作记录加载失败").font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text("为避免把损坏或不兼容的数据伪装成空记录，本页不会显示“暂无记录”。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("重新读取", systemImage: "arrow.clockwise", action: loadAction)
                    .buttonStyle(.borderedProminent)
                Button("清空本机记录…", systemImage: "trash.slash", action: clearAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct OperationHistoryRow: View {
    let entry: OperationHistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Label(entry.domainTitle, systemImage: entry.domainSymbol)
                    .font(.body.weight(.semibold))
                Spacer()
                Image(systemName: entry.detailAvailability == .complete ? "doc.text.magnifyingglass" : "exclamationmark.bubble")
                    .foregroundStyle(entry.detailAvailability == .complete ? AppTheme.accent : AppTheme.warning)
                    .accessibilityHidden(true)
            }
            Text(entry.summary.title)
                .font(.callout)
                .lineLimit(2)
            Text(entry.completedAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(entry.statusLine)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                "实际成功 \(ExecutionReceiptCapacityFormatter.string(fromByteCount: entry.summary.actualSucceededBytes))",
                systemImage: "trash.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(AppTheme.healthy)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.domainTitle)，\(entry.summary.title)，完成于 \(entry.completedAt.formatted(date: .abbreviated, time: .standard))，\(entry.statusLine)，实际成功 \(ExecutionReceiptCapacityFormatter.string(fromByteCount: entry.summary.actualSucceededBytes))")
        .accessibilityHint("选择后显示只读详情")
    }
}

private struct OperationHistoryDetail: View {
    let entry: OperationHistoryRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(entry.domainTitle).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent)
                        Text(entry.summary.title).font(.title2.bold())
                        Text(entry.completedAt.formatted(date: .complete, time: .standard))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("只读", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.healthy)
                }

                Label(
                    "此页只保存审阅快照，不包含执行入口，也不会恢复过去的选择。",
                    systemImage: "hand.raised.fill"
                )
                .font(.callout.weight(.medium))
                .padding(AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.healthy.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))

                if entry.detailAvailability == .complete,
                   let plan = entry.plan,
                   let receipt = entry.receipt?.receiptForReadOnlyDisplay() {
                    OperationHistoryPlanSummary(plan: plan)
                    ExecutionReceiptSummaryView(receipt: receipt)
                } else {
                    OperationHistoryUnavailableDetail(entry: entry)
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct OperationHistoryUnavailableDetail: View {
    let entry: OperationHistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Label(
                entry.detailAvailability == .legacySummaryOnly ? String(localized: "旧版摘要，详情不可用") : String(localized: "可信详情不可用"),
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.title3.bold())
            .foregroundStyle(AppTheme.warning)
            Text(entry.detailMessage ?? String(localized: "没有可验证的冻结计划与执行收据快照。"))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(entry.statusLine)
                .font(.callout.monospacedDigit())
            Text("实际成功处理：\(ExecutionReceiptCapacityFormatter.string(fromByteCount: entry.summary.actualSucceededBytes))")
                .font(.callout.monospacedDigit())
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct OperationHistoryPlanSummary: View {
    let plan: OperationHistoryPlanSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("冻结计划摘要").font(.headline)
            HistoryValueRow(title: String(localized: "计划 ID"), value: plan.id.uuidString, monospaced: true)
            HistoryValueRow(title: String(localized: "冻结状态"), value: plan.state)
            HistoryValueRow(title: String(localized: "创建时间"), value: plan.createdAt.formatted(date: .abbreviated, time: .standard))
            HistoryValueRow(title: String(localized: "冻结时间"), value: plan.frozenAt.formatted(date: .abbreviated, time: .standard))
            HistoryValueRow(title: String(localized: "预计容量"), value: ExecutionReceiptCapacityFormatter.string(fromByteCount: plan.estimatedBytes))
            HistoryValueRow(title: String(localized: "计划项目"), value: String(localized: "\(plan.items.count.formatted()) 项"))
            HistoryValueRow(title: String(localized: "覆盖记录"), value: String(localized: "\(plan.coverageRecords.count.formatted()) 项"))

            if !plan.warnings.isEmpty {
                DisclosureGroup("计划警告（\(plan.warnings.count.formatted())）") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ForEach(plan.warnings, id: \.self) { warning in
                            Text(warning).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    .padding(.top, AppTheme.Spacing.sm)
                }
            }

            if !plan.sourceScanContexts.isEmpty {
                DisclosureGroup("扫描上下文（\(plan.sourceScanContexts.count.formatted())）") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ForEach(plan.sourceScanContexts, id: \.id) { context in
                            Text("\(context.id.uuidString) · \(context.startedAt.formatted(date: .abbreviated, time: .standard)) · \(context.ruleVersion)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, AppTheme.Spacing.sm)
                }
            }

            if !plan.coverageRecords.isEmpty {
                DisclosureGroup("扫描覆盖快照") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ForEach(Array(plan.coverageRecords.enumerated()), id: \.offset) { _, coverage in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(coverage.scanner) · \(coverage.phase) · \(coverage.status)")
                                    .font(.caption.weight(.semibold))
                                Text(coverage.targetPath ?? coverage.rootPath)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Text("问题 \(coverage.issueCount) · 权限 \(coverage.accessIssueCount) · 保留样本 \(coverage.retainedIssueSampleCount) · 省略 \(coverage.omittedIssueCount)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(AppTheme.Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.recessedSurface)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                        }
                    }
                    .padding(.top, AppTheme.Spacing.sm)
                }
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("计划项目").font(.headline)
                ForEach(plan.items.sorted { $0.order < $1.order }) { item in
                    OperationHistoryPlanItemRow(item: item)
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct OperationHistoryPlanItemRow: View {
    let item: OperationHistoryPlanItemSnapshot

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HistoryValueRow(title: String(localized: "项目 ID"), value: item.id, monospaced: true)
                HistoryValueRow(title: String(localized: "计划状态"), value: item.state)
                HistoryValueRow(title: String(localized: "扫描根目录"), value: item.identity.scanRootPath, monospaced: true)
                HistoryValueRow(title: String(localized: "项目类型"), value: item.identity.itemType)
                HistoryValueRow(title: String(localized: "设备 / inode"), value: "\(item.identity.deviceID) / \(item.identity.inode)", monospaced: true)
                HistoryValueRow(title: String(localized: "分配 / 逻辑容量"), value: "\(item.identity.allocatedBytes) / \(item.identity.logicalBytes) bytes", monospaced: true)
                HistoryValueRow(title: String(localized: "修改时间戳"), value: "\(item.identity.modifiedSeconds).\(item.identity.modifiedNanoseconds)", monospaced: true)
                HistoryValueRow(title: "Bundle ID", value: item.identity.bundleIdentifier ?? "—", monospaced: true)
                HistoryValueRow(title: String(localized: "安全边界"), value: item.safetyBoundary, monospaced: true)
                HistoryValueRow(title: String(localized: "规则代码"), value: item.evidence.reasonCode, monospaced: true)
                HistoryValueRow(title: String(localized: "规则版本"), value: item.evidence.ruleVersion, monospaced: true)
                HistoryValueRow(title: String(localized: "范围 ID"), value: item.evidence.scopeID, monospaced: true)
                HistoryValueRow(title: String(localized: "判定依据"), value: item.evidence.reasonText)
                HistoryValueRow(title: String(localized: "影响"), value: item.evidence.impactText)
                HistoryValueRow(title: String(localized: "恢复语义"), value: item.evidence.recoverability)
                if let parent = item.parentApplication {
                    HistoryValueRow(title: String(localized: "所属应用"), value: "\(parent.name) · \(parent.bundleIdentifier) · \(parent.path)")
                }
            }
            .padding(.top, AppTheme.Spacing.sm)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("第 \((item.order + 1).formatted()) 项 · \(item.category.title)")
                    .font(.callout.weight(.semibold))
                Text(item.identity.originalPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text("预计 \(ExecutionReceiptCapacityFormatter.string(fromByteCount: item.estimatedBytes))")
                    .font(.caption2.monospacedDigit())
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.recessedSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct HistoryValueRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension OperationHistoryRecord {
    var domainTitle: String {
        operationDomain == .uninstall ? String(localized: "应用卸载") : String(localized: "磁盘清理")
    }

    var domainSymbol: String {
        operationDomain == .uninstall ? "shippingbox" : "internaldrive"
    }

    var statusLine: String {
        let counts = summary.statusCounts
        return String(localized: "成功 \(display(counts.succeeded)) · 失败 \(display(counts.failed)) · 跳过 \(display(counts.skipped)) · 中止 \(display(counts.aborted)) · 未执行 \(display(counts.notExecuted))")
    }

    private func display(_ count: Int?) -> String {
        count?.formatted() ?? String(localized: "未知")
    }
}

actor InMemoryOperationHistoryStore: OperationHistoryReading {
    private var entries: [OperationHistoryRecord]
    private var notices: [String]
    private var loadError: String?
    private let clearError: String?

    init(
        entries: [OperationHistoryRecord],
        notices: [String] = [],
        loadError: String? = nil,
        clearError: String? = nil
    ) {
        self.entries = entries
        self.notices = notices
        self.loadError = loadError
        self.clearError = clearError
    }

    func load() async throws -> OperationHistoryLoadOutcome {
        if let loadError { throw OperationHistoryStoreError.unifiedFileCorrupt(loadError) }
        return OperationHistoryLoadOutcome(entries: entries, notices: notices)
    }

    func clear() async throws {
        if let clearError {
            throw OperationHistoryStoreError.persistenceFailed(clearError)
        }
        entries = []
        notices = [String(localized: "操作记录已清空；旧版迁移标记已保留，旧版文件不会再次导入。")]
        loadError = nil
    }
}

struct DisabledTrashOpener: TrashOpening {
    @MainActor func openTrash() -> Bool { false }
}
