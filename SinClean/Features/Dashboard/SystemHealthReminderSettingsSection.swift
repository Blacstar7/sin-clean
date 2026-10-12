import AppKit
import SwiftUI

// SC-4 设置页区块：提醒开关（四类，默认关闭）与趋势数据清空（二次确认）。
// 口径见 work/SC-4-frozen-semantics.md §5 与 §7。
// SC-7 通知权限生产接线（work/SC-7-notification-wiring-rework-20261001/）：
// 开启任一提醒类别且系统尚未授权时，先给冻结三句说明（SC-5 §3.4）再申请；可取消；
// 已拒绝／不可确认分流处理；开关只代表用户偏好，授权状态永远来自实时查询。

struct SystemHealthReminderSettingsSection: View {
    @ObservedObject var viewModel: SystemHealthDashboardViewModel
    @ObservedObject var delivery: SystemNotificationDelivery
    @ObservedObject var permissionStatus: PermissionStatusViewModel
    @State private var showingClearConfirmation = false
    /// 开关分流的待处理类别：说明确认前不写偏好。
    @State private var pendingKind: SystemHealthReminderKind?
    @State private var gateDialog: GateDialog?

    init(
        viewModel: SystemHealthDashboardViewModel,
        delivery: SystemNotificationDelivery = SystemNotificationDelivery(scheduler: InertNotificationScheduler()),
        permissionStatus: PermissionStatusViewModel? = nil
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _delivery = ObservedObject(wrappedValue: delivery)
        _permissionStatus = ObservedObject(wrappedValue: permissionStatus ?? PermissionStatusViewModel())
    }

