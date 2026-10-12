import Foundation
import SwiftUI

// SC-5 权限状态视图模型：状态来自实时查询（§4），覆盖事实来自最近一次扫描结果。
@MainActor
final class PermissionStatusViewModel: ObservableObject {
    @Published private(set) var snapshot: PermissionStatusSnapshot = .unknown
    @Published private(set) var coverage: PermissionCoverage = .none
    @Published private(set) var lastQueriedAt: Date?

    private let probe: any PermissionStatusProbing

    init(probe: any PermissionStatusProbing = SystemPermissionProbe()) {
        self.probe = probe
    }

    /// 只查询，不申请。
    func refresh() async {
        snapshot = await probe.snapshot()
        lastQueriedAt = Date()
    }

    /// 覆盖事实来自真实的扫描结果（未统计目录数与是否完整完成），不是猜测。
    func updateCoverage(hasScanResult: Bool, unreadableDirectoryCount: Int, scanCompleted: Bool = true) {
        coverage = PermissionCoverage(
            unreadableDirectoryCount: unreadableDirectoryCount,
            hasScanResult: hasScanResult,
            scanCompleted: scanCompleted
        )
    }
}

// SC-5 隐私页（§5）：每条声明对应可验证事实与自行验证方法；本页不含任何申请权限的按钮。
struct PrivacyView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("隐私说明")
                        .font(.largeTitle.bold())
                    Text("每一条声明都对应一个可以自行验证的事实。本页只作说明，不会申请任何权限。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(PrivacyDisclosure.claims) { claim in
                    claimCard(claim)
                }
            }
            .padding(AppTheme.Spacing.xl)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .background(.clear)
        .accessibilityElement(children: .contain)
    }

    private func claimCard(_ claim: PrivacyClaim) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("可验证事实")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(claim.verifiableFact)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("如何自行验证")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(claim.howToVerify)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, AppTheme.Spacing.sm)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(claim.claim)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("查看事实与验证方法")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("隐私声明 \(claim.claim)")
        .accessibilityValue("可验证事实：\(claim.verifiableFact) 如何自行验证：\(claim.howToVerify)")
    }

    private var surfaceStyle: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(AppTheme.obsidian) : AnyShapeStyle(.ultraThinMaterial)
    }
}
