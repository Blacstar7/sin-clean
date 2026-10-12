#if DEBUG
import SwiftUI

struct SC24OperationHistoryPreview: View {
    enum Mode: String, CaseIterable, Identifiable {
        case mixed = "混合记录与详情"
        case empty = "空记录"
        case migrationWarning = "迁移告警"
        case failed = "加载失败"

        var id: Self { self }
    }

    @State private var mode: Mode = .mixed

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                Picker("SC-2.4 预览状态", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
                .padding(.top, AppTheme.Spacing.md)
                .accessibilityLabel("SC-2.4 预览状态")

                SC24OperationHistoryPreviewScene(mode: mode)
                    .id(mode)
            }
        }
        .tint(AppTheme.accent)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

private struct SC24OperationHistoryPreviewScene: View {
    let mode: SC24OperationHistoryPreview.Mode
    private let store: InMemoryOperationHistoryStore

    init(mode: SC24OperationHistoryPreview.Mode) {
        self.mode = mode
        switch mode {
        case .mixed:
            store = InMemoryOperationHistoryStore(
                entries: SC24OperationHistoryFixtures.mixedRecords,
                notices: ["已迁移 1 条旧版清理摘要；逐项详情不可用。"]
            )
        case .empty:
            store = InMemoryOperationHistoryStore(entries: [])
        case .migrationWarning:
            store = InMemoryOperationHistoryStore(
                entries: [],
                notices: ["旧版清理记录损坏或无法解码：DEBUG 注入的损坏旧文件"]
            )
        case .failed:
            store = InMemoryOperationHistoryStore(
                entries: [],
                loadError: "DEBUG 注入：统一存储内容无法解码"
            )
        }
    }

    var body: some View {
        OperationHistoryView(store: store, trashOpener: DisabledTrashOpener())
    }
}

private enum SC24OperationHistoryFixtures {
    static let mixedRecords: [OperationHistoryRecord] = {
        do {
            let now = Date(timeIntervalSince1970: 1_789_318_800)
            let cleanupPlan = try cleanupPlan(frozenAt: now.addingTimeInterval(-8))
            let cleanupResults: [(ExecutionReceiptItemStatus, ExecutionResultReasonCode, String, Int64)] = [
                (.succeeded, .movedToTrash, "已移入废纸篓", 768),
                (.failed, .movePermissionDenied, "Finder 拒绝移动该文件", 0),
                (.skipped, .identityChanged, "文件身份已变化，已跳过", 0),
                (.aborted, .userCancelledAtBoundary, "用户在项目边界停止", 0),
                (.notExecuted, .notExecutedAfterUserCancellation, "中止后的项目未执行", 0)
            ]
            let cleanupReceipt = try ExecutionReceiptBuilder().build(
                plan: cleanupPlan,
                resultSet: ExecutionResultSet(
                    domain: .cleanup,
                    startedAt: now.addingTimeInterval(-6),
                    completedAt: now,
                    wasUserAborted: true,
                    items: zip(cleanupPlan.items, cleanupResults).map { item, result in
                        ExecutionItemResult(
                            itemID: item.id,
                            order: item.order,
                            originalPath: item.identity.originalPath,
                            status: result.0,
                            reasonCode: result.1,
                            reasonText: result.2,
                            actualBytes: result.3
                        )
                    }
                ),
                receiptID: UUID(uuidString: "24000000-0000-0000-0000-000000000001")!
            )
            let cleanupRecord = try OperationHistoryRecord.completed(
                plan: cleanupPlan,
                receipt: cleanupReceipt,
                title: "磁盘清理"
            )

            let uninstallPlan = try uninstallPlan(frozenAt: now.addingTimeInterval(-90))
            let uninstallReceipt = try ExecutionReceiptBuilder().build(
                plan: uninstallPlan,
                resultSet: ExecutionResultSet(
                    domain: .uninstall,
                    startedAt: now.addingTimeInterval(-88),
                    completedAt: now.addingTimeInterval(-80),
                    wasUserAborted: false,
                    items: uninstallPlan.items.map { item in
                        ExecutionItemResult(
                            itemID: item.id,
                            order: item.order,
                            originalPath: item.identity.originalPath,
                            status: .succeeded,
                            reasonCode: .movedToTrash,
                            reasonText: "已移入废纸篓",
                            actualBytes: item.estimatedBytes
                        )
                    }
                ),
                receiptID: UUID(uuidString: "24000000-0000-0000-0000-000000000002")!
            )
            let uninstallRecord = try OperationHistoryRecord.completed(
                plan: uninstallPlan,
                receipt: uninstallReceipt,
                title: "Aurora Notes"
            )

            let legacy = OperationHistoryRecord(
                id: UUID(uuidString: "24000000-0000-0000-0000-000000000003")!,
                planID: nil,
                receiptID: nil,
                domain: OperationPlanDomain.cleanup.rawValue,
                completedAt: now.addingTimeInterval(-160),
                summary: OperationHistorySummarySnapshot(
                    title: "旧版磁盘清理",
                    statusCounts: OperationHistoryStatusCounts(
                        succeeded: 7,
                        failed: 1,
                        skipped: nil,
                        aborted: 0,
                        notExecuted: nil
                    ),
                    actualSucceededBytes: 1_572_864,
                    wasUserAborted: false
                ),
                detailAvailability: .legacySummaryOnly,
                detailMessage: "旧版摘要，详情不可用。旧存储没有逐项计划或执行结果，因此没有补造路径、状态或收据。",
                plan: nil,
                receipt: nil
            )
            return [cleanupRecord, uninstallRecord, legacy]
        } catch {
            assertionFailure("SC-2.4 preview fixture failed: \(error)")
            return []
        }
    }()

