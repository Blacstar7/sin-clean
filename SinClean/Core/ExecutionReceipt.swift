import Foundation

/// Receipt-only adaptive capacity formatting. Positive values below one KiB round up to 1 KB,
/// so a successful non-empty item is never announced as zero.
enum ExecutionReceiptCapacityFormatter: Sendable {
    static func string(fromByteCount byteCount: Int64) -> String {
        guard byteCount > 0 else { return "0 KB" }

        let kibibyte = 1_024.0
        let units: [(threshold: Double, divisor: Double, suffix: String)] = [
            (kibibyte * kibibyte * kibibyte * kibibyte, kibibyte * kibibyte * kibibyte * kibibyte, "TB"),
            (kibibyte * kibibyte * kibibyte, kibibyte * kibibyte * kibibyte, "GB"),
            (kibibyte * kibibyte, kibibyte * kibibyte, "MB"),
            (kibibyte, kibibyte, "KB")
        ]
        let bytes = Double(byteCount)
        guard let unit = units.first(where: { bytes >= $0.threshold }) else {
            return "1 KB"
        }
        let scaled = bytes / unit.divisor
        let rounded = (scaled * 100).rounded() / 100
        let number: String
        if rounded.rounded() == rounded {
            number = String(format: "%.0f", rounded)
        } else if (rounded * 10).rounded() == rounded * 10 {
            number = String(format: "%.1f", rounded)
        } else {
            number = String(format: "%.2f", rounded)
        }
        return "\(number) \(unit.suffix)"
    }
}

enum ExecutionReceiptItemStatus: String, CaseIterable, Hashable, Sendable {
    case succeeded
    case failed
    case skipped
    case aborted
    case notExecuted
}

enum ExecutionResultReasonCode: String, Hashable, Sendable {
    case movedToTrash = "execution.movedToTrash"

    case movePermissionDenied = "execution.move.permissionDenied"
    case moveSystemFailure = "execution.move.systemFailure"

    case pathOutsideAllowedRoot = "execution.skip.pathOutsideAllowedRoot"
    case pathChanged = "execution.skip.pathChanged"
    case symbolicLinkDetected = "execution.skip.symbolicLinkDetected"
    case fileTypeChanged = "execution.skip.fileTypeChanged"
    case identityChanged = "execution.skip.identityChanged"
    case metadataChanged = "execution.skip.metadataChanged"
    case validationPermissionDenied = "execution.skip.validationPermissionDenied"
    case bundleIdentifierInvalid = "execution.skip.bundleIdentifierInvalid"
    case bundleIdentifierChanged = "execution.skip.bundleIdentifierChanged"
    case applicationStillRunning = "execution.skip.applicationStillRunning"
    case residueRuleMismatch = "execution.skip.residueRuleMismatch"

    /// A typed fail-closed marker used only when executor observations cannot be
    /// reconciled without guessing from localized text. Receipt construction rejects it.
    case unknownExecutorResult = "execution.unknown.executorResult"

    case userCancelledAtBoundary = "execution.abort.userCancelledAtBoundary"
    case notExecutedAfterUserCancellation = "execution.notExecuted.userCancellation"
    case notExecutedAfterApplicationFailure = "execution.notExecuted.applicationFailure"
    case uninstallApplicationMissing = "execution.notExecuted.applicationMissing"
}

struct ExecutionValidationFailure: Hashable, Sendable {
    let code: ExecutionResultReasonCode
    let text: String
}

/// Executor-owned, strongly typed result for exactly one submitted candidate.
/// It is intentionally not a receipt until it has been checked against the frozen plan.
struct ExecutionItemResult: Identifiable, Hashable, Sendable {
    var id: String { itemID }

    let itemID: String
    let order: Int
    let originalPath: String
    let status: ExecutionReceiptItemStatus
    let reasonCode: ExecutionResultReasonCode
    let reasonText: String
    let actualBytes: Int64
}

struct ExecutionResultSet: Hashable, Sendable {
    let domain: OperationPlanDomain
    let startedAt: Date
    let completedAt: Date
    let wasUserAborted: Bool
    let items: [ExecutionItemResult]
}

enum ExecutionReceiptWarning: String, Hashable, Sendable {
    case trashSpaceMayNotBeReleasedImmediately

