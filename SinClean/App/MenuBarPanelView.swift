import AppKit
import SwiftUI

private enum MenuPalette {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.68)
    static let tertiary = Color.white.opacity(0.46)
    static let solidFallback = Color(red: 0.10, green: 0.07, blue: 0.18).opacity(0.97)
}

struct MenuBarPanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject private var viewModel: SystemHealthDashboardViewModel
    @State private var isPresented = false
    @State private var samplingConsumerToken = UUID()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    init(viewModel: SystemHealthDashboardViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            menuBackground

            LiquidGlassGroup(spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    processorCard

                    VStack(alignment: .leading, spacing: 14) {
                        LazyVGrid(columns: columns, spacing: 12) {
                            diskCard
                            memoryCard
                            batteryCard
                            networkCard
                        }

                        externalDriveCard

                        suggestionCard

                        footer
                    }
                }
                .padding(20)
            }

            MenuOpeningOverlay(isPresented: isPresented, reduceMotion: reduceMotion)
        }
        .frame(width: 452, height: 760)
        .foregroundStyle(MenuPalette.primary)
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
        .task(id: settings.dashboardRefreshTaskID) {
            // SC-4.4：采样节奏交给自适应策略（前台基础 5 秒 / 后台 30 / 锁屏 120 / 低电量 30 / 扫描中 60 秒），
            // 不再使用固定 2 秒轮询。用户关闭自动刷新时只做一次手动采样。
            // SC-ARCH-R2：两界面提交同一全局配置身份，只有第一次提交会采样或重启共享循环。
            await viewModel.activate(
                .menuBar(samplingConsumerToken),
                configurationID: settings.dashboardRefreshTaskID,
                automaticRefreshEnabled: settings.autoRefreshDashboard,
                preferredBaseInterval: settings.refreshBaseInterval
            )
        }
        .onAppear {
            isPresented = false
            DispatchQueue.main.async {
                isPresented = true
            }
        }
        .onDisappear {
            isPresented = false
            viewModel.deactivate(.menuBar(samplingConsumerToken))
        }
    }

    private var menuBackground: some View {
        ZStack {
            AuroraBackground()

            LinearGradient(
                colors: [.clear, AppTheme.obsidian.opacity(0.28), AppTheme.obsidian.opacity(0.52)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [AppTheme.violet.opacity(0.42), AppTheme.accent.opacity(0.13), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .padding(1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            // SC-Rework-UI-Visual R2 补完：面板头部品牌标识位（与主窗侧边栏同源冻结资产；
            // 手册 §5.3 禁额外渐变/投影，§4.2 遮罩自施加）。
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("本机状态 · 实时数据")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MenuPalette.secondary)
                Text("Mac 状态 \(healthWord)")
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(spacing: 2) {
                Text("\(viewModel.healthScore)")
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                Text("健康评分")
                    .font(.caption2)
                    .foregroundStyle(MenuPalette.secondary)
            }
            .frame(width: 62, height: 62)
            .menuGlassSurface(radius: 17)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Mac 健康评分 \(viewModel.healthScore) 分")
            .accessibilityValue(viewModel.scoreBasis)
        }
        .frame(height: 62)
    }

    private var processorCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("处理器实时负载")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MenuPalette.secondary)
                Spacer()
                Label(processorStatus, systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(processorTint)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("\(Int((sample?.cpuLoad ?? 0) * 100))%")
                    .font(.system(size: 38, weight: .medium, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Spacer()
                Text("过去 60 秒")
                    .font(.caption)
                    .foregroundStyle(MenuPalette.secondary)
            }

            MenuSparkline(values: viewModel.series(.cpu).map(\.value), tint: AppTheme.accent, lineWidth: 2.4)
                .frame(height: 36)
        }
        .padding(13)
        .frame(height: 128)
        .menuGlassSurface()
        .accessibilityElement(children: .combine)
    }

    private var diskCard: some View {
        MenuMetricCard(
            title: "Macintosh HD",
            status: viewModel.storagePressure.title,
            value: SystemFormatters.bytes.string(fromByteCount: sample?.volumeFreeBytes ?? 0),
            detail: String(localized: "可用，共 \(SystemFormatters.bytes.string(fromByteCount: sample?.volumeTotalBytes ?? 0))"),
            symbol: "internaldrive",
            tint: AppTheme.accent,
            progress: sample?.volumeFreeRatio ?? 0,
            statusIsHealthy: false
        )
    }

    private var memoryCard: some View {
        MenuMetricCard(
            title: String(localized: "内存使用"),
            status: sample?.memoryPressure.title ?? String(localized: "内存压力数据不可得"),
            value: SystemFormatters.bytes.string(fromByteCount: Int64(sample?.memoryUsedBytes ?? 0)),
            detail: String(localized: "已用，共 \(SystemFormatters.bytes.string(fromByteCount: Int64(sample?.physicalMemoryBytes ?? 0)))；档位只由系统内存压力决定"),
            symbol: "memorychip",
            tint: AppTheme.accent,
            progress: sample?.memoryUsedRatio ?? 0,
            statusIsHealthy: sample?.memoryPressure == .normal
        )
    }

    private var batteryCard: some View {
        MenuMetricCard(
            title: String(localized: "电池"),
            status: sample?.battery == nil ? String(localized: "无内置电池") : String(localized: "状态正常"),
            value: batteryValue,
            detail: batteryDetail,
            symbol: sample?.battery?.isCharging == true ? "battery.100percent.bolt" : "battery.75percent",
            tint: AppTheme.warning,
            progress: sample?.battery?.level,
            statusIsHealthy: sample?.battery != nil
        )
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: networkConnected ? "wifi" : "wifi.slash")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 26, height: 26)
                    .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text("Wi‑Fi")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(networkConnected ? String(localized: "已连接") : String(localized: "未连接"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(networkConnected ? AppTheme.healthy : AppTheme.warning)
            }

            HStack {
                Text("↑ \(SystemFormatters.bytesPerSecond(sample?.network.uploadBytesPerSecond ?? 0))")
                Spacer()
                Text("↓ \(SystemFormatters.bytesPerSecond(sample?.network.downloadBytesPerSecond ?? 0))")
            }
            .font(.caption.monospacedDigit())

            HStack(spacing: 6) {
                Text("连接稳定 · \(sample?.network.interfaceName ?? "—")")
                    .font(.caption2)
                    .foregroundStyle(MenuPalette.secondary)
                MenuSparkline(values: viewModel.series(.network).map(\.value), tint: AppTheme.accent, lineWidth: 1.8)
                    .frame(height: 20)
            }
        }
        .padding(12)
        .frame(height: 110)
        .menuGlassSurface()
        .accessibilityElement(children: .combine)
    }

    private var externalDriveCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.title3.weight(.medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("外置驱动器")
                    .font(.headline)
                Text(externalDriveDetail)
                    .font(.caption)
                    .foregroundStyle(MenuPalette.secondary)
            }

            Spacer()

            Button("查看设备 ›") {
                openMainWindow(section: .overview)
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .accessibilityHint("在主窗口查看完整状态")
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
        .menuGlassSurface(interactive: true)
        .glassHoverEffect()
        .accessibilityElement(children: .contain)
    }

    private var suggestionCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(suggestionTitle)
                    .font(.headline)
                Text(suggestionText)
                    .font(.callout)
                    .foregroundStyle(MenuPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("查看可清理项目") {
                openMainWindow(section: .cleanup)
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .foregroundStyle(AppTheme.obsidian)
            .padding(.horizontal, 15)
            .frame(height: 34)
            .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: AppTheme.accent.opacity(0.18), radius: 10, y: 5)
            .accessibilityHint("在主窗口打开空间清理的可清理项目")
        }
        .padding(16)
        .frame(height: 108)
        .menuGlassSurface(radius: 18, interactive: true)
        .glassHoverEffect()
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack {
            Label(
                monitorStatusTitle,
                systemImage: "circle.fill"
            )
            .font(.caption)
            .foregroundStyle(settings.autoRefreshDashboard ? AppTheme.healthy : AppTheme.warning)

            Spacer()

            Button("打开完整应用  ⌘O") {
                openMainWindow(section: .overview)
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .foregroundStyle(MenuPalette.primary)
            .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
        }
        .frame(height: 34)
        .accessibilityElement(children: .contain)
    }

    /// SC-5 二次返工（缺陷 D）：页脚按当前档位如实说明节奏，不再出现做不到的具体秒数。
    /// 自动档显示「自动（自适应）」；固定档显示其基础间隔；两者都附带当前实际间隔。
    private var monitorStatusTitle: String {
        guard settings.autoRefreshDashboard else { return String(localized: "自动刷新已暂停") }
        let current = SystemHealthFormatters.duration(viewModel.refreshInterval)
        switch settings.dashboardRefreshPreference {
        case .automatic:
            return String(localized: "实时监测中 · 自动（自适应），当前间隔 \(current)")
        case .thirtySeconds:
            return String(localized: "实时监测中 · 基础 30 秒，当前间隔 \(current)")
        case .sixtySeconds:
            return String(localized: "实时监测中 · 基础 1 分钟，当前间隔 \(current)")
        case .fiveMinutes:
            return String(localized: "实时监测中 · 基础 5 分钟，当前间隔 \(current)")
        }
    }

    private var sample: SystemHealthSample? { viewModel.sample }

    private var networkConnected: Bool { sample?.network.isConnected ?? false }

    private var healthWord: String {
        switch viewModel.healthScore {
        case 90...: String(localized: "出色")
        case 70..<90: String(localized: "良好")
        default: String(localized: "需要关注")
        }
    }

    /// 菜单栏也只按持续状态定性：单次负载再高也不写成「需要关注」。
    private var processorStatus: String {
        viewModel.sustainedLoad.title
    }

    private var processorTint: Color {
        switch viewModel.sustainedLoad {
        case .sampling, .steady: AppTheme.healthy
        case .sustained: AppTheme.warning
        }
    }

    private var batteryValue: String {
        guard let battery = sample?.battery else { return "—" }
        return "\(Int(battery.level * 100))%"
    }

    private var batteryDetail: String {
        guard let battery = sample?.battery else { return String(localized: "此 Mac 没有内置电池") }
        if battery.isCharging { return String(localized: "正在充电") }
        if let remaining = battery.timeRemaining {
            return String(localized: "约 \(max(1, Int(remaining / 3_600))) 小时 · 未充电")
        }
        return String(localized: "未充电 · 状态正常")
    }

    private var externalDriveDetail: String {
        (sample?.externalDriveCount ?? 0) == 0
            ? String(localized: "尚未连接任何设备")
            : String(localized: "已连接 \(sample?.externalDriveCount ?? 0) 个设备")
    }

    private var suggestionTitle: String {
        (sample?.volumeFreeRatio ?? 1) < 0.15 ? String(localized: "建议检查磁盘空间") : String(localized: "今天无需急着清理")
    }

    private var suggestionText: String {
        if (sample?.volumeFreeRatio ?? 1) < 0.15 {
            return String(localized: "可用空间较低，建议先扫描，再逐项复核候选文件。")
        }
        return String(localized: "系统负载平稳，磁盘空间充足。按需维护即可。")
    }

    private func refreshSnapshot() {
        Task { await viewModel.refreshNow() }
    }

    private func openMainWindow(section: AppSection) {
        navigation.request(section)
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Sin Clean" && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct MenuMetricCard: View {
    let title: String
    let status: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    let progress: Double?
    let statusIsHealthy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                Text(status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusIsHealthy ? AppTheme.healthy : AppTheme.warning)
            }

            Text(value)
                .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .contentTransition(.numericText())

            Text(detail)
                .font(.caption2)
                .foregroundStyle(MenuPalette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)

            if let progress {
                MenuProgressBar(value: progress, tint: tint)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(progress * 100))%")
            }
        }
        .padding(12)
        .frame(height: 110)
        .menuGlassSurface()
        .accessibilityElement(children: .combine)
    }
}

