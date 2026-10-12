import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ignoreList: IgnoreListStore
    @ObservedObject private var healthViewModel: SystemHealthDashboardViewModel
    /// SC-7：提醒开关的真实通知申请与投递接线（应用级共享实例经环境注入）。
    @EnvironmentObject private var notificationDelivery: SystemNotificationDelivery
    @StateObject private var permissionViewModel = PermissionStatusViewModel()
    @EnvironmentObject private var onboarding: OnboardingViewModel
    @EnvironmentObject private var spaceChangeHistory: SpaceChangeHistoryStore
    @State private var showsPrivacy = false
    @State private var showsSpaceChangeClearConfirmation = false
    @State private var spaceChangeClearFailed = false
    let embedded: Bool

    init(
        healthViewModel: SystemHealthDashboardViewModel,
        embedded: Bool = false
    ) {
        _healthViewModel = ObservedObject(wrappedValue: healthViewModel)
        self.embedded = embedded
    }

    #if DEBUG
    /// 既有 DEBUG 预览调用点的兼容入口；持久化显式隔离在内存中，Release 不存在此构造。
    init(embedded: Bool = false) {
        self.init(
            healthViewModel: SystemHealthDashboardViewModel.isolatedPreview(),
            embedded: embedded
        )
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("设置")
                            .font(.largeTitle.bold())
                        Text("管理刷新频率、扫描范围、性能与隐私权限")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("恢复默认设置", systemImage: "arrow.counterclockwise", action: settings.reset)
                        .buttonStyle(.bordered)
                        .help("恢复刷新、扫描范围与性能设置；不会清除忽略规则")
                        .accessibilityLabel("恢复常规默认设置，不清除忽略规则")
                }

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: embedded ? 360 : 420), spacing: AppTheme.Spacing.lg)
                    ],
                    alignment: .leading,
                    spacing: AppTheme.Spacing.lg
                ) {
                    SettingsGroup(
                        title: String(localized: "状态监测"),
                        subtitle: String(localized: "调整主界面和菜单栏的数据刷新行为。")
                    ) {
                        Toggle("自动刷新 Mac 状态", isOn: $settings.autoRefreshDashboard)
                        Divider()
                        // C-a：档位真正生效——自动＝自适应基础 5 秒；固定档作为基础间隔参与取最宽。
                        Picker("刷新间隔", selection: $settings.dashboardRefreshPreference) {
                            ForEach(DashboardRefreshPreference.allCases) { preference in
                                Text(preference.title).tag(preference)
                            }
                        }
                        .disabled(!settings.autoRefreshDashboard)
                        InformationDisclosure(
                            title: String(localized: "刷新规则"),
                            summary: String(localized: "系统会根据前台、后台、锁屏、低电量和扫描状态调整间隔"),
                            symbol: "timer",
                            tint: AppTheme.accent
                        ) {
                            Text("自动（自适应）：跟随系统状态调整，前台基础 5 秒；固定档作为基础间隔，在后台、锁屏、低电量或扫描时仍会进一步放宽。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityValue("自动（自适应）：跟随系统状态调整，前台基础 5 秒；固定档作为基础间隔，在后台、锁屏、低电量或扫描时仍会进一步放宽。")
                    }

                    SettingsGroup(
                        title: String(localized: "扫描性能"),
                        subtitle: String(localized: "只影响读取速度，不会修改任何文件。")
                    ) {
                        Picker("容量统计速度", selection: $settings.measurementConcurrency) {
                            Text("节能").tag(2)
                            Text("均衡").tag(4)
                            Text("快速").tag(6)
                        }
                        .pickerStyle(.segmented)
                        Divider()
                        Toggle("分析登录项、后台代理和安装收据", isOn: $settings.analyzeAssociatedComponents)
                    }

                    SettingsGroup(
                        title: String(localized: "扫描位置"),
                        subtitle: String(localized: "至少保留一个应用目录，更改将在下次扫描时生效。")
                    ) {
                        Toggle(
                            "应用程序 /Applications",
                            isOn: Binding(
                                get: { settings.includeSystemApplications },
                                set: { newValue in
                                    settings.setIncludeSystemApplications(newValue)
                                }
                            )
                        )
                        Divider()
                        Toggle(
                            "用户应用程序 ~/Applications",
                            isOn: Binding(
                                get: { settings.includeUserApplications },
                                set: { newValue in
                                    settings.setIncludeUserApplications(newValue)
                                }
                            )
                        )
                    }

                    SettingsGroup(
                        title: String(localized: "隐私与安全"),
                        subtitle: String(localized: "Sin Clean 不会尝试绕过 macOS 权限。")
                    ) {
                        Label("文件路径与扫描结果始终在本机处理", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(AppTheme.healthy)
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("完全磁盘访问")
                                Text("仅在读取受保护目录时需要")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("打开系统设置", systemImage: "gear") {
                                openPrivacySettings()
                            }
                        }
                    }

                    SettingsGroup(
                        title: String(localized: "空间变化记录"),
                        subtitle: String(localized: "记录保存在本机，可随时关闭或清除。")
                    ) {
                        spaceChangeSection
                    }
                }

                SystemHealthReminderSettingsSection(
                    viewModel: healthViewModel,
                    delivery: notificationDelivery,
                    permissionStatus: permissionViewModel
                )

                PermissionSettingsSection(
                    viewModel: permissionViewModel,
                    reopenOnboarding: { onboarding.reopen() },
                    openSettings: { kind in
                        guard let url = URL(string: PermissionGuidance.settingsURL(for: kind)) else { return }
                        NSWorkspace.shared.open(url)
                    },
                    showPrivacy: { showsPrivacy = true }
                )

                IgnoreListSettingsSection(ignoreList: ignoreList)
            }
            .padding(AppTheme.Spacing.xl)
            .frame(maxWidth: embedded ? 1_080 : 760, alignment: .leading)
        }
        .background {
            if !embedded {
                AuroraBackground()
            }
        }
        .frame(
            minWidth: embedded ? nil : 620,
            idealWidth: embedded ? nil : 760,
            minHeight: embedded ? nil : 600,
            idealHeight: embedded ? nil : 680
        )
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
        .task {
            await healthViewModel.loadPersistedState()
            await permissionViewModel.refresh()
        }
        // SC-7：用户在系统设置授五回到本页时，权限状态立即回到真实值，不留过期结论
        //（只查询，不申请、不跳转）。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissionViewModel.refresh() }
        }
        .sheet(isPresented: $showsPrivacy) {
            PrivacyView()
                .frame(minWidth: 720, minHeight: 560)
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true)
        )
    }

    // MARK: - 空间变化记录（SC-PD2：启停＋二段确认清除＋与真实持久字段一致的隐私说明）

    @ViewBuilder
    private var spaceChangeSection: some View {
        Toggle("记录空间分析的变化", isOn: $settings.spaceChangeRecordingEnabled)
            .accessibilityHint("关闭只停止新增记录，不删除既有记录，也不会触发扫描")
        Divider()
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("已保留 \(spaceChangeHistory.snapshotCount.formatted()) 条记录")
                Text("最多保留最近 30 条且不超过 90 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if spaceChangeHistory.condition != .ready {
                    Text(spaceChangeStoreConditionText)
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                }
                if spaceChangeClearFailed {
                    Text("清除失败：记录未被删除，可重试。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.danger)
                        .accessibilityLabel("清除失败提示")
                        .accessibilityValue("清除失败，记录未被删除，可重试")
                }
            }
            Spacer()
            Button("清除空间变化记录", systemImage: "trash") {
                spaceChangeClearFailed = false
                showsSpaceChangeClearConfirmation = true
            }
            .buttonStyle(.bordered)
            .disabled(spaceChangeHistory.snapshotCount == 0 && spaceChangeHistory.condition == .ready)
            .accessibilityLabel("清除空间变化记录")
            .accessibilityValue("当前 \(spaceChangeHistory.snapshotCount.formatted()) 条记录")
            .accessibilityHint("需要二次确认；清除后从下一次成功扫描重新开始记录")
        }
        .confirmationDialog(
            "清除全部 \(spaceChangeHistory.snapshotCount.formatted()) 条空间变化记录？",
            isPresented: $showsSpaceChangeClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认清除", role: .destructive) {
                if spaceChangeHistory.clear() == .failed {
                    spaceChangeClearFailed = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销。清除后将从下一次成功扫描重新开始记录。")
        }
        InformationDisclosure(
            title: String(localized: "记录了什么"),
            summary: String(localized: "只保存类别统计与匿名范围标识"),
            symbol: "lock.shield",
            tint: AppTheme.accent
        ) {
            Text("变化记录只保存在本机应用自身的 Application Support 目录，包含：加盐后的匿名范围标识、七个类别各自的容量与条目数、扫描完成时间、覆盖与精度标志、记录格式与规则版本号。不保存任何路径、文件名、目录名、应用名或文件清单；不联网、不上传。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("空间变化记录隐私说明")
                .accessibilityValue("变化记录只保存在本机应用自身的 Application Support 目录，包含：加盐后的匿名范围标识、七个类别各自的容量与条目数、扫描完成时间、覆盖与精度标志、记录格式与规则版本号。不保存任何路径、文件名、目录名、应用名或文件清单；不联网、不上传。")
        }
    }

    private var spaceChangeStoreConditionText: String {
        switch spaceChangeHistory.condition {
        case .ready:
            ""
        case .corrupt:
            String(localized: "历史记录文件无法读取或校验失败；原文件已保留，可在确认后清除并重新开始。")
        case .migrationFailed:
            String(localized: "记录由更新版本的 Sin Clean 生成，本版本无法安全读取；原文件已保留，可在确认后清除。")
        case .saltMissing:
            String(localized: "本地随机盐缺失，无法核对范围可比性；记录文件已保留，可在确认后清除并重新开始。")
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .cardSurface()
    }
}

#if DEBUG
#Preview("设置") {
    SettingsView(healthViewModel: SystemHealthDashboardViewModel.isolatedPreview())
        .environmentObject(AppSettings())
        .environmentObject(SystemNotificationDelivery(scheduler: InertNotificationScheduler()))
        .environmentObject(IgnoreListStore(repository: InMemoryIgnoreRuleRepository(), autoload: false))
        .environmentObject(SpaceChangeHistoryStore(
            fileAccess: LocalSpaceChangeFileAccess(),
            paths: SpaceChangeStoragePaths(
                baseDirectory: URL(fileURLWithPath: "/tmp/scpd2-settings-preview", isDirectory: true)
            )
        ))
}
#endif