    var message: String {
        switch self {
        case .trashSpaceMayNotBeReleasedImmediately:
            return String(localized: "文件仍在废纸篓时占用的空间可能尚未释放，可用空间不会立即完全增加。")
        }
    }
}

struct ExecutionReceiptItem: Identifiable, Hashable, Sendable {
    let id: String
    let order: Int
    let originalPath: String
    let category: OperationPlanItemCategory
    let estimatedBytes: Int64
    let status: ExecutionReceiptItemStatus
    let reasonCode: ExecutionResultReasonCode
    let reasonText: String
    let actualBytes: Int64
}

struct ExecutionReceipt: Identifiable, Hashable, Sendable {
    let id: UUID
    let planID: UUID
    let domain: OperationPlanDomain
    let startedAt: Date
    let completedAt: Date
    let expectedItemCount: Int
    let expectedBytes: Int64
    let succeededCount: Int
    let succeededBytes: Int64
    let wasUserAborted: Bool
    let items: [ExecutionReceiptItem]
    let warnings: [ExecutionReceiptWarning]

    func count(for status: ExecutionReceiptItemStatus) -> Int {
        items.reduce(0) { $0 + ($1.status == status ? 1 : 0) }
    }
}

enum ExecutionReceiptBuildError: Error, Equatable, Sendable {
    case domainMismatch(plan: OperationPlanDomain, results: OperationPlanDomain)
    case executionBeforePlanWasFrozen
    case invalidTimeRange
    case duplicateResultID(String)
    case missingResult(String)
    case unexpectedResult(String)
    case orderMismatch(itemID: String, expected: Int, actual: Int)
    case pathMismatch(itemID: String)
    case invalidActualCapacity(itemID: String, value: Int64)
    case statusReasonMismatch(itemID: String)
    case unknownExecutionResult(itemID: String)
    case capacityOverflow
    case cancellationSequenceInvalid
    case uninstallApplicationNotFirst
    case uninstallResidueStateInvalid(itemID: String)
}

extension ExecutionReceiptBuildError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .domainMismatch:
            return String(localized: "执行结果领域与冻结计划不一致。")
        case .executionBeforePlanWasFrozen:
            return String(localized: "执行开始时间早于计划冻结时间。")
        case .invalidTimeRange:
            return String(localized: "执行完成时间早于开始时间。")
        case .duplicateResultID(let itemID):
            return String(localized: "执行结果包含重复项目：\(itemID)")
        case .missingResult(let itemID):
            return String(localized: "冻结计划项目缺少执行结果：\(itemID)")
        case .unexpectedResult(let itemID):
            return String(localized: "执行结果包含计划外项目：\(itemID)")
        case .orderMismatch(let itemID, let expected, let actual):
            return String(localized: "执行结果顺序与计划不一致：\(itemID)，预计 \(expected)，实际 \(actual)。")
        case .pathMismatch(let itemID):
            return String(localized: "执行结果路径与冻结计划不一致：\(itemID)")
        case .invalidActualCapacity(let itemID, let value):
            return String(localized: "执行结果容量非法：\(itemID)，\(value) bytes。")
        case .statusReasonMismatch(let itemID):
            return String(localized: "执行结果状态与原因代码不一致：\(itemID)")
        case .unknownExecutionResult(let itemID):
            return String(localized: "执行器返回未知结果：\(itemID)")
        case .capacityOverflow:
            return String(localized: "执行收据容量合计溢出。")
        case .cancellationSequenceInvalid:
            return String(localized: "执行中止状态与后续未执行项目不一致。")
        case .uninstallApplicationNotFirst:
            return String(localized: "卸载收据的第一项不是应用本体。")
        case .uninstallResidueStateInvalid(let itemID):
            return String(localized: "应用本体结果与残留状态不一致：\(itemID)")
        }
    }
}

