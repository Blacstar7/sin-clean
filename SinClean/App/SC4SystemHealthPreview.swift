#if DEBUG
import AppKit
import Foundation
import SwiftUI

// SC-4 预览：全部为注入的内存实现，不进行真实采样、不读写真实存储、不发起任何网络请求。
// 覆盖状态：证据卡正常 / 持续压力 / 数据不足 / 趋势有数据 / 趋势数据不足 / 提醒设置。

@MainActor
struct SC4SystemHealthPreview: View {
    enum Mode: String, CaseIterable {
        case evidenceNormal = "normal"
        case evidenceSustained = "sustained"
        case evidenceNoData = "nodata"
        case trendWithData = "trend"
        case trendNoData = "trendnodata"
        case reminderSettings = "settings"
        /// SC-4 R3（b14）：隔离故障注入态——清空/采样持久化失败的真实界面反馈。
        case trendFailures = "trend-failures"
    }

    @StateObject private var settings = AppSettings(store: UserDefaults(suiteName: "sc4-preview") ?? .standard)
    @StateObject private var spaceAnalysisResults = SpaceAnalysisResultsViewModel()
    @StateObject private var viewModel: SystemHealthDashboardViewModel

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        let access: any SystemHealthDocumentAccessing
        if mode == .trendFailures {
            // 哨兵文件存在期间写入失败（删除哨兵即恢复）；预置 28 个采样点。
            access = SC4PreviewFailingTrendAccess()
        } else {
            access = InMemorySystemHealthDocumentAccess(
                document: mode == .trendWithData ? SC4PreviewData.trendDocument(access: nil) : nil
            )
        }
        // 趋势面自成一体：屏幕高度有限，仪表盘整页放不下全部区块，
        // 因此趋势态与「数据不足」态在专用滚动面上复验（仍是真实窗口与真实 AX 树）。
        let store = SystemHealthTrendStore(access: access)
        let preferences = InMemorySystemHealthReminderPreferenceStore(
            preferences: mode == .reminderSettings
                ? SystemHealthReminderPreferences(enabled: [.diskPressure, .memoryPressure])
                : .default
        )
        let engine = SystemHealthReminderEngine(store: preferences)
        _viewModel = StateObject(wrappedValue: SystemHealthDashboardViewModel(
            sampler: SC4StubSampler(mode: mode),
            trendStore: store,
            reminderEngine: engine,
            spaceAnalysisLink: { SC4PreviewData.spaceLink },
            isScanning: { false }
        ))
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            Group {
                if mode == .trendWithData || mode == .trendNoData {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                            Text("Mac 状态 · 趋势")
                                .font(.largeTitle.bold())
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
                            SystemHealthReminderPanel(
                                reminders: viewModel.reminders,
                                preferences: viewModel.preferences,
                                dismiss: { _ in }
                            )
                        }
                        .padding(AppTheme.Spacing.xl)
                        .frame(maxWidth: 980, alignment: .leading)
                    }
                } else if mode == .reminderSettings || mode == .trendFailures {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                            Text(mode == .trendFailures ? "设置 · 系统健康提醒（故障注入预览）" : "设置 · 系统健康提醒")
                                .font(.largeTitle.bold())
                            SystemHealthReminderSettingsSection(viewModel: viewModel)
                        }
                        .padding(AppTheme.Spacing.xl)
                        .frame(maxWidth: 720, alignment: .leading)
                    }
                } else {
                    DashboardView(viewModel: viewModel)
                }
            }
        }
        .tint(AppTheme.accent)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .environmentObject(settings)
        .environmentObject(spaceAnalysisResults)
        .task {
            await viewModel.loadPersistedState()
            await viewModel.refreshNow()
            if mode == .evidenceSustained {
                // 持续压力：连续注入足够样本，验证「持续」判据而不是单次峰值。
                for _ in 0..<SystemHealthSemantics.sustainedMinimumSamples + 2 {
                    await viewModel.refreshNow()
                }
            }
        }
    }
}

// MARK: - 预览用注入实现

