import SwiftUI

// SC-5 首次使用界面（三屏，硬上限）。
// §1：引导不申请任何权限；§2：四项原则逐字呈现；§7：中性文案。

struct OnboardingView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var viewModel: OnboardingViewModel
    let onFinished: () -> Void

    init(viewModel: OnboardingViewModel, onFinished: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header
            stepContent
            footer
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: 620, alignment: .leading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("欢迎使用 Sin Clean")
                    .font(.title2.bold())
                Spacer(minLength: AppTheme.Spacing.sm)
                Text(viewModel.step.positionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("引导进度")
                    .accessibilityValue(viewModel.step.positionText)
            }
            Text("三步了解核心规则，约 20 秒。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(viewModel.step.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(viewModel.step.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(viewModel.step.principles) { principle in
                principleRow(principle)
            }

            if viewModel.step == .permissionsOnDemand {
                permissionSummary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var permissionSummary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            onboardingFact(
                symbol: "switch.2",
                title: String(localized: "两项可选权限"),
                detail: String(localized: "读取受保护目录、发送提醒。")
            )
            onboardingFact(
                symbol: "hand.tap",
                title: String(localized: "需要时才申请"),
                detail: String(localized: "使用相关功能时，会先说明为什么需要、用来做什么。")
            )
            onboardingFact(
                symbol: "arrow.triangle.branch",
                title: String(localized: "拒绝不影响其他功能"),
                detail: String(localized: "未授权的相关能力不可用，其余功能照常使用。")
            )
            Text("本引导只作说明，不会申请任何权限。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, AppTheme.Spacing.xs)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("权限按需说明")
        .accessibilityValue(viewModel.step.permissionNote ?? "")
    }

    private func onboardingFact(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: symbol)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func principleRow(_ principle: OnboardingPrinciple) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: principle.symbol)
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(principle.title)
                    .font(.callout.weight(.semibold))
                Text(principle.statement)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("安全原则 \(principle.title)")
        .accessibilityValue(principle.statement)
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("上一步") { viewModel.back() }
                .buttonStyle(.bordered)
                .disabled(viewModel.isFirstStep)
                .accessibilityLabel("返回上一屏")
                .accessibilityValue(viewModel.isFirstStep ? "已在第一屏" : "回到\(OnboardingStep(rawValue: viewModel.step.rawValue - 1)?.title ?? "")")

            Button("跳过") { viewModel.skipToLast() }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLastStep)
                .accessibilityLabel("跳过剩余说明，直达最后一屏")
                .accessibilityHint("不会跳过任何权限说明，也不会申请任何权限")

            Spacer(minLength: AppTheme.Spacing.sm)

            if viewModel.isLastStep {
                Button("开始使用") {
                    viewModel.finish()
                    onFinished()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("完成首次使用说明并开始使用")
                .accessibilityHint("本引导不会申请任何权限")
            } else {
                Button("下一步") { viewModel.next() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("进入下一屏")
                    .accessibilityValue(viewModel.step.positionText)
            }
        }
    }

    private var surfaceStyle: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(AppTheme.obsidian) : AnyShapeStyle(.ultraThinMaterial)
    }
}