struct ExecutionReceiptBuilder: Sendable {
    func build(
        plan: OperationPlan,
        resultSet: ExecutionResultSet,
        receiptID: UUID = UUID()
    ) throws -> ExecutionReceipt {
        guard plan.domain == resultSet.domain else {
            throw ExecutionReceiptBuildError.domainMismatch(plan: plan.domain, results: resultSet.domain)
        }
        guard resultSet.startedAt >= plan.frozenAt else {
            throw ExecutionReceiptBuildError.executionBeforePlanWasFrozen
        }
        guard resultSet.completedAt >= resultSet.startedAt else {
            throw ExecutionReceiptBuildError.invalidTimeRange
        }

        let duplicateID = Dictionary(grouping: resultSet.items, by: \.itemID)
            .compactMap { $0.value.count > 1 ? $0.key : nil }
            .sorted()
            .first
        if let duplicateID {
            throw ExecutionReceiptBuildError.duplicateResultID(duplicateID)
        }

        let plannedIDs = Set(plan.items.map(\.id))
        if let unexpected = resultSet.items.first(where: { !plannedIDs.contains($0.itemID) }) {
            throw ExecutionReceiptBuildError.unexpectedResult(unexpected.itemID)
        }
        let resultIDs = Set(resultSet.items.map(\.itemID))
        if let missing = plan.items.first(where: { !resultIDs.contains($0.id) }) {
            throw ExecutionReceiptBuildError.missingResult(missing.id)
        }

        var receiptItems: [ExecutionReceiptItem] = []
        receiptItems.reserveCapacity(plan.items.count)
        var succeededCount = 0
        var succeededBytes: Int64 = 0

        for (index, planItem) in plan.items.enumerated() {
            let result = resultSet.items[index]
            guard result.itemID == planItem.id else {
                throw ExecutionReceiptBuildError.orderMismatch(
                    itemID: result.itemID,
                    expected: planItem.order,
                    actual: result.order
                )
            }
            guard result.order == planItem.order else {
                throw ExecutionReceiptBuildError.orderMismatch(
                    itemID: planItem.id,
                    expected: planItem.order,
                    actual: result.order
                )
            }
            guard result.originalPath == planItem.identity.originalPath else {
                throw ExecutionReceiptBuildError.pathMismatch(itemID: planItem.id)
            }
            guard result.actualBytes >= 0 else {
                throw ExecutionReceiptBuildError.invalidActualCapacity(itemID: planItem.id, value: result.actualBytes)
            }
        guard !result.reasonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExecutionReceiptBuildError.unknownExecutionResult(itemID: planItem.id)
        }
        guard result.reasonCode != .unknownExecutorResult else {
            throw ExecutionReceiptBuildError.unknownExecutionResult(itemID: planItem.id)
        }
        try validateStatusAndReason(result, planItem: planItem)

            if result.status == .succeeded {
                guard result.actualBytes == planItem.estimatedBytes else {
                    throw ExecutionReceiptBuildError.invalidActualCapacity(
                        itemID: planItem.id,
                        value: result.actualBytes
                    )
                }
                succeededCount += 1
                let addition = succeededBytes.addingReportingOverflow(result.actualBytes)
                guard !addition.overflow else {
                    throw ExecutionReceiptBuildError.capacityOverflow
                }
                succeededBytes = addition.partialValue
            } else if result.actualBytes != 0 {
                throw ExecutionReceiptBuildError.invalidActualCapacity(itemID: planItem.id, value: result.actualBytes)
            }

            receiptItems.append(ExecutionReceiptItem(
                id: planItem.id,
                order: planItem.order,
                originalPath: planItem.identity.originalPath,
                category: planItem.category,
                estimatedBytes: planItem.estimatedBytes,
                status: result.status,
                reasonCode: result.reasonCode,
                reasonText: result.reasonText,
                actualBytes: result.actualBytes
            ))
        }

        try validateCancellation(items: receiptItems, wasUserAborted: resultSet.wasUserAborted)
        if plan.domain == .uninstall {
            try validateUninstall(items: receiptItems)
        }

