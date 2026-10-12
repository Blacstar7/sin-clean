import SwiftUI

struct IgnoreListStatusBanner: View {
    let loadState: IgnoreListLoadState
    let ignoredCount: Int
    let manageAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusTint)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppTheme.Spacing.md)
            Button("管理忽略列表", systemImage: "list.bullet.rectangle", action: manageAction)
                .buttonStyle(.bordered)
                .accessibilityLabel("打开设置中的忽略列表")
        }
        .padding(AppTheme.Spacing.md)
        .background(statusTint.opacity(0.09), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        switch loadState {
        case .loading: String(localized: "正在加载忽略列表")
        case .ready: String(localized: "本次展示已精确忽略 \(ignoredCount.formatted()) 项")
        case .failed: String(localized: "忽略列表不可用，选择与执行已暂停")
        }
    }

    private var statusMessage: String {
        switch loadState {
        case .loading:
            String(localized: "加载完成前不会把任何项目加入执行选择。原始扫描报告、Coverage 与权限问题保持不变。")
        case .ready:
            String(localized: "忽略只作用于扫描完成后的展示和操作层；上方原始候选统计与扫描覆盖没有被改写。")
        case .failed(let message):
            message
        }
    }

    private var statusSymbol: String {
        switch loadState {
        case .loading: "hourglass"
        case .ready: "eye.slash.fill"
        case .failed: "exclamationmark.shield.fill"
        }
    }

    private var statusTint: Color {
        switch loadState {
        case .loading: AppTheme.warning
        case .ready: AppTheme.accent
        case .failed: AppTheme.danger
        }
    }
}

struct IgnoreListSettingsSection: View {
    @ObservedObject var ignoreList: IgnoreListStore
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("忽略列表")
                        .font(.title3.bold())
                    Text("规则仅做精确匹配；恢复默认设置不会清除此列表。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !ignoreList.rules.isEmpty {
                    Button("清空全部", systemImage: "trash", role: .destructive) {
                        showsClearConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.danger)
                    .accessibilityLabel("清空全部忽略规则")
                    .accessibilityHint("需要再次确认；不会清理、卸载或移动任何文件")
                }
            }

            Divider()

            switch ignoreList.loadState {
            case .loading:
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在从 Application Support 加载忽略规则…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .failed(let message):
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Label("忽略列表未能加载", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(AppTheme.danger)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("原文件没有被覆盖。修复或升级前，清理和卸载执行保持暂停。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                    Button("重新加载", systemImage: "arrow.clockwise") {
                        Task { await ignoreList.reload() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("重新加载忽略列表")
                }
            case .ready:
                if ignoreList.rules.isEmpty {
                    ContentUnavailableView(
                        "没有忽略规则",
                        systemImage: "eye.slash",
                        description: Text("可在候选证据详情或应用详情中选择明确的忽略范围。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ForEach(IgnoreRuleGroup.allCases, id: \.self) { group in
                        let rules = ignoreList.rules.filter { $0.kind.group == group }
                        if !rules.isEmpty {
                            IgnoreRuleGroupView(group: group, rules: rules, ignoreList: ignoreList)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface()
        .confirmationDialog(
            "确认清空全部忽略规则？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空全部忽略规则", role: .destructive) {
                Task { try? await ignoreList.clearAll() }
            }
            Button("取消", role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("将撤销 \(ignoreList.rules.count.formatted()) 条规则。项目可在当前或下次扫描结果中重新显示，但保持默认未勾选。此操作不会触发扫描、清理、卸载或废纸篓移动。")
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
}

private struct IgnoreRuleGroupView: View {
    let group: IgnoreRuleGroup
    let rules: [IgnoreRule]
    @ObservedObject var ignoreList: IgnoreListStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text(group.title)
                    .font(.headline)
                Spacer()
                Text(rules.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(rules) { rule in
                IgnoreRuleRow(rule: rule) {
                    Task { try? await ignoreList.remove(id: rule.id) }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct IgnoreRuleRow: View {
    let rule: IgnoreRule
    let removeAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: rule.kind.group.symbol)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(rule.displayName)
                        .font(.body.weight(.semibold))
                    Text(rule.kind.typeTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                Text(rule.kind.exactMatchDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("创建于 \(rule.createdAt.formatted(date: .abbreviated, time: .shortened)) · schema \(rule.schemaVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button("撤销", systemImage: "arrow.uturn.backward", action: removeAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("撤销忽略规则：\(rule.displayName)，\(rule.kind.typeTitle)")
                .accessibilityHint("撤销后匹配项目重新显示，但不会自动勾选或执行")
        }
        .padding(.vertical, AppTheme.Spacing.xs)
        .accessibilityElement(children: .contain)
    }
}

private extension IgnoreRuleGroup {
    var symbol: String {
        switch self {
        case .candidate: "doc.badge.ellipsis"
        case .fixedPath: "folder.badge.minus"
        case .application: "app.badge"
        }
    }
}
