import Foundation

protocol CleanupExecuting: Sendable {
    func moveToTrash(
        candidates: [CleanupFileCandidate],
        progress: @escaping @Sendable (CleanupExecutionProgress) async -> Void
    ) async -> CleanupExecutionReport
}

protocol TrashMoving: Sendable {
    func moveToTrash(_ url: URL) throws
}

struct SystemTrashMover: TrashMoving {
    func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// The default production cleanup executor. It owns the conservative move operation and the
/// strongly typed observation emitted for every frozen candidate.
actor TrashCleanupExecutor: CleanupExecuting {
    private let allowedRootPaths: Set<String>
    private let progressBatchSize: Int
    private let trashMover: any TrashMoving

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        progressBatchSize: Int = 25,
        trashMover: any TrashMoving = SystemTrashMover()
    ) {
        allowedRootPaths = Set(Self.defaultAllowedRoots(homeDirectory: homeDirectory))
        self.progressBatchSize = progressBatchSize
        self.trashMover = trashMover
    }

    init(
        allowedRoots: [URL],
        progressBatchSize: Int = 25,
        trashMover: any TrashMoving = SystemTrashMover()
    ) {
        allowedRootPaths = Set(allowedRoots.map { $0.standardizedFileURL.path })
        self.progressBatchSize = progressBatchSize
        self.trashMover = trashMover
    }

    func moveToTrash(
        candidates: [CleanupFileCandidate],
        progress: @escaping @Sendable (CleanupExecutionProgress) async -> Void
    ) async -> CleanupExecutionReport {
        let startedAt = Date()
        let requestedBytes = candidates.reduce(0) { $0 + $1.allocatedBytes }
        var movedCount = 0
        var movedBytes: Int64 = 0
        var failures: [CleanupFailure] = []
        var results: [ExecutionItemResult] = []
        var cancelled = false

        await progress(.init(
            currentPath: String(localized: "正在复核所选文件"),
            completedCount: 0,
            totalCount: candidates.count,
            movedBytes: 0,
            failureCount: 0
        ))

        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled {
                cancelled = true
                results.append(ExecutionItemResult(
                    itemID: candidate.id,
                    order: index,
                    originalPath: candidate.path,
                    status: .aborted,
                    reasonCode: .userCancelledAtBoundary,
                    reasonText: String(localized: "执行边界观察到用户取消，本项目没有尝试。"),
                    actualBytes: 0
                ))
                for (remainingIndex, remaining) in candidates.enumerated() where remainingIndex > index {
                    results.append(ExecutionItemResult(
                        itemID: remaining.id,
                        order: remainingIndex,
                        originalPath: remaining.path,
                        status: .notExecuted,
                        reasonCode: .notExecutedAfterUserCancellation,
                        reasonText: String(localized: "因前序用户中止，本项目没有执行。"),
                        actualBytes: 0
                    ))
                }
                break
            }

            if let failure = ExecutionSafetyCore.validateCleanup(
                candidate,
                allowedRootPaths: allowedRootPaths
            ) {
                failures.append(CleanupFailure(path: candidate.path, reason: failure.text))
                results.append(ExecutionItemResult(
                    itemID: candidate.id,
                    order: index,
                    originalPath: candidate.path,
                    status: .skipped,
                    reasonCode: failure.code,
                    reasonText: failure.text,
                    actualBytes: 0
                ))
            } else {
                do {
                    try trashMover.moveToTrash(URL(fileURLWithPath: candidate.path))
                    movedCount += 1
                    movedBytes += candidate.allocatedBytes
                    results.append(ExecutionItemResult(
                        itemID: candidate.id,
                        order: index,
                        originalPath: candidate.path,
                        status: .succeeded,
                        reasonCode: .movedToTrash,
                        reasonText: String(localized: "已通过执行前安全复验并移入废纸篓。"),
                        actualBytes: candidate.allocatedBytes
                    ))
                } catch {
                    let typedFailure = ExecutionSafetyCore.moveFailure(error as NSError)
                    failures.append(CleanupFailure(path: candidate.path, reason: typedFailure.text))
                    results.append(ExecutionItemResult(
                        itemID: candidate.id,
                        order: index,
                        originalPath: candidate.path,
                        status: .failed,
                        reasonCode: typedFailure.code,
                        reasonText: typedFailure.text,
                        actualBytes: 0
                    ))
                }
            }

            let completedCount = index + 1
            if completedCount.isMultiple(of: progressBatchSize) || completedCount == candidates.count {
                await progress(.init(
                    currentPath: candidate.path,
                    completedCount: completedCount,
                    totalCount: candidates.count,
                    movedBytes: movedBytes,
                    failureCount: failures.count
                ))
            }
        }

        return CleanupExecutionReport(
            requestedCount: candidates.count,
            requestedBytes: requestedBytes,
            movedCount: movedCount,
            movedBytes: movedBytes,
            failures: failures,
            cancelled: cancelled,
            finishedAt: Date(),
            startedAt: startedAt,
            itemResults: results
        )
    }

    private static func defaultAllowedRoots(homeDirectory: URL) -> [String] {
        [
            homeDirectory.appending(path: "Library/Caches", directoryHint: .isDirectory),
            homeDirectory.appending(path: "Library/Logs", directoryHint: .isDirectory),
            homeDirectory.appending(path: "Library/Application Support/CrashReporter", directoryHint: .isDirectory),
            homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        ].map { $0.standardizedFileURL.path }
    }
}