        return ExecutionReceipt(
            id: receiptID,
            planID: plan.id,
            domain: plan.domain,
            startedAt: resultSet.startedAt,
            completedAt: resultSet.completedAt,
            expectedItemCount: plan.itemCount,
            expectedBytes: plan.estimatedBytes,
            succeededCount: succeededCount,
            succeededBytes: succeededBytes,
            wasUserAborted: resultSet.wasUserAborted,
            items: receiptItems,
            warnings: [.trashSpaceMayNotBeReleasedImmediately]
        )
    }

    private func validateStatusAndReason(
        _ result: ExecutionItemResult,
        planItem: OperationPlanItem
    ) throws {
        let valid: Bool
        switch result.status {
        case .succeeded:
            valid = result.reasonCode == .movedToTrash
        case .failed:
            valid = result.reasonCode == .movePermissionDenied
                || result.reasonCode == .moveSystemFailure
        case .skipped:
            valid = validSkipReasonCodes(for: planItem.category).contains(result.reasonCode)
        case .aborted:
            valid = result.reasonCode == .userCancelledAtBoundary
        case .notExecuted:
            valid = result.reasonCode == .notExecutedAfterUserCancellation
                || (result.reasonCode == .notExecutedAfterApplicationFailure
                    && planItem.category.isResidue)
        }
        guard valid else {
            if result.reasonCode == .uninstallApplicationMissing {
                throw ExecutionReceiptBuildError.unknownExecutionResult(itemID: planItem.id)
            }
            throw ExecutionReceiptBuildError.statusReasonMismatch(itemID: planItem.id)
        }
    }

    private func validateCancellation(
        items: [ExecutionReceiptItem],
        wasUserAborted: Bool
    ) throws {
        let abortedIndices = items.indices.filter { items[$0].status == .aborted }
        guard wasUserAborted == (abortedIndices.count == 1) else {
            throw ExecutionReceiptBuildError.cancellationSequenceInvalid
        }
        guard let abortedIndex = abortedIndices.first else {
            guard items.allSatisfy({
                $0.reasonCode != .notExecutedAfterUserCancellation
            }) else {
                throw ExecutionReceiptBuildError.cancellationSequenceInvalid
            }
            return
        }
        for index in items.indices {
            if index < abortedIndex
                && (items[index].status == .notExecuted || items[index].status == .aborted) {
                throw ExecutionReceiptBuildError.cancellationSequenceInvalid
            }
            if index > abortedIndex,
               (items[index].status != .notExecuted
                || items[index].reasonCode != .notExecutedAfterUserCancellation) {
                throw ExecutionReceiptBuildError.cancellationSequenceInvalid
            }
        }
    }

    private func validateUninstall(items: [ExecutionReceiptItem]) throws {
        guard let application = items.first,
              application.category == .applicationBundle else {
            throw ExecutionReceiptBuildError.uninstallApplicationNotFirst
        }

        switch application.status {
        case .succeeded:
            if let invalid = items.dropFirst().first(where: {
                $0.reasonCode == .notExecutedAfterApplicationFailure
            }) {
                throw ExecutionReceiptBuildError.uninstallResidueStateInvalid(itemID: invalid.id)
            }
        case .failed, .skipped:
            if let invalid = items.dropFirst().first(where: {
                $0.status != .notExecuted
                    || $0.reasonCode != .notExecutedAfterApplicationFailure
            }) {
                throw ExecutionReceiptBuildError.uninstallResidueStateInvalid(itemID: invalid.id)
            }
        case .aborted:
            if let invalid = items.dropFirst().first(where: {
                $0.status != .notExecuted
                    || $0.reasonCode != .notExecutedAfterUserCancellation
            }) {
                throw ExecutionReceiptBuildError.uninstallResidueStateInvalid(itemID: invalid.id)
            }
        case .notExecuted:
            throw ExecutionReceiptBuildError.uninstallResidueStateInvalid(itemID: application.id)
        }
    }

    private func validSkipReasonCodes(
        for category: OperationPlanItemCategory
    ) -> Set<ExecutionResultReasonCode> {
        let shared: Set<ExecutionResultReasonCode> = [
            .pathOutsideAllowedRoot,
            .pathChanged,
            .symbolicLinkDetected,
            .fileTypeChanged,
            .identityChanged,
            .metadataChanged,
            .validationPermissionDenied
        ]
        switch category {
        case .cleanup:
            return shared
        case .applicationBundle:
            return shared.union([
                .bundleIdentifierInvalid,
                .bundleIdentifierChanged,
                .applicationStillRunning
            ])
        case .residue:
            return shared.union([.bundleIdentifierInvalid, .residueRuleMismatch])
        }
    }
}

private extension OperationPlanItemCategory {
    var isResidue: Bool {
        if case .residue = self { return true }
        return false
    }
}
