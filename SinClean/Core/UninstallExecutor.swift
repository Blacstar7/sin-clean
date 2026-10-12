import Foundation

protocol UninstallExecuting: Sendable {
    func moveToTrash(
        candidates: [UninstallItemCandidate],
        progress: @escaping @Sendable (UninstallProgress) async -> Void
    ) async -> UninstallExecutionReport
}

/// The default production uninstall executor. Candidate order comes from the frozen plan and is
/// never rebuilt here: application first, followed only by approved residue candidates.
actor UninstallExecutor: UninstallExecuting {
    private let applicationRootPaths: Set<String>
    private let residueRootPaths: Set<String>
    private let trashMover: any TrashMoving

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashMover: any TrashMoving = SystemTrashMover()
    ) {
        applicationRootPaths = Set([
            URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL.path,
            homeDirectory.appending(path: "Applications", directoryHint: .isDirectory).standardizedFileURL.path
        ])
        residueRootPaths = Set(Self.residueRootURLs(homeDirectory: homeDirectory).map {
            $0.standardizedFileURL.path
        })
        self.trashMover = trashMover
    }

    init(
        applicationRoots: [URL],
        residueRoots: [URL],
        trashMover: any TrashMoving = SystemTrashMover()
    ) {
        applicationRootPaths = Set(applicationRoots.map { $0.standardizedFileURL.path })
        residueRootPaths = Set(residueRoots.map { $0.standardizedFileURL.path })
        self.trashMover = trashMover
    }

    func moveToTrash(
        candidates: [UninstallItemCandidate],
        progress: @escaping @Sendable (UninstallProgress) async -> Void
    ) async -> UninstallExecutionReport {
        let startedAt = Date()
        let applicationName = candidates.first?.applicationName ?? String(localized: "未知应用")
        let bundleIdentifier = candidates.first?.bundleIdentifier ?? ""
        var movedCount = 0
        var movedBytes: Int64 = 0
        var failures: [UninstallFailure] = []
        var results: [ExecutionItemResult] = []
        var cancelled = false
        var applicationMoved = false

        await progress(.init(
            currentPath: String(localized: "正在复核应用身份"),
            completedCount: 0,
            totalCount: candidates.count,
            movedBytes: 0,
            failureCount: 0
        ))

        guard candidates.first?.kind == .applicationBundle else {
            failures.append(UninstallFailure(path: "", reason: String(localized: "卸载清单中缺少位于第一项的应用本体")))
            results = candidates.enumerated().map { index, candidate in
                ExecutionItemResult(
                    itemID: candidate.id,
                    order: index,
                    originalPath: candidate.path,
                    status: .notExecuted,
                    reasonCode: .uninstallApplicationMissing,
                    reasonText: String(localized: "执行候选缺少位于第一项的应用本体，本项目没有执行。"),
                    actualBytes: 0
                )
            }
            return makeReport(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                requestedCount: candidates.count,
                movedCount: 0,
                movedBytes: 0,
                applicationMoved: false,
                failures: failures,
                cancelled: false,
                startedAt: startedAt,
                itemResults: results
            )
        }

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

            if let failure = ExecutionSafetyCore.validateUninstall(
                candidate,
                applicationRootPaths: applicationRootPaths,
                residueRootPaths: residueRootPaths
            ) {
                failures.append(UninstallFailure(path: candidate.path, reason: failure.text))
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
                    if index == 0 { applicationMoved = true }
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
                    failures.append(UninstallFailure(path: candidate.path, reason: typedFailure.text))
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

            await progress(.init(
                currentPath: candidate.path,
                completedCount: index + 1,
                totalCount: candidates.count,
                movedBytes: movedBytes,
                failureCount: failures.count
            ))

            if index == 0, !applicationMoved {
                for (remainingIndex, remaining) in candidates.enumerated() where remainingIndex > index {
                    let reason = String(localized: "应用本体未成功移入废纸篓，按照卸载边界，本残留保持不动且未执行。")
                    failures.append(UninstallFailure(path: remaining.path, reason: reason))
                    results.append(ExecutionItemResult(
                        itemID: remaining.id,
                        order: remainingIndex,
                        originalPath: remaining.path,
                        status: .notExecuted,
                        reasonCode: .notExecutedAfterApplicationFailure,
                        reasonText: reason,
                        actualBytes: 0
                    ))
                }
                break
            }
        }

        return makeReport(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            requestedCount: candidates.count,
            movedCount: movedCount,
            movedBytes: movedBytes,
            applicationMoved: applicationMoved,
            failures: failures,
            cancelled: cancelled,
            startedAt: startedAt,
            itemResults: results
        )
    }

    private func makeReport(
        applicationName: String,
        bundleIdentifier: String,
        requestedCount: Int,
        movedCount: Int,
        movedBytes: Int64,
        applicationMoved: Bool,
        failures: [UninstallFailure],
        cancelled: Bool,
        startedAt: Date,
        itemResults: [ExecutionItemResult]
    ) -> UninstallExecutionReport {
        UninstallExecutionReport(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            requestedCount: requestedCount,
            movedCount: movedCount,
            movedBytes: movedBytes,
            applicationMoved: applicationMoved,
            failures: failures,
            cancelled: cancelled,
            finishedAt: Date(),
            startedAt: startedAt,
            itemResults: itemResults
        )
    }

    private static func residueRootURLs(homeDirectory: URL) -> [URL] {
        let library = homeDirectory.appending(path: "Library", directoryHint: .isDirectory)
        return [
            "Caches", "Logs", "Preferences", "Saved Application State", "Application Support",
            "Containers", "HTTPStorages", "WebKit", "Application Scripts"
        ].map { library.appending(path: $0, directoryHint: .isDirectory) }
    }
}
