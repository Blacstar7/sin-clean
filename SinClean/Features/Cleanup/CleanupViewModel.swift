import SwiftUI

@MainActor
final class CleanupViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case completed
        case cancelled
        case failed(String)
    }

    enum CleanupPhase: Equatable {
        case idle
        case running
        case completed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: CleanupScanProgress = .idle
    @Published private(set) var report: CleanupScanReport?
    @Published private(set) var selectedCandidateIDs: Set<String> = []
    @Published private(set) var selectedBytes: Int64 = 0
    @Published private(set) var selectedFileCount = 0
    @Published private(set) var selectedReviewFileCount = 0
    @Published private(set) var cleanupPhase: CleanupPhase = .idle
    @Published private(set) var cleanupProgress: CleanupExecutionProgress = .idle
    @Published private(set) var lastExecutionReport: CleanupExecutionReport?
    @Published private(set) var lastExecutionReceipt: ExecutionReceipt?
    @Published private(set) var executionReceiptBuildError: ExecutionReceiptBuildError?
    @Published private(set) var cleanupHistory: [CleanupHistoryEntry] = []
    @Published private(set) var historySaveWarning: String?
    @Published private(set) var frozenOperationPlan: OperationPlan?
    @Published private(set) var operationPlanBuildError: OperationPlanBuildError?

    private let scanner: any DiskScanning
    private let executor: any CleanupExecuting
    private let historyStore: any CleanupHistoryStoring
    private let ignoreList: IgnoreListStore
    private let operationPlanBuilder: OperationPlanBuilder
    private let operationPlanTextExporter: OperationPlanTextExporter
    private let executionReceiptBuilder: ExecutionReceiptBuilder
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?

    var results: [CleanupScanResult] {
        report?.results ?? []
    }

    var ignoredCandidateCount: Int {
        report?.allCandidates.reduce(0) { $0 + (ignoreList.isIgnored($1) ? 1 : 0) } ?? 0
    }

    var canUseIgnoreRules: Bool { ignoreList.isOperational }

    var selectedPathSummary: String {
        let candidates = selectedCandidatesSnapshot()
        guard !candidates.isEmpty else { return "" }
        let visiblePaths = candidates.prefix(3).map(\.path).joined(separator: "；")
        let remainingCount = candidates.count - min(candidates.count, 3)
        return remainingCount > 0
            ? String(localized: "\(visiblePaths)；另有 \(remainingCount.formatted()) 个文件")
            : visiblePaths
    }

    init(
        scanner: any DiskScanning = DiskScanner(),
        executor: any CleanupExecuting = TrashCleanupExecutor(),
        historyStore: any CleanupHistoryStoring = CleanupHistoryStore(),
        ignoreList: IgnoreListStore? = nil,
        operationPlanBuilder: OperationPlanBuilder = OperationPlanBuilder(),
        operationPlanTextExporter: OperationPlanTextExporter = OperationPlanTextExporter(),
        executionReceiptBuilder: ExecutionReceiptBuilder = ExecutionReceiptBuilder()
    ) {
        self.scanner = scanner
        self.executor = executor
        self.historyStore = historyStore
        self.operationPlanBuilder = operationPlanBuilder
        self.operationPlanTextExporter = operationPlanTextExporter
        self.executionReceiptBuilder = executionReceiptBuilder
        self.ignoreList = ignoreList ?? IgnoreListStore(
            repository: InMemoryIgnoreRuleRepository(),
            autoload: false
        )

        Task { [weak self, historyStore] in
            let entries = await historyStore.load()
            guard !Task.isCancelled else { return }
            self?.cleanupHistory = entries
        }
    }

    deinit {
        scanTask?.cancel()
        cleanupTask?.cancel()
    }

    func startScan() {
        guard cleanupPhase != .running else { return }
        scanTask?.cancel()
        resetSelection()
        report = nil
        lastExecutionReport = nil
        lastExecutionReceipt = nil
        executionReceiptBuildError = nil
        cleanupPhase = .idle
        cleanupProgress = .idle
        historySaveWarning = nil
        progress = .idle
        phase = .scanning

        scanTask = Task { [weak self, scanner] in
            do {
                let report = try await scanner.scan { progress in
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self?.progress = progress
                    }
                }
                try Task.checkCancellation()
                self?.report = report
                self?.phase = .completed
            } catch is CancellationError {
                self?.phase = .cancelled
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func isSelected(_ candidate: CleanupFileCandidate) -> Bool {
        selectedCandidateIDs.contains(candidate.id) && !ignoreList.isIgnored(candidate)
    }

    func visibleCandidates(in result: CleanupScanResult) -> [CleanupFileCandidate] {
        result.candidates.filter { !ignoreList.isIgnored($0) }
    }

    func ignoredCount(in result: CleanupScanResult) -> Int {
        result.candidates.reduce(0) { $0 + (ignoreList.isIgnored($1) ? 1 : 0) }
    }

    func selectedCount(in result: CleanupScanResult) -> Int {
        result.candidates.reduce(0) { partialResult, candidate in
            partialResult + (isSelected(candidate) ? 1 : 0)
        }
    }

    func setSelected(_ isSelected: Bool, candidate: CleanupFileCandidate) {
        guard cleanupPhase != .running, ignoreList.isOperational else { return }
        if isSelected {
            guard !ignoreList.isIgnored(candidate) else { return }
            selectedCandidateIDs.insert(candidate.id)
        } else {
            selectedCandidateIDs.remove(candidate.id)
        }
        updateSelectionSummary()
    }

    func setSelected(_ isSelected: Bool, result: CleanupScanResult) {
        guard cleanupPhase != .running, ignoreList.isOperational else { return }
        let candidateIDs = visibleCandidates(in: result).map(\.id)
        if isSelected {
            selectedCandidateIDs.formUnion(candidateIDs)
        } else {
            selectedCandidateIDs.subtract(candidateIDs)
        }
        updateSelectionSummary()
    }

    func startCleanup() {
        guard cleanupPhase != .running, ignoreList.isOperational else { return }
        let finalCandidates = selectedCandidatesSnapshot()
        guard !finalCandidates.isEmpty else { return }
        let frozenOperation: FrozenCleanupOperation
        do {
            frozenOperation = try operationPlanBuilder.freezeCleanup(
                candidates: finalCandidates,
                coverageRecords: report?.coverage ?? []
            )
        } catch let error as OperationPlanBuildError {
            operationPlanBuildError = error
            return
        } catch {
            assertionFailure("OperationPlanBuilder returned an unexpected error: \(error)")
            return
        }
        operationPlanBuildError = nil
        frozenOperationPlan = frozenOperation.plan
        let executionCandidates = frozenOperation.executionCandidates

        cleanupProgress = CleanupExecutionProgress(
            currentPath: String(localized: "正在复核所选文件"),
            completedCount: 0,
            totalCount: executionCandidates.count,
            movedBytes: 0,
            failureCount: 0
        )
        lastExecutionReport = nil
        lastExecutionReceipt = nil
        executionReceiptBuildError = nil
        historySaveWarning = nil
        cleanupPhase = .running

        let frozenPlan = frozenOperation.plan
        cleanupTask = Task { [weak self, executor, historyStore, executionReceiptBuilder] in
            let executionReport = await executor.moveToTrash(
                candidates: executionCandidates
            ) { progress in
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.cleanupProgress = progress
                }
            }

            let receipt: ExecutionReceipt?
            let receiptError: ExecutionReceiptBuildError?
            do {
                receipt = try executionReceiptBuilder.build(
                    plan: frozenPlan,
                    resultSet: executionReport.executionResultSet
                )
                receiptError = nil
            } catch let error as ExecutionReceiptBuildError {
                receipt = nil
                receiptError = error
            } catch {
                assertionFailure("ExecutionReceiptBuilder returned an unexpected error: \(error)")
                receipt = nil
                receiptError = .unknownExecutionResult(itemID: "receipt-builder")
            }

            let historyEntry = CleanupHistoryEntry(
                id: UUID(),
                finishedAt: executionReport.finishedAt,
                requestedCount: executionReport.requestedCount,
                movedCount: executionReport.movedCount,
                failedCount: executionReport.failures.count,
                movedBytes: executionReport.movedBytes,
                cancelled: executionReport.cancelled
            )

            var saveWarning: String?
            do {
                try await historyStore.append(
                    historyEntry,
                    plan: frozenPlan,
                    receipt: receipt,
                    receiptError: receiptError?.localizedDescription,
                    resultSet: executionReport.executionResultSet
                )
            } catch {
                saveWarning = error.localizedDescription
            }

            guard !Task.isCancelled || executionReport.cancelled else { return }
            self?.lastExecutionReport = executionReport
            self?.lastExecutionReceipt = receipt
            self?.executionReceiptBuildError = receiptError
            self?.cleanupPhase = .completed
            self?.historySaveWarning = saveWarning
            self?.cleanupHistory.insert(historyEntry, at: 0)
            if let count = self?.cleanupHistory.count, count > 50 {
                self?.cleanupHistory.removeLast(count - 50)
            }
            self?.resetSelection()
        }
    }

    func cancelCleanup() {
        cleanupTask?.cancel()
    }

    var canExportOperationPlan: Bool {
        phase == .completed
            && cleanupPhase == .idle
            && ignoreList.isOperational
            && selectedFileCount > 0
    }

    /// Freezes a read-only export snapshot without touching the execution plan slot.
    /// A later destructive confirmation must build its own final snapshot in `startCleanup()`.
    func makeOperationPlanExport() throws -> OperationPlanTextExport {
        guard phase == .completed else {
            throw OperationPlanExportPreparationError.scanNotCompleted
        }
        guard cleanupPhase != .running else {
            throw OperationPlanExportPreparationError.executionInProgress
        }
        guard ignoreList.isOperational else {
            throw OperationPlanExportPreparationError.ignoreListUnavailable
        }
        let candidates = selectedCandidatesSnapshot()
        guard !candidates.isEmpty else {
            throw OperationPlanExportPreparationError.noEligibleSelection
        }
        let exportOperation = try operationPlanBuilder.freezeCleanup(
            candidates: candidates,
            coverageRecords: report?.coverage ?? []
        )
        return try operationPlanTextExporter.export(exportOperation.plan)
    }

    func returnToResults() {
        guard cleanupPhase != .running else { return }
        lastExecutionReport = nil
        lastExecutionReceipt = nil
        executionReceiptBuildError = nil
        cleanupPhase = .idle
        cleanupProgress = .idle
        historySaveWarning = nil
    }

    func reconcileIgnoredSelection() {
        guard let report else {
            resetSelection()
            return
        }
        let ignoredIDs = report.allCandidates.lazy
            .filter { self.ignoreList.isIgnored($0) }
            .map(\.id)
        selectedCandidateIDs.subtract(ignoredIDs)
        updateSelectionSummary()
    }

    private func selectedCandidatesSnapshot() -> [CleanupFileCandidate] {
        report?.allCandidates.filter {
            selectedCandidateIDs.contains($0.id) && !ignoreList.isIgnored($0)
        } ?? []
    }

    private func updateSelectionSummary() {
        let candidates = selectedCandidatesSnapshot()
        selectedFileCount = candidates.count
        selectedBytes = candidates.reduce(0) { $0 + $1.allocatedBytes }
        selectedReviewFileCount = candidates.reduce(0) { count, candidate in
            count + (candidate.risk == .safe ? 0 : 1)
        }
    }

    private func resetSelection() {
        selectedCandidateIDs.removeAll()
        selectedBytes = 0
        selectedFileCount = 0
        selectedReviewFileCount = 0
    }
}
