import AppKit
import SwiftUI

// SC-4 Mac 状态页：证据卡、趋势与提醒。
// 语义见 work/SC-4-frozen-semantics.md：
// - 内存以系统压力为准、CPU 以持续状态为准、磁盘升级为存储压力并只读连接空间分析；
// - 运行时间与核心数不参与健康扣分；
// - 每个事实都给出测量值、判断依据、持续时间、更新时间与推荐操作。

struct DashboardView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var spaceAnalysisResults: SpaceAnalysisResultsViewModel
    @ObservedObject private var viewModel: SystemHealthDashboardViewModel
    @State private var samplingConsumerToken = UUID()

    init(viewModel: SystemHealthDashboardViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                header
                scoreSection
                evidenceSection
                trendSection
                SystemHealthReminderPanel(
                    reminders: viewModel.reminders,
                    preferences: viewModel.preferences,
                    dismiss: { viewModel.dismissReminder($0) }
                )
                honestySection
            }
            .padding(AppTheme.Spacing.xl)
            .frame(maxWidth: 1_080, alignment: .leading)
        }
        .background(.clear)
        .accessibilityElement(children: .contain)
        .task(id: settings.dashboardRefreshTaskID) {
            let results = spaceAnalysisResults
            viewModel.bind(
                spaceAnalysisLink: { [weak results] in
                    guard let results else { return .none }
                    return Self.link(from: results)
                },
                isScanning: { [weak results] in
                    results?.isScanning ?? false
                }
            )
            // SC-ARCH-R2：两界面提交同一全局配置身份，只有第一次提交会采样或重启共享循环。
            await viewModel.activate(
                .dashboard(samplingConsumerToken),
                configurationID: settings.dashboardRefreshTaskID,
                automaticRefreshEnabled: settings.autoRefreshDashboard,
                preferredBaseInterval: settings.refreshBaseInterval
            )
        }
        .onDisappear { viewModel.deactivate(.dashboard(samplingConsumerToken)) }
    }

    /// 只读引用：仅读取既有空间分析结果，不触发扫描、不触碰任何文件。
    private static func link(from results: SpaceAnalysisResultsViewModel) -> SpaceAnalysisLink {
        guard let outcome = results.outcome else { return .none }
        let largeFiles = results.largeFiles
        return SpaceAnalysisLink(
            hasResult: true,
            scannedTotalBytes: outcome.summary.scannedTotalBytes,
            largeFileCount: largeFiles.count,
            largeFileBytes: largeFiles.reduce(Int64(0)) { $0 + $1.allocatedBytes },
            finishedAt: outcome.summary.finishedAt
        )
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mac 状态")
                    .font(.largeTitle.bold())
                Text(viewModel.sample.map {
                    "关键指标来自本机 · 更新于 \($0.capturedAt.formatted(date: .omitted, time: .standard))"
                } ?? "正在读取本机指标…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("采样节奏：\(viewModel.refreshReason)（当前间隔 \(SystemHealthFormatters.duration(viewModel.refreshInterval))）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("采样节奏说明")
                    .accessibilityValue("\(viewModel.refreshReason)，当前间隔 \(SystemHealthFormatters.duration(viewModel.refreshInterval))")
            }
            Spacer(minLength: AppTheme.Spacing.lg)
            Button {
                Task { await viewModel.refreshNow() }
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isSampling)
            .accessibilityLabel("立即刷新本机指标")
            .accessibilityValue(viewModel.isSampling ? "正在采样" : "可以刷新")
            .accessibilityHint("只读取系统指标，不扫描目录、不修改任何文件")
        }
    }

    // MARK: - 评分

    private var scoreSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.md) {
                Text("\(viewModel.healthScore)")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text("健康评分")
                        .font(.headline)
                    Text("您的 Mac \(viewModel.healthTitle)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppTheme.Spacing.sm)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Mac 健康评分 \(viewModel.healthScore) 分")
            .accessibilityValue("\(viewModel.healthTitle)。\(viewModel.scoreBasis)")

            InformationDisclosure(
                title: String(localized: "评分依据"),
                summary: String(localized: "查看这次评分如何得出"),
                symbol: "function",
                tint: AppTheme.accent
            ) {
                Text(viewModel.scoreBasis)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    // MARK: - 证据卡

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("状态证据卡")
                    .font(.title3.bold())
                Spacer()
                Text("先看结果和建议，依据与限制可展开")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320), spacing: AppTheme.Spacing.md)],
                alignment: .leading,
                spacing: AppTheme.Spacing.md
            ) {
                ForEach(viewModel.evidenceCards) { card in
                    SystemHealthEvidenceCardView(card: card)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 趋势

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("趋势")
                    .font(.title3.bold())
                Spacer()
                Text("数据不足时不绘制、不预测")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320), spacing: AppTheme.Spacing.md)],
                alignment: .leading,
                spacing: AppTheme.Spacing.md
            ) {
                ForEach(SystemHealthTrendSeries.allCases) { series in
                    SystemHealthTrendSection(
                        series: series,
                        points: viewModel.series(series),
                        hasEnoughPoints: viewModel.hasEnoughPoints(for: series)
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 诚实说明

    private var honestySection: some View {
        InformationDisclosure(
            title: String(localized: "指标说明"),
            summary: String(localized: "了解评分能说明什么，以及它的边界"),
            symbol: "info.circle",
            tint: AppTheme.accent
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("这些数字能说明什么")
                    .font(.headline)
                Text("内存以系统内存压力为准，不看占用率；CPU 看持续状态，单次峰值不算异常；磁盘是存储压力，并只读引用空间分析的统计结果。运行时间与核心数不参与健康扣分。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("这些数字不能说明什么")
                    .font(.headline)
                Text("它们不能替代对具体应用的判断，也不能解释个别应用的卡顿感受。本页不会清理缓存、不删除文件、不发起任何网络请求；需要处理文件时，请前往“空间清理”的“可清理项目”或“空间分析”，那里始终是先统计、逐项确认，且只会把您选中的项目移入系统废纸篓。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var surfaceStyle: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(AppTheme.obsidian) : AnyShapeStyle(.ultraThinMaterial)
    }
}

#if DEBUG
#Preview("浅色") {
    DashboardView(viewModel: SystemHealthDashboardViewModel.isolatedPreview())
        .frame(width: 900, height: 720)
        .environmentObject(AppSettings())
        .environmentObject(SpaceAnalysisResultsViewModel())
}

#Preview("深色") {
    DashboardView(viewModel: SystemHealthDashboardViewModel.isolatedPreview())
        .frame(width: 900, height: 720)
        .preferredColorScheme(.dark)
        .environmentObject(AppSettings())
        .environmentObject(SpaceAnalysisResultsViewModel())
}
#endif
