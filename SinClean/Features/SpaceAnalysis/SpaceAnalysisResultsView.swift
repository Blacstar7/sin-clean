import SwiftUI

struct SpaceAnalysisResultsView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var results: SpaceAnalysisResultsViewModel

    /// Rework：右区分段呈现——概览／目录树／大文件（含手动处理）；
    /// 扫描主操作已迁往左栏 ScopeView。
    private enum Segment: String, CaseIterable, Identifiable {
        case overview
        case tree
        case largeFiles

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: String(localized: "概览")
            case .tree: String(localized: "目录树")
            case .largeFiles: String(localized: "大文件")
            }
        }
    }

    @State private var selectedSegment: Segment = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if results.outcome != nil {
                Picker("结果视图", selection: $selectedSegment) {
                    ForEach(Segment.allCases) { segment in
                        Text(segment.title).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 320, alignment: .leading)
                .accessibilityLabel("分析结果视图")
                .accessibilityValue("当前 \(selectedSegment.title)")
                .accessibilityHint("在概览、目录树与大文件之间切换；只改变展示，不重新扫描")

                switch selectedSegment {
                case .overview:
                    capacitySection
                    honestySection
                case .tree:
                    treeSection
                case .largeFiles:
                    largeFileSection
                    // SC-3.5 冻结语义不变：手动处理仍独立成面（勾选／审阅／收据齐全），
                    // 只是嵌入大文件分段呈现。
                    SpaceAnalysisTrashView(embedded: true)
                }
            } else if results.isScanning {
                Label("扫描进行中——进度与取消入口在左侧任务栏。", systemImage: "arrow.left.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("扫描进行中")
                    .accessibilityValue("进度见左侧任务栏")
            } else {
                resultEmptyState
            }
        }
        .background(.clear)
        .accessibilityElement(children: .contain)
    }

    // MARK: - 结果空态（扫描控制已迁往左栏 ScopeView.scanControl）

    private var resultEmptyState: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "square.stack.3d.up.slash")
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("尚无分析结果")
                    .font(.headline)
                Text("选择范围后开始扫描，结果只保存在当前会话中；本轮不会移动、删除或修改任何文件。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("尚无分析结果")
        .accessibilityValue("尚未开始扫描")
        .accessibilityHint("先在左侧任务栏选择范围，再点击开始扫描")
    }

    // MARK: - 容量条

    private var capacitySection: some View {
        let bar = results.capacityBar
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("容量分布")
                .font(.headline)

            if bar.segments.isEmpty {
                Text(bar.denominatorKind == .empty ? "尚未统计到容量：扫描尚未产生可比对的字节总量。" : "没有可展示的容量分段。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                capacityBarTrack(bar)
                capacityBarTextAlternative(bar)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    ForEach(bar.segments) { segment in
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Circle()
                                .fill(color(for: segment))
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(segment.displayName)
                                .font(.callout)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            Text(SpaceAnalysisByteText.bytes(segment.bytes))
                                .font(.callout.monospacedDigit())
                            Text(percentageText(segment.fraction))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("容量分段 \(segment.displayName)")
                        .accessibilityValue("\(SpaceAnalysisByteText.bytes(segment.bytes))，占已统计总量 \(percentageText(segment.fraction))")
                    }
                }
            }

            InformationDisclosure(
                title: String(localized: "容量计算说明"),
                summary: String(localized: "查看统计口径、精度、硬链接和云端占位规则"),
                symbol: "ruler",
                tint: AppTheme.accent
            ) {
                Text("分母语义：\(bar.denominatorKind.localizedTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(bar.percentageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("容量精度：\(results.precisionNote)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("容量精度说明")
                    .accessibilityValue(results.precisionNote)

                if let hardLinkNote = results.deduplication.hardLinkNote {
                    Text(hardLinkNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("硬链接去重说明")
                        .accessibilityValue(hardLinkNote)
                }

                if let datalessNote = results.deduplication.datalessNote {
                    Text(datalessNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("云端占位说明")
                        .accessibilityValue(datalessNote)
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func capacityBarTrack(_ bar: SpaceAnalysisCapacityBar) -> some View {
        // 使用真实布局容器承载分段，使容量条本身成为一个可访问元素并携带文本替代。
        // 宽度随容器自适应；曾为固定 640pt，窄窗口下撑破横向边界把两栏顶出屏幕（b26 mini 实测）。
        GeometryReader { proxy in
            let usable = proxy.size.width - CGFloat(max(0, bar.segments.count - 1))
            return HStack(spacing: 1) {
                ForEach(bar.segments) { segment in
                    Rectangle()
                        .fill(color(for: segment))
                        .frame(width: max(2, usable * segment.fraction))
                }
            }
            .frame(height: 14, alignment: .leading)
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }

    // 容量条的文本等价物：可见、可被 VoiceOver 直接读取，避免只靠颜色与长度表达。
    private func capacityBarTextAlternative(_ bar: SpaceAnalysisCapacityBar) -> some View {
        let summary = bar.segments
            .map { "\($0.displayName) \(percentageText($0.fraction))" }
            .joined(separator: String(localized: "，"))
        return Text("占比：\(summary)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("容量条")
            .accessibilityValue(summary)
    }

    private func color(for segment: SpaceAnalysisCapacitySegment) -> Color {
        if segment.isAggregate { return AppTheme.warning.opacity(0.75) }
        let palette: [Color] = [AppTheme.accent, AppTheme.violet, AppTheme.healthy, AppTheme.warning]
        let index = abs(segment.path.hashValue) % palette.count
        return palette[index]
    }

    private func percentageText(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0%" }
        let value = fraction * 100
        return value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
    }

    // MARK: - 目录树

    private var treeSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("目录树")
                    .font(.headline)
                Text("共 \(results.treeRows.count.formatted()) 行可见")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部展开") { results.expandAll() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("展开全部目录节点")
                    .accessibilityHint("只改变展示，不重新扫描")
                Button("全部折叠") { results.collapseAll() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("折叠全部目录节点")
                    .accessibilityHint("只改变展示，不重新扫描")
            }

            VStack(spacing: AppTheme.Spacing.xs) {
                ForEach(results.treeRows) { node in
                    treeRow(node)
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func treeRow(_ node: SpaceAnalysisTreeNode) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Spacer()
                .frame(width: CGFloat(node.depth) * 14)
            if node.childDirectoryCount > 0 {
                Button {
                    results.toggleExpansion(node.path)
                } label: {
                    Image(systemName: results.expandedPaths.contains(node.path) ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(results.expandedPaths.contains(node.path) ? "折叠 \(node.displayName)" : "展开 \(node.displayName)")
                .accessibilityValue(results.expandedPaths.contains(node.path) ? "已展开" : "已折叠")
                .accessibilityHint("只改变展示，不重新扫描")
            } else {
                Image(systemName: "circle.dashed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Image(systemName: node.isReadable ? "folder" : "folder.badge.questionmark")
                .foregroundStyle(node.isReadable ? AppTheme.accent : AppTheme.warning)
                .accessibilityHidden(true)
            Text(node.displayName)
                .font(.callout)
                .lineLimit(1)
            if !node.isReadable {
                Text("不可读")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.warning.opacity(0.16), in: Capsule())
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            Text("\(node.fileCount.formatted()) 项")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(SpaceAnalysisByteText.bytes(node.totalBytes))
                .font(.callout.monospacedDigit())
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("目录 \(node.displayName)")
        .accessibilityValue("\(node.isReadable ? String(localized: "可读") : String(localized: "不可读"))，累计 \(SpaceAnalysisByteText.bytes(node.totalBytes))，直属文件 \(node.fileCount.formatted()) 项，子目录 \(node.childDirectoryCount.formatted()) 个")
    }

    // MARK: - 大文件列表

    private var largeFileSection: some View {
        let selection = results.displaySelection
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("大文件")
                    .font(.headline)
                Text("阈值 \(results.largeFileRule.thresholdText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: AppTheme.Spacing.md) {
                Picker("排序", selection: $results.sortDescriptor.key) {
                    ForEach(SpaceAnalysisSortKey.allCases) { key in
                        Text(key.localizedTitle).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .accessibilityLabel("大文件排序键")
                .accessibilityHint("按大小、修改时间或名称排序")

                Picker("方向", selection: $results.sortDescriptor.ascending) {
                    Text("降序").tag(false)
                    Text("升序").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
                .accessibilityLabel("排序方向")

                Picker("类型", selection: $results.typeGroup) {
                    ForEach(SpaceAnalysisTypeGroup.allCases) { group in
                        Text(group.localizedTitle).tag(group)
                    }
                }
                .frame(maxWidth: 200)
                .accessibilityLabel("文件类型筛选")
                .accessibilityValue(results.typeGroup.localizedTitle)

                Picker("阈值", selection: $results.largeFileRule) {
                    ForEach(SpaceAnalysisLargeFileRule.options, id: \.self) { value in
                        Text(SpaceAnalysisByteText.bytes(value)).tag(SpaceAnalysisLargeFileRule(minimumBytes: value))
                    }
                }
                .frame(maxWidth: 160)
                .accessibilityLabel("大文件阈值")
                .accessibilityValue(results.largeFileRule.thresholdText)
            }

            Text("当前筛选下：\(selection.itemCount.formatted()) 项 · 合计 \(SpaceAnalysisByteText.bytes(selection.totalBytes))\(selection.isFiltered ? "（已按类型筛选）" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)

            if selection.entries.isEmpty {
                Text("当前条件下没有大文件。可以降低阈值或放宽类型筛选。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(selection.entries) { entry in
                        largeFileRow(entry)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func largeFileRow(_ entry: SpaceAnalysisEntry) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            Image(systemName: "doc")
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(entry.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if entry.isDatalessPlaceholder {
                        Text("云端占位未下载")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.warning.opacity(0.18), in: Capsule())
                    }
                    if entry.linkGroupID != nil {
                        Text("硬链接共享")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.accent.opacity(0.16), in: Capsule())
                    }
                }
                Text(entry.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            VStack(alignment: .trailing, spacing: 2) {
                Text(SpaceAnalysisByteText.bytes(entry.allocatedBytes))
                    .font(.callout.monospacedDigit())
                Text(entry.modifiedAt.map { Self.dateFormatter.string(from: $0) } ?? String(localized: "修改时间不可得"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("大文件 \(entry.displayName)")
        .accessibilityValue(Self.largeFileAccessibilityValue(entry))
    }

    // SC-3.4：占位与硬链接状态必须进入可访问性值，不得只靠徽章颜色表达。
    private static func largeFileAccessibilityValue(_ entry: SpaceAnalysisEntry) -> String {
        var parts: [String] = [SpaceAnalysisByteText.bytes(entry.allocatedBytes)]
        if entry.isDatalessPlaceholder {
            parts.append(String(localized: "云端占位未下载；逻辑大小 \(SpaceAnalysisByteText.bytes(entry.logicalBytes))，下载后会占用更多空间"))
        }
        if entry.linkGroupID != nil {
            parts.append(String(localized: "硬链接共享：与另一路径共享同一物理文件，容量只计一次"))
        }
        parts.append(String(localized: "路径 \(entry.path)"))
        parts.append(entry.modifiedAt.map { String(localized: "修改时间 \(dateFormatter.string(from: $0))") } ?? String(localized: "修改时间不可得"))
        return parts.joined(separator: String(localized: "，"))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - 诚实说明

    private var honestySection: some View {
        InformationDisclosure(
            title: String(localized: "能力与边界"),
            summary: String(localized: "只读分析，不移动、不删除、不修改文件"),
            symbol: "info.circle",
            tint: AppTheme.accent
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(results.capabilityNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(results.exclusionNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel("空间分析能力与边界")
        .accessibilityValue("只读分析；不移动、不删除、不修改文件。\(results.exclusionNote)")
        .accessibilityHint("本轮只做只读分析，不提供任何文件处理动作")
    }

    private var surfaceStyle: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(AppTheme.obsidian)
            : AnyShapeStyle(.ultraThinMaterial)
    }
}