private struct MenuProgressBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let fraction = max(0, min(1, value))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.72)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width)
                    .scaleEffect(x: max(0.02, fraction), y: 1, anchor: .leading)
                    .shadow(color: tint.opacity(0.20), radius: 5)
                    .animation(.easeOut(duration: 0.24), value: fraction)
            }
        }
        .frame(height: 5)
    }
}

private struct MenuSparkline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let values: [Double]
    let tint: Color
    let lineWidth: CGFloat
    @State private var drawProgress = 0.0

    private var displayValues: [Double] {
        guard let first = values.first else { return [0, 0] }
        return values.count == 1 ? [first, first] : values
    }

    var body: some View {
        GeometryReader { proxy in
            let points = makePoints(in: proxy.size)

            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            .trim(from: 0, to: drawProgress)
            .stroke(tint.opacity(0.14), style: StrokeStyle(lineWidth: lineWidth + 10, lineCap: .round, lineJoin: .round))

            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            .trim(from: 0, to: drawProgress)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
        .onAppear {
            drawProgress = reduceMotion ? 1 : 0
            withAnimation(reduceMotion ? .linear(duration: 0.01) : AppTheme.Motion.chartDraw.delay(0.12)) {
                drawProgress = 1
            }
        }
    }

    private func makePoints(in size: CGSize) -> [CGPoint] {
        let samples = displayValues
        let maxValue = max(samples.max() ?? 1, 0.12)
        return samples.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(max(1, samples.count - 1))
            let normalized = CGFloat(value / maxValue)
            let y = size.height - (normalized * max(4, size.height - 4))
            return CGPoint(x: x, y: y)
        }
    }
}

