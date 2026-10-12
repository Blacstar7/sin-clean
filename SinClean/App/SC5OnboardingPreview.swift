#if DEBUG
import AppKit
import Foundation
import SwiftUI

// SC-5 预览：全部为注入的内存实现；不申请任何权限、不跳转系统设置、不读写真实存储。
// 覆盖状态：首次使用三屏 / 权限被拒降级 / 权限状态可见 / 隐私页 / 撤回后状态。

@MainActor
struct SC5OnboardingPreview: View {
    enum Mode: String, CaseIterable {
        case onboardingFirst = "step1"
        case onboardingSecond = "step2"
        case onboardingThird = "step3"
        case permissionDenied = "denied"
        case permissionVisible = "visible"
        case privacy
        case revoked
        /// SC-5.2 修补复验态：脚本化探针（首次查询「未授权」、再次查询「已授权」），
        /// 用于真实复验「重新检测」入口与「回到本应用自动重新检测」两条路径。
        case permissionRecheck = "recheck"
    }

    @StateObject private var onboarding: OnboardingViewModel
    @StateObject private var permissions: PermissionStatusViewModel

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        let completionStore = InMemoryOnboardingCompletionStore(completed: false)
        let viewModel = OnboardingViewModel(store: completionStore)
        _onboarding = StateObject(wrappedValue: viewModel)

        let probe: any PermissionStatusProbing
        if mode == .permissionRecheck {
            // 以 /tmp 哨兵模拟「用户在系统设置中授权」；复验工具在动作前放置哨兵，
            // 并读取查询日志判断应用是否真的重新查询过。
            probe = SentinelPermissionProbe()
        } else {
            probe = InjectedPermissionProbe(snapshot: SC5PreviewData.snapshot(for: mode))
        }
        let permissionViewModel = PermissionStatusViewModel(probe: probe)
        permissionViewModel.updateCoverage(
            hasScanResult: true,
            unreadableDirectoryCount: SC5PreviewData.unreadableCount(for: mode),
            scanCompleted: true
        )
        _permissions = StateObject(wrappedValue: permissionViewModel)
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            Group {
                switch mode {
                case .onboardingFirst, .onboardingSecond, .onboardingThird:
                    OnboardingView(viewModel: onboarding)
                case .privacy:
                    PrivacyView()
                case .permissionDenied, .permissionVisible, .revoked, .permissionRecheck:
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                            Text("空间分析 · 扫描覆盖与权限")
                                .font(.largeTitle.bold())
                            PermissionStatusStrip(viewModel: permissions, openSettings: { _ in })
                            degradationNote
                        }
                        .padding(AppTheme.Spacing.xl)
                        .frame(maxWidth: 820, alignment: .leading)
                    }
                }
            }
        }
        .tint(AppTheme.accent)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task {
            // 权限状态的首次查询由 PermissionStatusStrip 自身的 .task 负责（与生产路径一致），
            // 此处只为引导屏推进步骤，避免脚本化探针被重复消费。
            switch mode {
            case .onboardingSecond: onboarding.next()
            case .onboardingThird: onboarding.next(); onboarding.next()
            default: break
            }
        }
    }

    /// 权限被拒或撤回后的降级说明：主流程照常可用。
    private var degradationNote: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("被拒绝或撤回后会发生什么")
                .font(.headline)
            Text("扫描、分析、逐项手动处理与系统健康全部照常可用；受保护目录的内容不会被统计，上面的覆盖条会明确写出有几个目录未统计。应用不会因此删除任何数据，也不会改变任何既有行为。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("权限降级说明")
        .accessibilityValue("扫描、分析、逐项手动处理与系统健康全部照常可用；受保护目录不计入统计并明确标注")
    }
}

private enum SC5PreviewData {
    static func snapshot(for mode: SC5OnboardingPreview.Mode) -> PermissionStatusSnapshot {
        switch mode {
        case .permissionDenied:
            PermissionStatusSnapshot(fullDiskAccess: .denied, notifications: .denied)
        case .permissionVisible:
            PermissionStatusSnapshot(fullDiskAccess: .denied, notifications: .granted)
        case .revoked:
            PermissionStatusSnapshot(fullDiskAccess: .unknown, notifications: .denied)
        case .permissionRecheck:
            PermissionStatusSnapshot(fullDiskAccess: .denied, notifications: .granted)
        default:
            .unknown
        }
    }



    static func unreadableCount(for mode: SC5OnboardingPreview.Mode) -> Int {
        switch mode {
        case .permissionDenied, .permissionVisible, .permissionRecheck: 3
        case .revoked: 0
        default: 0
        }
    }
}

/// 预览专用夹具：以 `/tmp` 哨兵文件模拟「用户在系统设置中授权了完全磁盘访问」，
/// 并把每次查询追加到 `/tmp` 查询日志——复验工具据此判定「是否真的重新查询」。
/// 只读查询，不申请任何权限，不跳转系统设置。
final class SentinelPermissionProbe: PermissionStatusProbing, @unchecked Sendable {
    static let grantSentinelPath = "/tmp/sc5-permission-granted.sentinel"
    static let queryLogPath = "/tmp/sc5-permission-queries.log"

    private let lock = NSLock()

    private func current() -> PermissionStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let granted = FileManager.default.fileExists(atPath: Self.grantSentinelPath)
        let line = "\(ISO8601DateFormatter().string(from: Date())) granted=\(granted)\n"
        if let handle = FileHandle(forWritingAtPath: Self.queryLogPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: Self.queryLogPath))
        }
        return PermissionStatusSnapshot(
            fullDiskAccess: granted ? .granted : .denied,
            notifications: .granted
        )
    }

    func snapshot() async -> PermissionStatusSnapshot { current() }
}

/// SC-5 二次返工（C-a）预览：真实设置页（`SettingsView`）＋注入的内存实现，
/// 用于以真实 accessibility tree 复验「刷新间隔」档位（自动／固定）与说明文案。
/// 档位由 `--sc5-preview-refresh-fixed30`／`--sc5-preview-refresh-fixed60` 覆盖（默认自动）。
@MainActor
struct SC5RefreshSettingsPreview: View {
    @StateObject private var settings: AppSettings
    @StateObject private var ignoreList: IgnoreListStore
    @StateObject private var onboarding: OnboardingViewModel

    init() {
        // 独立 suite，避免读写真实偏好；档位覆盖只在实例内生效（见 AppSettings 的 DEBUG 分支）。
        let store = UserDefaults(suiteName: "sc5-refresh-settings-preview") ?? .standard
        _settings = StateObject(wrappedValue: AppSettings(store: store))
        let listStore = IgnoreListStore(
            repository: InMemoryIgnoreRuleRepository(),
            autoload: false
        )
        _ignoreList = StateObject(wrappedValue: listStore)
        _onboarding = StateObject(wrappedValue: OnboardingViewModel(
            store: InMemoryOnboardingCompletionStore(completed: true)
        ))
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                SettingsView()
                    .padding(AppTheme.Spacing.xl)
                    .frame(maxWidth: 860, alignment: .leading)
            }
        }
        .preferredColorScheme(.dark)
        .environmentObject(settings)
        .environmentObject(ignoreList)
        .environmentObject(onboarding)
    }
}
#endif
