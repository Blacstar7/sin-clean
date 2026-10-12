import SwiftUI

struct SpaceAnalysisScopeView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var viewModel: SpaceAnalysisScopeViewModel
    /// Rework：扫描主操作自结果区迁入本栏（左控右览）。
    @EnvironmentObject private var results: SpaceAnalysisResultsViewModel

    var body: some View {
        // Rework：左栏任务卡——范围、主操作与扫描状态集中一栏，外层不包滚动容器
        // （OBS-003 断根：任何窗口高度下「开始扫描」都在场、不被挤压滚走）。
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AppTheme.violet)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("空间分析")
                        .font(.title3.bold())
                    Text("只读分析 · 范围可控；先选范围，再开始扫描。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            scopePicker
            validationFeedback
            selectedScopeList
            scanControl
            boundaryExplanation
        }
        .background(.clear)
        .accessibilityElement(children: .contain)
    }

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("选择范围")
                    .font(.headline)
                Text("选择常用范围，或添加其他目录；Sin Clean 不会自动代选。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: AppTheme.Spacing.sm)],
                spacing: AppTheme.Spacing.sm
            ) {
                ForEach(viewModel.commonScopeCandidates, id: \.self) { candidate in
                    let isSelected = viewModel.selectedScopes.contains { $0.path == candidate.path }
                    Button(candidate.displayName) {
                        viewModel.addCommonScope(candidate)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("添加常用范围：\(candidate.displayName)")
                    .accessibilityValue(isSelected ? "已在范围中" : "尚未选择")
                    .accessibilityHint("校验后加入空间分析范围；不会开始扫描")
                }
            }

            Button("选择其他目录", systemImage: "folder.badge.plus") {
                viewModel.chooseOtherDirectories()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("选择其他目录")
            .accessibilityValue("当前已选择 \(viewModel.selectedScopes.count.formatted()) 个范围")
            .accessibilityHint("打开原生面板，可选择一个或多个目录；取消不会改变现有选择")
        }
        .padding(AppTheme.Spacing.lg)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var validationFeedback: some View {
        if let rejection = viewModel.lastRejection {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.warning)
                    .accessibilityHidden(true)
                Text(rejection.message)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .stroke(AppTheme.warning.opacity(0.45), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("范围校验失败：\(rejection.message)")
            .accessibilityValue("未加入")
            .accessibilityHint("请按提示调整所选目录")
            .id(viewModel.feedbackRevision)
        }
    }

    private var selectedScopeList: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("已选择，将纳入后续空间分析")
                        .font(.headline)
                    Text("当前会话共 \(viewModel.selectedScopes.count.formatted()) 个范围")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("清空全部") {
                    viewModel.clearScopes()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.selectedScopes.isEmpty)
                .accessibilityLabel("清空全部空间分析范围")
                .accessibilityValue(viewModel.selectedScopes.isEmpty ? "没有可清空的范围" : "将移除 \(viewModel.selectedScopes.count.formatted()) 个范围")
                .accessibilityHint("只清空当前会话中的范围配置，不会访问或删除目录内容")
            }

            if viewModel.selectedScopes.isEmpty {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "folder")
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("尚未选择任何范围")
                            .font(.headline)
                        Text("空间分析保持为空，也不会自动选择个人文件夹或打开目录面板。")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("空间分析范围为空")
                .accessibilityValue("尚未选择任何范围")
                .accessibilityHint("使用上方按钮主动添加目录")
            } else {
                // Rework：列表自身限高滚动——范围再多也不把左栏主操作挤出屏幕。
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(viewModel.selectedScopes) { scope in
                            scopeRow(scope)
                        }
                    }
                }
                .frame(maxHeight: 176)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
    }

    private func scopeRow(_ scope: SpaceAnalysisScope) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(scope.displayName)
                        .font(.body.weight(.semibold))
                    Text(scope.source.localizedTitle)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppTheme.accent.opacity(0.13), in: Capsule())
                }
                Text(scope.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            Button("移除", systemImage: "minus.circle") {
                viewModel.removeScope(id: scope.id)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("移除空间分析范围：\(scope.displayName)")
            .accessibilityValue("路径 \(scope.path)，来源 \(scope.source.localizedTitle)")
            .accessibilityHint("只从当前会话的范围配置中移除，不会访问或删除目录内容")
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    // MARK: - 扫描控制（Rework：自结果区迁入左栏；回车快捷键照旧）

    private var scanControl: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Button {
                results.startScan(scopes: viewModel.selectedScopes)
            } label: {
                Label("开始扫描", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedScopes.isEmpty || results.isScanning)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityLabel("开始扫描空间分析范围")
            .accessibilityValue(viewModel.selectedScopes.isEmpty
                ? "尚未选择任何范围"
                : "将只读扫描 \(viewModel.selectedScopes.count.formatted()) 个范围")
            .accessibilityHint("只读取目录与文件元数据；不移动、不删除、不修改任何文件")

            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    results.cancelScan()
                } label: {
                    Label("取消扫描", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!results.isScanning)
                .accessibilityLabel("取消空间分析扫描")
                .accessibilityValue(results.isScanning ? "扫描进行中" : "当前没有进行中的扫描")
                .accessibilityHint("取消后保留已完成的部分结果，不访问或修改目录内容")

                Button {
                    results.clearResult()
                } label: {
                    Label("清除结果", systemImage: "trash.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(results.outcome == nil && !results.isScanning)
                .accessibilityLabel("清除空间分析结果")
                .accessibilityValue(results.outcome == nil ? "没有可清除的结果" : "只清除当前会话中的结果数据")
                .accessibilityHint("只清空内存中的分析结果，不会访问或删除目录内容")
            }

            if results.isScanning {
                scanningIndicator
            }

            Text("将扫描：\(viewModel.selectedScopes.isEmpty ? String(localized: "尚未选择范围") : viewModel.selectedScopes.map(\.displayName).joined(separator: String(localized: "、")))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.lg)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var scanningIndicator: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ProgressView()
                .progressViewStyle(.linear)
            Text(progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("空间分析扫描进行中")
        .accessibilityValue(progressText)
        .accessibilityHint("可随时取消；取消后保留已完成的部分结果")
    }

    private var progressText: String {
        guard let progress = results.progress else { return String(localized: "正在准备扫描") }
        return String(localized: "当前范围 \(progress.currentRoot) · 已完成 \(progress.finishedRootCount.formatted())/\(progress.totalRootCount.formatted()) · 已检查 \(progress.inspectedEntryCount.formatted()) 项 · 已统计 \(SpaceAnalysisByteText.bytes(progress.scannedBytes))")
    }

    private var boundaryExplanation: some View {
        InformationDisclosure(
            title: String(localized: "范围边界"),
            summary: String(localized: "只分析明确选择的目录；系统盘、卷根和符号链接不纳入"),
            symbol: "scope",
            tint: AppTheme.healthy
        ) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                boundaryColumn(
                    title: String(localized: "将扫描"),
                    symbol: "checkmark.shield.fill",
                    tint: AppTheme.healthy,
                    lines: [
                        String(localized: "仅限用户明确选择的目录。"),
                        String(localized: "后续任务会在选定目录内递归；本轮不会开始扫描。"),
                        String(localized: "不可读目录未来不会被静默计为零。")
                    ]
                )
                boundaryColumn(
                    title: String(localized: "不会扫描"),
                    symbol: "nosign",
                    tint: AppTheme.warning,
                    lines: [
                        String(localized: "未选择的目录。"),
                        String(localized: "系统盘与任何卷根。"),
                        String(localized: "通过符号链接到达的位置。"),
                        String(localized: "当前任务不会读取子目录、统计容量或处理文件。")
                    ]
                )
            }
        }
    }

    private func boundaryColumn(
        title: String,
        symbol: String,
        tint: Color,
        lines: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                    Text("•")
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(lines.joined(separator: " "))
        .accessibilityHint("空间分析范围边界说明")
    }

    private var surfaceStyle: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(AppTheme.obsidian)
            : AnyShapeStyle(.ultraThinMaterial)
    }
}