private struct MenuGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        if #available(macOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(
                    .clear.tint(AppTheme.violet.opacity(0.08)).interactive(interactive),
                    in: shape
                )
                .overlay {
                    shape
                        .fill(AppTheme.glassWash)
                        .opacity(0.14)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                .overlay(edge(shape))
                .shadow(color: .black.opacity(0.21), radius: 15, y: 8)
        } else {
            content
                .background(reduceTransparency ? AnyShapeStyle(MenuPalette.solidFallback) : AnyShapeStyle(.ultraThinMaterial), in: shape)
                .overlay {
                    shape
                        .fill(AppTheme.glassWash)
                        .opacity(reduceTransparency ? 0.30 : 0.50)
                        .allowsHitTesting(false)
                }
                .overlay(edge(shape))
                .shadow(color: .black.opacity(0.24), radius: 20, y: 10)
        }
    }

    private func edge(_ shape: RoundedRectangle) -> some View {
        shape
            .stroke(
                LinearGradient(
                    colors: [.white.opacity(0.40), .white.opacity(0.075), AppTheme.accent.opacity(0.15), .white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.30), AppTheme.accent.opacity(0.11), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 104, height: 1)
                    .padding(.leading, 18)
            }
            .allowsHitTesting(false)
    }
}

private struct MenuOpeningOverlay: View {
    let isPresented: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let sweepWidth: CGFloat = 116

            ZStack(alignment: .leading) {
                AppTheme.obsidian
                    .opacity(isPresented ? 0 : 0.16)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, AppTheme.accent.opacity(0.11), AppTheme.violet.opacity(0.08), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: sweepWidth)
                    .offset(x: isPresented ? proxy.size.width + sweepWidth : -sweepWidth)
                    .opacity(isPresented ? 0 : 1)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, AppTheme.accent.opacity(0.88), AppTheme.violet.opacity(0.55), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: sweepWidth, height: 2)
                    .offset(x: isPresented ? proxy.size.width + sweepWidth : -sweepWidth, y: -proxy.size.height / 2 + 2)
                    .opacity(isPresented ? 0 : 1)
            }
        }
        .animation(
            reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.28),
            value: isPresented
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension View {
    func menuGlassSurface(radius: CGFloat = 16, interactive: Bool = false) -> some View {
        modifier(MenuGlassSurface(radius: radius, interactive: interactive))
    }

}

#if DEBUG
#Preview("菜单栏面板") {
    MenuBarPanelView(viewModel: SystemHealthDashboardViewModel.isolatedPreview())
        .environmentObject(AppSettings())
        .environmentObject(AppNavigationState())
}
#endif
