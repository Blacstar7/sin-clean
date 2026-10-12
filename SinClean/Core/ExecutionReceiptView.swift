import SwiftUI

struct ExecutionReceiptSummaryView: View {
    let receipt: ExecutionReceipt

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: AppTheme.Spacing.sm)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            capacitySummary
            statusSummary
            receiptMetadata
            safetyNotice
            itemList
        }
        .accessibilityElement(children: .contain)
    }

    private var capacitySummary: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ReceiptMetric(
                title: String(localized: "计划预计容量"),
                value: ExecutionReceiptCapacityFormatter.string(fromByteCount: receipt.expectedBytes),
                symbol: "shippingbox"
            )
            ReceiptMetric(
                title: String(localized: "实际成功处理"),
                value: ExecutionReceiptCapacityFormatter.string(fromByteCount: receipt.succeededBytes),
                symbol: "trash.fill"
            )
        }
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("项目最终状态")
                .font(.headline)

            LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ForEach(ExecutionReceiptItemStatus.allCases, id: \.self) { status in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: status.symbol)
                            .foregroundStyle(status.tint)
                            .accessibilityHidden(true)
                        Text(status.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: AppTheme.Spacing.xs)
                        Text(receipt.count(for: status).formatted())
                            .font(.body.monospacedDigit().weight(.semibold))
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .background(AppTheme.recessedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(status.title) \(receipt.count(for: status)) 项")
                }
            }
        }
    }

    private var receiptMetadata: some View {
        DisclosureGroup("收据信息") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ReceiptValueRow(title: String(localized: "收据 ID"), value: receipt.id.uuidString, monospaced: true)
                ReceiptValueRow(title: String(localized: "计划 ID"), value: receipt.planID.uuidString, monospaced: true)
                ReceiptValueRow(title: String(localized: "计划领域"), value: receipt.domain.receiptTitle)
                ReceiptValueRow(
                    title: String(localized: "执行开始"),
                    value: receipt.startedAt.formatted(date: .abbreviated, time: .standard)
                )
                ReceiptValueRow(
                    title: String(localized: "执行完成"),
                    value: receipt.completedAt.formatted(date: .abbreviated, time: .standard)
                )
                ReceiptValueRow(title: String(localized: "计划项目"), value: String(localized: "\(receipt.expectedItemCount.formatted()) 项"))
                ReceiptValueRow(title: String(localized: "用户中止"), value: receipt.wasUserAborted ? String(localized: "是") : String(localized: "否"))
            }
            .padding(.top, AppTheme.Spacing.sm)
        }
        .accessibilityHint("展开后显示收据和冻结计划标识、执行时间及中止状态")
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ForEach(receipt.warnings, id: \.self) { warning in
                Label(warning.localizedMessage, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(
                "所有成功项目只移入废纸篓，没有永久删除；可在 Finder 的废纸篓中恢复。",
                systemImage: "arrow.uturn.backward.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("逐项执行结果")
                .font(.headline)
            ForEach(receipt.items) { item in
                ExecutionReceiptItemRow(item: item)
            }
        }
    }
}

struct ExecutionReceiptFailureView: View {
    let error: ExecutionReceiptBuildError
    let primaryTitle: String
    let primaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Label("执行结果无法生成可信收据", systemImage: "exclamationmark.shield.fill")
                .font(.title2.bold())
                .foregroundStyle(AppTheme.danger)
            Text(error.localizedDescription)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("为避免展示不完整或错配结果，本页不会静默补齐收据。冻结计划仍保持不变，也不会自动重放。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(primaryTitle, systemImage: "arrow.clockwise", action: primaryAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("重新建立当前扫描结果；不会重放旧计划")
        }
        .liquidGlassSurface(tint: AppTheme.danger)
        .accessibilityElement(children: .contain)
    }
}

private struct ReceiptMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
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

private struct ReceiptValueRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ExecutionReceiptItemRow: View {
    let item: ExecutionReceiptItem

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Label(item.status.title, systemImage: item.status.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(item.status.tint)
                Text("第 \((item.order + 1).formatted()) 项 · \(item.category.receiptTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("预计 \(ExecutionReceiptCapacityFormatter.string(fromByteCount: item.estimatedBytes))")
                    .font(.caption.monospacedDigit())
                Text("实际 \(ExecutionReceiptCapacityFormatter.string(fromByteCount: item.actualBytes))")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            Text(item.originalPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(item.reasonText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.reasonCode.rawValue)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.recessedSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .stroke(item.status.tint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(localized: "第 \((item.order + 1).formatted()) 项，") +
            String(localized: "\(item.category.receiptTitle)，\(item.status.title)，") +
            String(localized: "路径 \(item.originalPath)，预计 \(ExecutionReceiptCapacityFormatter.string(fromByteCount: item.estimatedBytes))，") +
            String(localized: "实际 \(ExecutionReceiptCapacityFormatter.string(fromByteCount: item.actualBytes))，原因 \(item.reasonText)，") +
            String(localized: "原因代码 \(item.reasonCode.rawValue)")
        )
    }
}

private extension ExecutionReceiptItemStatus {
    var title: String {
        switch self {
        case .succeeded: String(localized: "成功")
        case .failed: String(localized: "失败")
        case .skipped: String(localized: "已跳过")
        case .aborted: String(localized: "中止")
        case .notExecuted: String(localized: "未执行")
        }
    }

    var symbol: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "shield.slash.fill"
        case .aborted: "stop.circle.fill"
        case .notExecuted: "minus.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: AppTheme.healthy
        case .failed: AppTheme.danger
        case .skipped, .aborted: AppTheme.warning
        case .notExecuted: .secondary
        }
    }
}

private extension OperationPlanDomain {
    var receiptTitle: String {
        switch self {
        case .cleanup: String(localized: "磁盘清理")
        case .uninstall: String(localized: "应用卸载")
        }
    }
}

private extension OperationPlanItemCategory {
    var receiptTitle: String {
        switch self {
        case .cleanup: String(localized: "清理候选")
        case .applicationBundle: String(localized: "应用本体")
        case .residue: String(localized: "卸载残留")
        }
    }
}

private extension ExecutionReceiptWarning {
    var localizedMessage: String {
        switch self {
        case .trashSpaceMayNotBeReleasedImmediately:
            String(localized: "文件仍在废纸篓时占用的空间可能尚未释放，可用空间不会立即完全增加。")
        }
    }
}
