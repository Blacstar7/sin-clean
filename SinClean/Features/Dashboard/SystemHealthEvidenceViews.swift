import SwiftUI

// SC-4 证据卡、趋势与提醒面板。
// 无障碍口径：每个卡片是一个有自己 label/value 的合并元素，五要素全部进入 value
// （避免子文本被显式值吞掉）。

struct SystemHealthEvidenceCardView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let card: HealthEvidenceCard

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: card.symbol)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                Text(card.category)
                    .font(.headline)
                Spacer(minLength: AppTheme.Spacing.sm)
                Text(card.evidence.updatedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(card.evidence.value)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text("推荐操作：\(card.evidence.recommendation.action)")
                .font(.callout.weight(.medium))

            InformationDisclosure(
                title: String(localized: "判断依据与限制"),
                summary: String(localized: "持续时间、能解决什么、不能解决什么"),
                symbol: "doc.text.magnifyingglass",
                tint: AppTheme.accent
            ) {
                labelledLine(String(localized: "判断依据"), card.evidence.basis)
                labelledLine(String(localized: "持续时间"), card.evidence.duration)
                Text("能解决：\(card.evidence.recommendation.canSolve)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("不能解决：\(card.evidence.recommendation.cannotSolve)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("落点：\(card.evidence.recommendation.target.title)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.category)证据卡")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("包含测量值、判断依据、持续时间、更新时间与推荐操作")
    }

    private func labelledLine(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityValue: String {
        let e = card.evidence
        return String(localized: "测量值 \(e.value)。判断依据 \(e.basis)。持续时间 \(e.duration)。更新时间 \(e.updatedAt.formatted(date: .abbreviated, time: .standard))。推荐操作 \(e.recommendation.action)；能解决 \(e.recommendation.canSolve)；不能解决 \(e.recommendation.cannotSolve)；落点 \(e.recommendation.target.title)")
    }

    private var surfaceStyle: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(AppTheme.obsidian) : AnyShapeStyle(.ultraThinMaterial)
    }
}

struct SystemHealthTrendSection: View {
    let series: SystemHealthTrendSeries
    let points: [SystemHealthTrendPoint]
    let hasEnoughPoints: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.title)
                    .font(.headline)
                Spacer(minLength: AppTheme.Spacing.sm)
                Text(series.unitNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if hasEnoughPoints {
                chart
            } else {
                Text("数据不足，暂不显示趋势")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(series.title)数据不足")
                    .accessibilityValue("数据不足，暂不显示趋势；当前 \(points.count) 个点，少于 \(SystemHealthSemantics.trendMinimumPoints) 个，也不做任何预测")
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var chart: some View {
        GeometryReader { proxy in
            let values = points.map(\.value)
            let minimum = values.min() ?? 0
            let maximum = values.max() ?? 1
            let span = max(maximum - minimum, 0.0001)
            let stepX = proxy.size.width / CGFloat(max(points.count - 1, 1))
            Path { path in
                for (index, point) in points.enumerated() {
                    let x = CGFloat(index) * stepX
                    let ratio = (point.value - minimum) / span
                    let y = proxy.size.height * (1 - CGFloat(ratio))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(series.title)折线图")
        .accessibilityValue(trendValueSummary)
    }

    private var trendValueSummary: String {
        guard let first = points.first, let last = points.last else { return String(localized: "无数据") }
        return String(localized: "共 \(points.count) 个点，最早 \(first.timestamp.formatted(date: .omitted, time: .shortened))，最新 \(last.timestamp.formatted(date: .omitted, time: .shortened))；最新值 \(String(format: "%.2f", last.value))")
    }
}

struct SystemHealthReminderPanel: View {
    let reminders: [SystemHealthReminder]
    let preferences: SystemHealthReminderPreferences
    let dismiss: (SystemHealthReminder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("提醒")
                    .font(.headline)
                Text("已开启 \(preferences.enabledKinds.count.formatted()) / \(SystemHealthReminderKind.allCases.count.formatted()) 类")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if reminders.isEmpty {
                Text("可在“设置”中按类别开启；省电或后台策略不会静默关闭已开启的提醒。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("当前没有提醒")
                    .accessibilityValue("提醒默认关闭，且不会被省电或后台策略静默关闭")
            } else {
                ForEach(reminders) { reminder in
                    HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "bell.badge")
                            .foregroundStyle(AppTheme.warning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reminder.title)
                                .font(.callout.weight(.semibold))
                            Text(reminder.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("落点：\(reminder.target.title)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Button("忽略") { dismiss(reminder) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("忽略提醒 \(reminder.title)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("提醒 \(reminder.title)")
                    .accessibilityValue("\(reminder.message) 落点 \(reminder.target.title)")
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
