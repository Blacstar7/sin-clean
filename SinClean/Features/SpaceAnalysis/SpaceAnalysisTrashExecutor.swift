import AppKit
import Darwin
import Foundation

// 废纸篓移动复用既有抽象 `TrashMoving` 与生产实现 `SystemTrashMover`
// （SinClean/Core/CleanupExecutor.swift，SC-1 起冻结）。本文件不新增任何破坏性调用点：
// 全工程对系统废纸篓的实际调用仍然只有那一处，测试可注入假实现断言调用与跳过。

/// SC-3.5 执行器。
///
/// 安全边界（见 work/SC-3.5-frozen-semantics.md 第六节）：
/// - 每一项在执行前都必须通过既有 `ExecutionSafetyCore.validateCleanup` 复验；
///   适配层只做字段搬运，不复制、不重写、不旁路任何校验逻辑；
/// - 唯一的破坏性动作是移入系统废纸篓，且只经由既有 `SystemTrashMover`；
///   全文不得出现 `unlink`／`removeItem`／`rmdir`；
/// - 单项失败不中断整轮，也不改变其他项的状态。
actor SpaceAnalysisTrashExecutor {
    private let mover: any TrashMoving

    init(mover: any TrashMoving = SystemTrashMover()) {
        self.mover = mover
    }

    func execute(
        plan: SpaceAnalysisTrashPlan,
        progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async -> SpaceAnalysisTrashReceipt {
        let startedAt = Date()
        var items: [SpaceAnalysisTrashReceiptItem] = []
        var cancelled = false

        for (index, item) in plan.items.enumerated() {
            if Task.isCancelled {
                cancelled = true
                items.append(SpaceAnalysisTrashReceiptItem(
                    path: item.path,
                    displayName: item.displayName,
                    reasonCode: ExecutionResultReasonCode.notExecutedAfterUserCancellation.rawValue,
                    text: String(localized: "已取消，该项未执行。"),
                    bytes: item.allocatedBytes,
                    movedToTrash: false,
                    finishedAt: Date()
                ))
                continue
            }
            items.append(await move(item: item, allowedRootPaths: plan.allowedRootPaths))
            await progress(index + 1, plan.items.count)
        }

        return SpaceAnalysisTrashReceipt(
            planFrozenAt: plan.frozenAt,
            startedAt: startedAt,
            finishedAt: Date(),
            items: items,
            cancelled: cancelled
        )
    }

    private func move(
        item: SpaceAnalysisTrashPlanItem,
        allowedRootPaths: Set<String>
    ) async -> SpaceAnalysisTrashReceiptItem {
        // 复用既有安全核心做执行前复验。适配层只搬运字段：身份与元数据一律取自冻结快照。
        let candidate = CleanupFileCandidate(
            id: item.path,
            locationID: item.rootPath,
            rootPath: item.rootPath,
            path: item.path,
            allocatedBytes: item.allocatedBytes,
            logicalBytes: item.logicalBytes,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(item.modifiedSeconds)),
            modifiedSeconds: item.modifiedSeconds,
            modifiedNanoseconds: item.modifiedNanoseconds,
            deviceID: item.deviceID,
            inode: item.inode,
            risk: .caution,
            evidenceOrigin: CandidateEvidenceOrigin(
                context: ScanContext(),
                scopeID: item.rootPath,
                reasonCode: .configuredRegularFiles
            )
        )

        if let failure = ExecutionSafetyCore.validateCleanup(candidate, allowedRootPaths: allowedRootPaths) {
            return SpaceAnalysisTrashReceiptItem(
                path: item.path,
                displayName: item.displayName,
                reasonCode: failure.code.rawValue,
                text: failure.text,
                bytes: item.allocatedBytes,
                movedToTrash: false,
                finishedAt: Date()
            )
        }

        do {
            try mover.moveToTrash(URL(fileURLWithPath: item.path))
            return SpaceAnalysisTrashReceiptItem(
                path: item.path,
                displayName: item.displayName,
                reasonCode: ExecutionResultReasonCode.movedToTrash.rawValue,
                text: item.isDatalessPlaceholder
                    ? String(localized: "已移入废纸篓；如需恢复，请在访达的废纸篓中放回原处。该项移动前是云端占位文件，移动过程可能已触发下载或占用额外空间。")
                    : String(localized: "已移入废纸篓；如需恢复，请在访达的废纸篓中放回原处。"),
                bytes: item.allocatedBytes,
                movedToTrash: true,
                finishedAt: Date()
            )
        } catch {
            let failure = ExecutionSafetyCore.moveFailure(error as NSError)
            return SpaceAnalysisTrashReceiptItem(
                path: item.path,
                displayName: item.displayName,
                reasonCode: failure.code.rawValue,
                text: failure.text,
                bytes: item.allocatedBytes,
                movedToTrash: false,
                finishedAt: Date()
            )
        }
    }
}
