#if DEBUG
import Foundation
import SwiftUI

/// A DEBUG-only, pure-memory execution simulator. It accepts frozen plans and
/// returns scripted strong-typed results without touching scanners, Finder,
/// Quick Look, production executors, Trash APIs, or the file system.
private struct SC23MemoryExecutionSimulator: Sendable {
    func cleanupResults(for plan: OperationPlan) -> ExecutionResultSet {
        let startedAt = plan.frozenAt.addingTimeInterval(1)
        let script: [(ExecutionReceiptItemStatus, ExecutionResultReasonCode, String)] = [
            (.succeeded, .movedToTrash, "已通过执行前复验并移入废纸篓。"),
            (.failed, .moveSystemFailure, "安全复验已通过，但系统移动操作失败。"),
            (.skipped, .identityChanged, "deviceID 或 inode 与扫描时不同，为避免处理替换后的文件而跳过。"),
            (.skipped, .pathChanged, "执行前无法在原始完整路径找到同一项目，路径状态已变化。"),
            (.aborted, .userCancelledAtBoundary, "在处理此项目之前观察到用户取消，未尝试移动。"),
            (.notExecuted, .notExecutedAfterUserCancellation, "因前序用户中止，本项目没有执行。")
        ]
        let items = zip(plan.items, script).map { item, scripted in
            ExecutionItemResult(
                itemID: item.id,
                order: item.order,
                originalPath: item.identity.originalPath,
                status: scripted.0,
                reasonCode: scripted.1,
                reasonText: scripted.2,
                actualBytes: scripted.0 == .succeeded ? item.estimatedBytes : 0
            )
        }
        return ExecutionResultSet(
            domain: .cleanup,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(3),
            wasUserAborted: true,
            items: items
        )
    }

    func uninstallResults(for plan: OperationPlan) -> ExecutionResultSet {
        let startedAt = plan.frozenAt.addingTimeInterval(1)
        let items = plan.items.map { item in
            if item.order == 0 {
                return ExecutionItemResult(
                    itemID: item.id,
                    order: item.order,
                    originalPath: item.identity.originalPath,
                    status: .skipped,
                    reasonCode: .bundleIdentifierChanged,
                    reasonText: "应用 Bundle Identifier 与冻结计划不一致；应用本体保留。",
                    actualBytes: 0
                )
            }
            return ExecutionItemResult(
                itemID: item.id,
                order: item.order,
                originalPath: item.identity.originalPath,
                status: .notExecuted,
                reasonCode: .notExecutedAfterApplicationFailure,
                reasonText: "应用本体未成功移入废纸篓，按照卸载边界，本残留保持不动且未执行。",
                actualBytes: 0
            )
        }
        return ExecutionResultSet(
            domain: .uninstall,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(2),
            wasUserAborted: false,
            items: items
        )
    }
}

struct SC23ExecutionReceiptPreview: View {
    private enum Domain: String, CaseIterable, Identifiable {
        case cleanup = "磁盘清理"
        case uninstall = "应用卸载"

        var id: Self { self }
    }

    @State private var domain: Domain = .cleanup
    private let cleanupReceipt: ExecutionReceipt
    private let uninstallReceipt: ExecutionReceipt