    /// 申请前说明弹窗的四态（尚未决定／已拒绝／不可确认各走各的路径），
    /// 以及申请后仍未取得决定的第五种呈现。
    private enum GateDialog: Equatable {
        case beforeRequest
        case deniedRestriction
        case unconfirmed
        case undecidedAfterRequest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("系统健康提醒")
                    .font(.headline)
                Text("默认关闭；开启后只依据持续状态触发，系统不会静默关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ForEach(SystemHealthReminderKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { viewModel.preferences.isEnabled(kind) },
                        set: { handleReminderToggle($0, kind: kind) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .font(.callout)
                            Text(kind.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityLabel("开启\(kind.title)")
                    .accessibilityValue(viewModel.preferences.isEnabled(kind) ? "已开启" : "已关闭")
                    .accessibilityHint("落点为\(kind.target.title)；不会指向清缓存")
                }
            }

            // 已拒绝时的限制说明：状态来自实时查询，回到本应用会自动刷新；
            // 跳转系统设置只发生在用户点击时。
            if showsDeniedRestrictionNotice {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(AppTheme.warning)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("通知权限未授权：已开启的提醒仍会显示在本应用内，但不会弹出系统通知。")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("打开系统设置") {
                            openNotificationSettings()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("打开系统设置的通知页")
                        .accessibilityHint("只在您点击时跳转系统设置；应用不会自动跳转")
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("通知权限未授权说明")
                .accessibilityValue("已开启的提醒仍会显示在本应用内，但不会弹出系统通知；可打开系统设置开启通知")
            }

            Divider()

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("趋势数据")
                    .font(.headline)
                InformationDisclosure(
                    title: String(localized: "本机存储"),
                    summary: String(localized: "\(viewModel.trends.totalPointCount.formatted()) 个采样点，不写入任何网络端点"),
                    symbol: "internaldrive",
                    tint: AppTheme.accent
                ) {
                    Text("趋势数据只保存在本机，不写入任何网络端点。当前存储位置：\(viewModel.storageLocation)。当前采样点合计 \(viewModel.trends.totalPointCount.formatted()) 个。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("趋势数据存储说明")
                        .accessibilityValue("只保存在本机，不写入任何网络端点；当前 \(viewModel.trends.totalPointCount.formatted()) 个采样点")
                }

                Button("清空趋势数据", systemImage: "trash.slash") {
                    showingClearConfirmation = true
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("清空趋势数据")
                .accessibilityValue(viewModel.trends.totalPointCount == 0 ? "当前没有采样点" : "将清空 \(viewModel.trends.totalPointCount.formatted()) 个采样点")
                .accessibilityHint("清空后趋势数据变为零采样点且不可撤销；不会删除任何用户文件")

                // SC-4 R2：清空与采样持久化失败的可观察反馈（复用空间变化记录的失败提示模式）。
                if viewModel.trendClearFailed {
                    Text("清空失败：趋势数据未被删除，可重试。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.danger)
                        .accessibilityLabel("趋势清空失败提示")
                        .accessibilityValue("清空失败，趋势数据未被删除，可重试")
                }
                if viewModel.trendPersistDegraded {
                    Text("最近一次采样未成功保存到本机；重启后趋势将缺少该采样点。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .accessibilityLabel("趋势采样保存失败提示")
                        .accessibilityValue("最近一次采样未成功保存到本机；重启后趋势将缺少该采样点")
                }
            }
        }
        .confirmationDialog(
            "清空趋势数据？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空趋势数据", role: .destructive) {
                viewModel.clearTrends()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把本机趋势文档重写为零采样点。该操作不可撤销，但不会删除任何用户文件。")
        }
        .alert(
            gateTitle,
            isPresented: Binding(
                get: { gateDialog != nil },
                set: { if !$0 { gateDialog = nil } }
            )
        ) {
            gateActions
        } message: {
            Text(gateMessage)
        }
        // 出现与回到前台时重新查询实际系统状态：撤回授权后说明行随之消失或出现，
        // 不残留任何过期结论（只查询，不申请）。
        .task { await refreshNotificationState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationState() }
        }
    }

    // MARK: - 开关分流（SC-7）

    /// 关闭是用户主动行为，直接生效；开启先按实时授权决策分流。
    private func handleReminderToggle(_ newValue: Bool, kind: SystemHealthReminderKind) {
        guard newValue else {
            viewModel.setReminderEnabled(false, for: kind)
            return
        }
        pendingKind = kind
        Task { @MainActor in
            let step = ReminderNotificationGate.step(for: await delivery.currentDecision())
            switch step {
            case .enableDirectly:
                viewModel.setReminderEnabled(true, for: kind)
                pendingKind = nil
            case .explainBeforeRequest:
                gateDialog = .beforeRequest
            case .explainDeniedRestriction:
                gateDialog = .deniedRestriction
            case .explainUnconfirmed:
                gateDialog = .unconfirmed
            case .explainUndecidedAfterRequest:
                // step() 不会在申请前返回该态；若出现也按「未取得决定」如实呈现。
                gateDialog = .undecidedAfterRequest
            }
        }
    }

    @ViewBuilder
    private var gateActions: some View {
        switch gateDialog {
        case .beforeRequest:
            Button("申请通知权限并开启") {
                // 先收起说明弹窗，申请只发生在用户读过三句说明并确认之后。
                gateDialog = nil
                Task { @MainActor in
                    let decision = await delivery.requestAuthorizationForReminders()
                    await permissionStatus.refresh()
                    // 申请后按真实系统状态四态分流（afterRequest）：只有明确拒绝才呈现已拒绝。
                    let step = ReminderNotificationGate.afterRequest(decision)
                    // 等第一个弹窗完成收起后再呈现下一个，避免同一弹窗内容被原地改写。
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    switch step {
                    case .enableDirectly:
                        commitPendingReminder()
                    case .explainDeniedRestriction:
                        gateDialog = .deniedRestriction
                    case .explainUnconfirmed:
                        gateDialog = .unconfirmed
                    case .explainUndecidedAfterRequest:
                        gateDialog = .undecidedAfterRequest
                    case .explainBeforeRequest:
                        // 申请后不可能回到「尚未决定→先说明再申请」的入口态；
                        // 若系统在申请后仍报告尚未决定，按未取得决定如实呈现。
                        gateDialog = .undecidedAfterRequest
                    }
                }
            }
            Button("暂不开启", role: .cancel) {}
        case .deniedRestriction:
            Button("打开系统设置") {
                openNotificationSettings()
            }
            Button("仍要开启（只在本应用内提醒）") {
                commitPendingReminder()
            }
            Button("暂不开启", role: .cancel) {}
        case .unconfirmed:
            Button("仍要开启") {
                commitPendingReminder()
            }
            Button("暂不开启", role: .cancel) {}
        case .undecidedAfterRequest:
            Button("仍要开启（只在本应用内提醒）") {
                commitPendingReminder()
            }
            Button("暂不开启", role: .cancel) {}
        case nil:
            EmptyView()
        }
    }

    private var gateTitle: String {
        switch gateDialog {
        case .beforeRequest: PermissionGuidance.requestButtonTitle(for: .notifications)
        case .deniedRestriction: String(localized: "通知权限已被拒绝")
        case .unconfirmed: String(localized: "无法确认通知授权状态")
        case .undecidedAfterRequest: String(localized: "尚未完成通知授权")
        case nil: ""
        }
    }

    /// 冻结三句说明逐字出现（SC-5 §3.4）；已拒绝／不可确认时先说明各自的限制。
    private var gateMessage: String {
        let kind = SystemPermissionKind.notifications
        let threeSentences = [
            String(localized: "为什么需要：\(kind.reason)"),
            String(localized: "用来做什么：\(kind.usage)"),
            String(localized: "不做会怎样：\(kind.ifNotGranted)")
        ].joined(separator: "\n")
        switch gateDialog {
        case .beforeRequest:
            return threeSentences
        case .deniedRestriction:
            return String(localized: "您此前在系统层面选择了拒绝，本应用不能再次弹出系统申请窗口。可以打开系统设置开启通知；在那之前，提醒只会显示在本应用内。") + "\n\n" + threeSentences
        case .unconfirmed:
            return String(localized: "当前无法确认通知授权状态，且不影响其余功能；本次不申请、不跳转系统设置。") + "\n\n" + threeSentences
        case .undecidedAfterRequest:
            return String(localized: "系统没有记录到您的选择（尚未决定）。本次不会自动再次申请，也不会打开系统设置；可稍后再次开启提醒重新申请。") + "\n\n" + threeSentences
        case nil:
            return ""
        }
    }

    private func commitPendingReminder() {
        if let kind = pendingKind {
            viewModel.setReminderEnabled(true, for: kind)
        }
        pendingKind = nil
    }

    /// 只在用户点击时打开系统设置的通知页；不会自动跳转。
    private func openNotificationSettings() {
        guard let url = URL(string: PermissionGuidance.settingsURL(for: .notifications)) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshNotificationState() async {
        _ = await delivery.currentDecision()
        await permissionStatus.refresh()
    }

    /// 已开启任一类别且最近一次真实查询为已拒绝时，说明限制（不猜测、不缓存）。
    private var showsDeniedRestrictionNotice: Bool {
        delivery.lastDecision == .denied && !viewModel.preferences.enabledKinds.isEmpty
    }
}