/// SC-4 R3（b14）：哨兵文件控制的隔离故障注入（仅 DEBUG 预览）。
/// 哨兵存在期间 `write` 失败、删除哨兵即恢复；`read` 透传内存文档。
/// 复用 SC-5 权限哨兵通道先例；不触碰真实 Application Support、不修改任何权限。
private final class SC4PreviewFailingTrendAccess: SystemHealthDocumentAccessing, @unchecked Sendable {
    static let sentinelPath = "/tmp/sc4-preview-trend-write-failure.sentinel"

    private let backing = InMemorySystemHealthDocumentAccess(
        document: SC4PreviewData.trendDocument(access: nil)
    )

    var locationDescription: String { "memory://preview/trend-failures/trends.json" }

    func read() throws -> Data? { try backing.read() }

    func write(_ data: Data) throws {
        if FileManager.default.fileExists(atPath: Self.sentinelPath) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try backing.write(data)
    }
}

private struct SC4StubSampler: SystemHealthSampling {
    let mode: SC4SystemHealthPreview.Mode

    func sample() async -> SystemHealthSample {
        switch mode {
        case .evidenceNoData:
            return SC4PreviewData.sample(
                pressure: .unavailable,
                cpuLoad: 0.12,
                freeRatio: nil,
                battery: nil
            )
        case .evidenceSustained, .trendWithData, .trendNoData, .reminderSettings, .trendFailures:
            return SC4PreviewData.sample(
                pressure: .warning,
                cpuLoad: 0.93,
                freeRatio: 0.07,
                battery: BatterySnapshot(level: 0.15, isCharging: false, timeRemaining: 5_400)
            )
        case .evidenceNormal:
            return SC4PreviewData.sample(
                pressure: .normal,
                cpuLoad: 0.24,
                freeRatio: 0.42,
                battery: BatterySnapshot(level: 0.82, isCharging: false, timeRemaining: 14_400)
            )
        }
    }
}

private enum SC4PreviewData {
    static let spaceLink = SpaceAnalysisLink(
        hasResult: true,
        scannedTotalBytes: 18_400_000_000,
        largeFileCount: 6,
        largeFileBytes: 12_000_000_000,
        finishedAt: Date(timeIntervalSince1970: 1_789_000_000)
    )

    static func sample(
        pressure: MemoryPressureLevel,
        cpuLoad: Double,
        freeRatio: Double?,
        battery: BatterySnapshot?
    ) -> SystemHealthSample {
        let total: Int64 = 1_000_000_000_000
        let free = Int64(Double(total) * (freeRatio ?? 0))
        return SystemHealthSample(
            capturedAt: Date(),
            memoryPressure: pressure,
            memoryPressureRawValue: pressure == .unavailable ? nil : (pressure == .normal ? 1 : 2),
            memoryUsedBytes: 12_000_000_000,
            physicalMemoryBytes: 16_000_000_000,
            compressorBytes: 640_000_000,
            cpuLoad: cpuLoad,
            processorCount: 10,
            volumeFreeBytes: free,
            volumeTotalBytes: total,
            battery: battery,
            externalDriveCount: 0,
            lowPowerModeEnabled: false,
            screenLocked: false,
            network: NetworkSnapshot(
                isConnected: true,
                interfaceName: "en0",
                uploadBytesPerSecond: 24_000,
                downloadBytesPerSecond: 320_000
            ),
            uptime: 86_400
        )
    }

    /// 趋势有数据态：预置 8 个点（> 判据下限 3），使折线可见。
    static func trendDocument(access: InMemorySystemHealthDocumentAccess?) -> Data? {
        let base = Date(timeIntervalSince1970: 1_789_000_000)
        func points(_ values: [Double]) -> [SystemHealthTrendPoint] {
            values.enumerated().map { index, value in
                SystemHealthTrendPoint(timestamp: base.addingTimeInterval(Double(index) * 5), value: value)
            }
        }
        let trends = SystemHealthTrends(
            formatVersion: SystemHealthTrends.currentFormatVersion,
            cpu: points([0.12, 0.18, 0.22, 0.35, 0.41, 0.38, 0.44, 0.39]),
            memoryPressure: points([1, 1, 1, 1, 2, 2, 2, 2]),
            network: points([120_000, 240_000, 180_000, 320_000, 410_000, 260_000, 300_000, 280_000]),
            disk: points([520_000_000_000, 519_000_000_000, 517_500_000_000, 516_000_000_000])
        )
        return try? JSONEncoder().encode(trends)
    }
}
#endif