    init() {
        let plans = Self.makePlans()
        let simulator = SC23MemoryExecutionSimulator()
        let builder = ExecutionReceiptBuilder()
        do {
            cleanupReceipt = try builder.build(
                plan: plans.cleanup,
                resultSet: simulator.cleanupResults(for: plans.cleanup),
                receiptID: UUID(uuidString: "23000000-0000-0000-0000-000000000001")!
            )
            uninstallReceipt = try builder.build(
                plan: plans.uninstall,
                resultSet: simulator.uninstallResults(for: plans.uninstall),
                receiptID: UUID(uuidString: "23000000-0000-0000-0000-000000000002")!
            )
        } catch {
            preconditionFailure("SC-2.3 preview fixture is invalid: \(error)")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("SC-2.3 执行收据 · 纯内存预览")
                        .font(.headline)
                    Text("结果由内存模拟执行器产生；未运行扫描器、真实执行器、Finder、Quick Look 或废纸篓 API。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("预览领域", selection: $domain) {
                    ForEach(Domain.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                .accessibilityLabel("切换执行收据预览领域")
                .accessibilityHint("在磁盘清理和应用卸载执行收据之间切换")
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md)
            .background(AppTheme.cardSurface)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                        Image(systemName: domain == .cleanup ? "doc.text.fill" : "exclamationmark.shield.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(AppTheme.warning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text(domain == .cleanup ? "清理执行已中止，已有逐项结果" : "应用身份复验未通过，残留保持不动")
                                .font(.title2.bold())
                            Text(domain == .cleanup
                                 ? "身份变化与路径变化使用不同原因代码；中止后的项目明确标记为未执行。"
                                 : "应用本体是第一项；本体未成功时，所有残留均未尝试。")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)

                    ExecutionReceiptSummaryView(
                        receipt: domain == .cleanup ? cleanupReceipt : uninstallReceipt
                    )
                }
                .liquidGlassSurface(tint: AppTheme.warning)
                .padding(AppTheme.Spacing.xl)
                .frame(maxWidth: 1_180)
                .frame(maxWidth: .infinity)
            }
        }
        .background(AuroraBackground())
        .preferredColorScheme(.dark)
    }

    private static func makePlans() -> (cleanup: OperationPlan, uninstall: OperationPlan) {
        let frozenAt = Date(timeIntervalSince1970: 1_800_200_000)
        let context = ScanContext()
        let cleanupRoot = "/Users/preview/Library/Caches"
        let modifiedSeconds = Int64(frozenAt.timeIntervalSince1970) - 3600
        var cleanupCandidates: [CleanupFileCandidate] = []
        for index in 0..<6 {
            let path = cleanupRoot + "/com.example.preview/item-" + String(index) + ".cache"
            let candidate = CleanupFileCandidate(
                id: "sc23-cleanup-\(index)",
                locationID: "user-caches",
                rootPath: cleanupRoot,
                path: path,
                allocatedBytes: Int64(index + 1) * 4_194_304,
                logicalBytes: Int64(index + 1) * 4_000_000,
                modifiedAt: frozenAt.addingTimeInterval(-3600),
                modifiedSeconds: modifiedSeconds,
                modifiedNanoseconds: Int64(index) * 1_000,
                deviceID: 1,
                inode: UInt64(23_000 + index),
                risk: .review,
                evidenceOrigin: CandidateEvidenceOrigin(
                    context: context,
                    scopeID: "disk:user-caches",
                    reasonCode: .userCaches
                )
            )
            cleanupCandidates.append(candidate)
        }

        let applicationContext = ScanContext()
        let bundleIdentifier = "com.example.ExecutionReceiptPreview"
        let application = InstalledApplication(
            id: "sc23-preview-application",
            name: "Receipt Preview",
            path: "/Applications/Receipt Preview.app",
            rootPath: "/Applications",
            bundleIdentifier: bundleIdentifier,
            version: "2.3",
            buildNumber: "230",
            allocatedBytes: 125_829_120,
            logicalBytes: 130_000_000,
            modifiedSeconds: Int64(frozenAt.timeIntervalSince1970) - 7200,
            modifiedNanoseconds: 230,
            deviceID: 1,
            inode: 24_000,
            signatureState: .valid,
            signer: "Developer ID Application: Preview Studio",
            teamIdentifier: "PREVIEWTEAM",
            evidenceOrigin: CandidateEvidenceOrigin(
                context: applicationContext,
                scopeID: "application:/Applications",
                reasonCode: .applicationDirectory,
                matchedValue: ".app"
            )
        )
        let residueContext = ScanContext()
        let kinds: [AppResidueKind] = [.cache, .logs, .preferences]
        var residues: [AppResidueCandidate] = []
        for (index, kind) in kinds.enumerated() {
            let root = index == 2 ? "/Users/preview/Library/Preferences" : "/Users/preview/Library/\(index == 0 ? "Caches" : "Logs")"
            let suffix = kind == .preferences ? "\(bundleIdentifier).plist" : bundleIdentifier
            let residue = AppResidueCandidate(
                id: "sc23-residue-\(index)",
                bundleIdentifier: bundleIdentifier,
                kind: kind,
                path: "\(root)/\(suffix)",
                rootPath: root,
                allocatedBytes: Int64(index + 1) * 2_097_152,
                logicalBytes: Int64(index + 1) * 2_000_000,
                modifiedSeconds: Int64(frozenAt.timeIntervalSince1970) - 86_400,
                modifiedNanoseconds: Int64(index) * 2_000,
                deviceID: 1,
                inode: UInt64(25_000 + index),
                isDirectory: kind != .preferences,
                matchReason: "固定路径与 Bundle Identifier 精确匹配",
                evidenceOrigin: CandidateEvidenceOrigin(
                    context: residueContext,
                    scopeID: kind.evidenceRule.rawValue,
                    reasonCode: kind.evidenceRule,
                    matchedValue: bundleIdentifier
                )
            )
            residues.append(residue)
        }

        do {
            let builder = OperationPlanBuilder()
            let cleanup = try builder.freezeCleanup(
                candidates: cleanupCandidates,
                coverageRecords: [],
                planID: UUID(uuidString: "21000000-0000-0000-0000-000000000001")!,
                frozenAt: frozenAt
            ).plan
            let uninstall = try builder.freezeUninstall(
                application: application,
                residues: residues,
                coverageRecords: [],
                planID: UUID(uuidString: "21000000-0000-0000-0000-000000000002")!,
                frozenAt: frozenAt
            ).plan
            return (cleanup, uninstall)
        } catch {
            preconditionFailure("SC-2.3 plan fixture is invalid: \(error)")
        }
    }
}
#endif
