import AppKit
import Combine
import SwiftUI

// SC-5 权限状态可见性（§4）与设置面权限区（§3、§8）。
// 状态来自实时查询；拒绝不阻塞；不得把「无法确认」渲染成「未授权」。

struct PermissionStatusStrip: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var viewModel: PermissionStatusViewModel
    /// 仅在用户主动点击时打开系统设置；本视图不会自动跳转，也不会自动申请。
    let openSettings: (SystemPermissionKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("扫描覆盖与权限")
                    .font(.headline)
                Spacer(minLength: AppTheme.Spacing.sm)
                Text(viewModel.coverage.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("扫描覆盖情况")
                    .accessibilityValue(viewModel.coverage.summary)
                // SC-5.2「重新检测入口」：用户显式入口，只重新查询状态，不申请权限、不跳转系统设置。
                // 另有两条自动路径与文案一致：回到本应用（焦点恢复）与扫描完成时都会重新检测。
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label(PermissionGuidance.recheckButtonTitle, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel(PermissionGuidance.recheckAccessibilityLabel)
                .accessibilityValue(recheckValue)
                .accessibilityHint(PermissionGuidance.recheckAccessibilityHint)
                .help(PermissionGuidance.recheckHelp)
            }

            HStack(spacing: AppTheme.Spacing.md) {
                ForEach(SystemPermissionKind.allCases) { kind in
                    permissionRow(kind)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        // SC-5.2：出现时查询一次；回到本应用（应用重新激活）再查询一次——
        // 都与文案一致，且只查询不申请。此处用 AppKit 的「应用重新激活」通知：
        // macOS 上它比 SwiftUI 的 scenePhase 更可靠地反映「用户从系统设置切回本应用」。
        .task { await viewModel.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.refresh() }
        }
    }

    /// 「重新检测」控件的取值：当前两项权限状态，供无障碍读出。
    private var recheckValue: String {
        SystemPermissionKind.allCases
            .map { String(localized: "\($0.title)：\(viewModel.snapshot.status(of: $0).title)") }
            .joined(separator: String(localized: "；"))
    }

    private func permissionRow(_ kind: SystemPermissionKind) -> some View {
        let status = viewModel.snapshot.status(of: kind)
        return VStack(alignment: .leading, spacing: 2) {
            Text(kind.title)
                .font(.callout.weight(.semibold))
            Text(status.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if status == .denied {
                Button(PermissionGuidance.requestButtonTitle(for: kind)) {
                    openSettings(kind)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(kind.title)：了解如何授权")
                .accessibilityValue(kind.ifNotGranted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("权限状态 \(kind.title)")
        .accessibilityValue("\(status.title)。\(kind.ifNotGranted)")
        .accessibilityHint("权限只在您执行相关操作时才申请；不授权也能继续使用其余功能")
    }

    private var surfaceStyle: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(AppTheme.obsidian) : AnyShapeStyle(.ultraThinMaterial)
    }
}

struct PermissionSettingsSection: View {
    @ObservedObject var viewModel: PermissionStatusViewModel
    let reopenOnboarding: () -> Void
    let openSettings: (SystemPermissionKind) -> Void
    let showPrivacy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("权限")
                    .font(.headline)
                Text("两项权限均为可选，只在相关操作时申请；拒绝不影响其他功能。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(SystemPermissionKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                        Text(kind.title)
                            .font(.callout.weight(.semibold))
                        Text(viewModel.snapshot.status(of: kind).title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Button(PermissionGuidance.requestButtonTitle(for: kind)) {
                            openSettings(kind)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("\(kind.title)：打开系统设置")
                        .accessibilityHint("只在您点击时才跳转系统设置；应用不会自动跳转")
                    }
                    Text(kind.ifNotGranted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("为什么需要与何时申请") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("为什么需要：\(kind.reason)")
                            Text("用来做什么：\(kind.usage)")
                            Text("不做会怎样：\(kind.ifNotGranted)")
                            Text("申请时机：\(kind.trigger)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, AppTheme.Spacing.xs)
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(AppTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("权限说明 \(kind.title)")
                .accessibilityValue("\(viewModel.snapshot.status(of: kind).title)。为什么需要：\(kind.reason) 用来做什么：\(kind.usage) 不做会怎样：\(kind.ifNotGranted)")
            }

            Divider()

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("重新查看首次使用") { reopenOnboarding() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("重新查看首次使用三屏说明")
                    .accessibilityHint("重看不会申请任何权限，也不会改变您的设置")
                Button("查看隐私说明") { showPrivacy() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("打开隐私说明")
                    .accessibilityHint("逐条列出声明与自行验证的方法")
            }
        }
    }
}