    private static func cleanupPlan(frozenAt: Date) throws -> OperationPlan {
        let context = ScanContext()
        let candidates = (0..<5).map { index in
            let names = ["a-success.cache", "b-failed.cache", "c-skipped.cache", "d-aborted.cache", "e-pending.cache"]
            return CleanupFileCandidate(
                id: "preview-cleanup-\(index)",
                locationID: "user-caches",
                rootPath: "/Users/preview/Library/Caches",
                path: "/Users/preview/Library/Caches/\(names[index])",
                allocatedBytes: index == 0 ? 768 : Int64((index + 1) * 1_024),
                logicalBytes: index == 0 ? 700 : Int64((index + 1) * 900),
                modifiedAt: frozenAt.addingTimeInterval(-60),
                modifiedSeconds: Int64(frozenAt.timeIntervalSince1970) - 60,
                modifiedNanoseconds: Int64(index),
                deviceID: 1,
                inode: UInt64(2_400 + index),
                risk: .review,
                evidenceOrigin: CandidateEvidenceOrigin(
                    context: context,
                    scopeID: "cleanup:user-caches",
                    reasonCode: .userCaches
                )
            )
        }
        let frozen = try OperationPlanBuilder().freezeCleanup(
            candidates: candidates,
            coverageRecords: [],
            planID: UUID(uuidString: "24000000-0000-0000-0000-000000000011")!,
            frozenAt: frozenAt
        )
        return frozen.plan
    }

    private static func uninstallPlan(frozenAt: Date) throws -> OperationPlan {
        let context = ScanContext()
        let bundleID = "com.example.aurora-notes"
        let application = InstalledApplication(
            id: "preview-application",
            name: "Aurora Notes",
            path: "/Applications/Aurora Notes.app",
            rootPath: "/Applications",
            bundleIdentifier: bundleID,
            version: "3.2",
            buildNumber: "42",
            allocatedBytes: 8_388_608,
            logicalBytes: 8_000_000,
            modifiedSeconds: Int64(frozenAt.timeIntervalSince1970) - 120,
            modifiedNanoseconds: 42,
            deviceID: 1,
            inode: 3_001,
            signatureState: .valid,
            signer: "Developer ID Application: Example",
            teamIdentifier: "EXAMPLE",
            evidenceOrigin: CandidateEvidenceOrigin(
                context: context,
                scopeID: "applications:system",
                reasonCode: .applicationDirectory
            )
        )
        let residue = AppResidueCandidate(
            id: "preview-residue",
            bundleIdentifier: bundleID,
            kind: .cache,
            path: "/Users/preview/Library/Caches/\(bundleID)",
            rootPath: "/Users/preview/Library/Caches",
            allocatedBytes: 524_288,
            logicalBytes: 500_000,
            modifiedSeconds: Int64(frozenAt.timeIntervalSince1970) - 100,
            modifiedNanoseconds: 7,
            deviceID: 1,
            inode: 3_002,
            isDirectory: true,
            matchReason: "Bundle Identifier 精确匹配固定缓存路径",
            evidenceOrigin: CandidateEvidenceOrigin(
                context: context,
                scopeID: "residue:cache",
                reasonCode: .residueCache,
                matchedValue: bundleID
            )
        )
        return try OperationPlanBuilder().freezeUninstall(
            application: application,
            residues: [residue],
            coverageRecords: [],
            planID: UUID(uuidString: "24000000-0000-0000-0000-000000000012")!,
            frozenAt: frozenAt
        ).plan
    }
}
#endif
