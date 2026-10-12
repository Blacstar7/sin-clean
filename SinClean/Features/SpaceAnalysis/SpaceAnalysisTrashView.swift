import AppKit
import QuickLook
import SwiftUI

// SC-3.5 手动处理面板：逐项选择、只读预览、审阅、执行与收据。
//
// 设计边界（见 work/SC-3.5-frozen-semantics.md）：
// - 与只读的分析结果区分开：分析结果页保持 SC-3.3 冻结的「无文件操作入口」契约，
//   本面板是独立的手动处理面，承载逐项选择、Quick Look、在访达中显示与移入废纸篓。
// - 默认不选；只能逐项勾选；不提供任何批量捷径或跳过审阅的入口。
// - 唯一的破坏性动作是把已选项目移入系统废纸篓，且必须经执行前安全复验。

struct SpaceAnalysisTrashView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var results: SpaceAnalysisResultsViewModel
    @EnvironmentObject private var trash: SpaceAnalysisTrashViewModel
    @State private var quickLookURL: URL?
    /// Rework：embedded＝嵌入大文件分段呈现（无独立卡壳，列表随右区页面滚动）。
    private let embedded: Bool

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    /// 面板只列可执行的大文件集合：所见即所执行（已排除忽略列表命中项）。
    private var items: [SpaceAnalysisEntry] { results.largeFiles }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            reviewHeader
            itemList
            reviewSummary
            actionRow
            if let receipt = trash.receipt {
                receiptSection(receipt)
            }
        }
        .padding(embedded ? 0 : AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            embedded ? AnyShapeStyle(.clear) : surfaceStyle,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .quickLookPreview($quickLookURL)
    }

    private var reviewHeader: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("手动处理")
                .font(.headline)
            Text(trash.phase.title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppTheme.accent.opacity(0.14), in: Capsule())
            Spacer()
            Button("清空选择") {
                trash.clearSelection()
            }
            .buttonStyle(.bordered)
            .disabled(trash.selectedCount == 0 || trash.isExecuting)
            .accessibilityLabel("清空已选项目")
            .accessibilityValue(trash.selectedCount == 0 ? "没有已选项目" : "将取消选择 \(trash.selectedCount.formatted()) 项")
            .accessibilityHint("只清空选择，不移动任何文件")
        }
    }

    // MARK: - 逐项列表

    private var itemList: some View {
        Group {
            if embedded {
                itemListContent
            } else {
                ScrollView {
                    itemListContent
                }
                .frame(minHeight: 120, idealHeight: 200, maxHeight: 300)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var itemListContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if items.isEmpty {
                Text("当前没有可处理的大文件。请先完成一次只读分析，或调整大文件阈值。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("手动处理列表为空")
            } else {
                ForEach(items) { entry in
                    itemRow(entry)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func itemRow(_ entry: SpaceAnalysisEntry) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            Toggle("", isOn: Binding(
                get: { trash.isSelected(entry) },
                set: { _ in trash.toggleSelection(entry) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!trash.isSelectable(entry) || trash.isExecuting)
            .accessibilityLabel("选择 \(entry.displayName)")
            .accessibilityValue(trash.isSelected(entry) ? "已选择" : "未选择")
            .accessibilityHint(trash.isSelectable(entry)
                ? "逐项选择后可在本区审阅并移入系统废纸篓"
                : "该项命中忽略列表，不可选择")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.callout.weight(.semibold))
                Text(entry.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("来源范围 \(entry.rootPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Text(SpaceAnalysisByteText.bytes(entry.allocatedBytes))
                .font(.callout.monospacedDigit())

            // 只读入口：预览与定位都不会移动或修改文件。
            Button {
                quickLookURL = URL(fileURLWithPath: entry.path)
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("快速查看 \(entry.displayName)")
            .accessibilityHint("只读预览，不会移动或修改文件")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("在访达中显示 \(entry.displayName)")
            .accessibilityHint("只在访达中定位，不移动文件")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 审阅摘要

    private var reviewSummary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            // 两个元素各自持有语义：能力说明不得被审阅摘要的显式值吞掉。
            Text(trash.reviewNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("手动处理审阅摘要")
                .accessibilityValue(trash.reviewNote)
                .accessibilityHint("移入废纸篓前请逐项确认")
            Text(trash.capabilityNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("手动处理能力说明")
                .accessibilityValue(trash.capabilityNote)
                .accessibilityHint("本区不提供永久删除，也不会自动移动任何文件")
        }
    }

    private var actionRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("移入废纸篓", systemImage: "trash") {
                trash.execute(entries: items)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!trash.canExecute)
            .accessibilityLabel("把已选项目移入系统废纸篓")
            .accessibilityValue(trash.selectedCount == 0
                ? "尚未选择任何项目"
                : "将移入废纸篓 \(trash.selectedCount.formatted()) 项")
            .accessibilityHint("逐项执行前复验；只移入系统废纸篓，不永久删除")

            Button("取消执行", systemImage: "stop.circle") {
                trash.cancelExecution()
            }
            .buttonStyle(.bordered)
            .disabled(!trash.isExecuting)
            .accessibilityLabel("取消正在进行的移入操作")
            .accessibilityValue(trash.isExecuting ? "执行进行中" : "当前没有进行中的执行")
            .accessibilityHint("已移入的项目无法由本应用撤销，请在访达废纸篓中恢复")
        }
    }

    // MARK: - 收据

    private func receiptSection(_ receipt: SpaceAnalysisTrashReceipt) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("执行收据")
                    .font(.headline)
                Text("已移入 \(receipt.movedCount.formatted()) 项 · 未移动 \(receipt.skippedCount.formatted()) 项 · \(SpaceAnalysisByteText.bytes(receipt.movedBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清除收据") { trash.clearReceipt() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("清除执行收据")
                    .accessibilityHint("只清除界面上的收据显示")
            }
            if receipt.cancelled {
                Text("本次执行已取消：以下为已发生的部分结果。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .accessibilityLabel("执行已取消说明")
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ForEach(receipt.items) { item in
                    receiptRow(item)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func receiptRow(_ item: SpaceAnalysisTrashReceiptItem) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: item.movedToTrash ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(item.movedToTrash ? AppTheme.healthy : AppTheme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.callout.weight(.semibold))
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            Text(item.reasonCode)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("收据项目 \(item.displayName)")
        .accessibilityValue("\(item.movedToTrash ? "已移入废纸篓" : "未移动")，原因码 \(item.reasonCode)，\(item.text)路径 \(item.path)，\(SpaceAnalysisByteText.bytes(item.bytes))")
    }

    private var surfaceStyle: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(AppTheme.obsidian)
            : AnyShapeStyle(.ultraThinMaterial)
    }
}
