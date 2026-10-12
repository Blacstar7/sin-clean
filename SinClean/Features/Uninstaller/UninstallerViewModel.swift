import SwiftUI

@MainActor
final class UninstallerViewModel: ObservableObject {
    enum ScanPhase: Equatable {
        case idle
        case scanning
        case completed
        case cancelled
        case failed(String)
    }

    enum ResiduePhase: Equatable {
        case idle
        case scanning
        case completed
    }

    enum AssociationPhase: Equatable {
        case disabled
        case scanning
        case completed
    }

    enum ExecutionPhase: Equatable {
        case idle
        case running
        case completed
    }

    @Published private(set) var scanPhase: ScanPhase = .idle
    @Published private(set) var scanProgress: ApplicationScanProgress = .idle
    @Published private(set) var scanReport: ApplicationScanReport?
    @Published private(set) var selectedApplicationID: String?
    @Published private(set) var residuePhase: ResiduePhase = .idle
    @Published private(set) var residueReport: ResidueScanReport?
    @Published private(set) var associationPhase: AssociationPhase = .scanning
    @Published private(set) var associationReport: AppAssociationReport?
    @Published private(set) var selectedResidueIDs: Set<String> = []
    @Published private(set) var executionPhase: ExecutionPhase = .idle
    @Published private(set) var executionProgress: UninstallProgress = .idle
    @Published private(set) var lastExecutionReport: UninstallExecutionReport?
    @Published private(set) var lastExecutionReceipt: ExecutionReceipt?
    @Published private(set) var executionReceiptBuildError: ExecutionReceiptBuildError?
    @Published private(set) var uninstallHistory: [UninstallHistoryEntry] = []
    @Published private(set) var historySaveWarning: String?
    @Published private(set) var frozenOperationPlan: OperationPlan?
    @Published private(set) var operationPlanBuildError: OperationPlanBuildError?
    // SC-PD3：占用全景（派生自既有报告＋一次身份复验）与卸载后复查（只读、仅内存）。
    @Published private(set) var footprintReport: AppFootprintReport?
    @Published private(set) var postUninstallRecheck: UninstallRecheckReport?
    @Published private(set) var postUninstallRecheckRunning = false

    private let applicationScanner: any ApplicationScanning
    private let residueScanner: any AppResidueScanning
    private let associationScanner: any AppAssociationScanning
    private let executor: any UninstallExecuting
    private let historyStore: any UninstallHistoryStoring
    private let ignoreList: IgnoreListStore
    private let operationPlanBuilder: OperationPlanBuilder
    private let operationPlanTextExporter: OperationPlanTextExporter
    private let executionReceiptBuilder: ExecutionReceiptBuilder
    private var appScanTask: Task<Void, Never>?
    private var residueScanTask: Task<Void, Never>?
    private var associationScanTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var footprintTask: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?
    private var analyzesAssociatedComponents = true
    private let footprintProbe: AppFootprintIdentityProbing
    /// 注入点：`startScan()` 未显式传配置时的缺省配置。生产恒为 nil（＝`.standard`），预览夹具用于关闭关联分析。
    private let fallbackScanConfiguration: ApplicationScanConfiguration?

    var applications: [InstalledApplication] {
        scanReport?.applications.filter { !ignoreList.isIgnored($0) } ?? []
    }

    var rawApplicationCount: Int { scanReport?.applications.count ?? 0 }

    var ignoredApplicationCount: Int {
        scanReport?.applications.reduce(0) { $0 + (ignoreList.isIgnored($1) ? 1 : 0) } ?? 0
    }

    var selectedApplication: InstalledApplication? {
        applications.first { $0.id == selectedApplicationID }
    }

    var residues: [AppResidueCandidate] {
        residueReport?.candidates.filter { !ignoreList.isIgnored($0) } ?? []
    }

    var ignoredResidueCount: Int {
        residueReport?.candidates.reduce(0) { $0 + (ignoreList.isIgnored($1) ? 1 : 0) } ?? 0
    }

    var associatedItems: [AppAssociatedItem] { associationReport?.items ?? [] }

    var selectedResidueCount: Int {
        residues.reduce(0) { count, residue in
            count + (selectedResidueIDs.contains(residue.id) ? 1 : 0)
        }
    }

    var selectedResidueBytes: Int64 {
        residues.reduce(0) { total, residue in
            total + (selectedResidueIDs.contains(residue.id) ? residue.allocatedBytes : 0)
        }
    }

    var selectedTotalBytes: Int64 {
        (selectedApplication?.allocatedBytes ?? 0) + selectedResidueBytes
    }

    var canUninstall: Bool {
        guard executionPhase != .running,
              ignoreList.isOperational,
              let application = selectedApplication,
              !ignoreList.isIgnored(application),
              let bundleIdentifier = application.bundleIdentifier else { return false }
        return ScanRules.bundleIdentifierRestriction(bundleIdentifier) == nil
    }

    var confirmationPathSummary: String {
        guard let application = selectedApplication else { return "" }
        let selectedPaths = residues
            .filter { selectedResidueIDs.contains($0.id) }
            .prefix(3)
            .map(\.path)
        var parts = [application.path]
        parts.append(contentsOf: selectedPaths)
        let remaining = selectedResidueCount - min(selectedResidueCount, 3)
        let summary = parts.joined(separator: "；")
        return remaining > 0 ? String(localized: "\(summary)；另有 \(remaining.formatted()) 项残留") : summary
    }

    init(
        applicationScanner: any ApplicationScanning = ApplicationScanner(),
        residueScanner: any AppResidueScanning = AppResidueScanner(),
        associationScanner: any AppAssociationScanning = AppAssociationScanner(),
        executor: any UninstallExecuting = UninstallExecutor(),
        historyStore: any UninstallHistoryStoring = UninstallHistoryStore(),
        ignoreList: IgnoreListStore? = nil,
        operationPlanBuilder: OperationPlanBuilder = OperationPlanBuilder(),
        operationPlanTextExporter: OperationPlanTextExporter = OperationPlanTextExporter(),
        executionReceiptBuilder: ExecutionReceiptBuilder = ExecutionReceiptBuilder(),
        footprintProbe: AppFootprintIdentityProbing = .live,
        fallbackScanConfiguration: ApplicationScanConfiguration? = nil
    ) {
        self.applicationScanner = applicationScanner
        self.residueScanner = residueScanner
        self.associationScanner = associationScanner
        self.executor = executor
        self.historyStore = historyStore
        self.operationPlanBuilder = operationPlanBuilder
        self.operationPlanTextExporter = operationPlanTextExporter
        self.executionReceiptBuilder = executionReceiptBuilder
        self.footprintProbe = footprintProbe
        self.fallbackScanConfiguration = fallbackScanConfiguration
        self.ignoreList = ignoreList ?? IgnoreListStore(
            repository: InMemoryIgnoreRuleRepository(),
            autoload: false
        )

        Task { [weak self, historyStore] in
            let history = await historyStore.load()
            guard !Task.isCancelled else { return }
            self?.uninstallHistory = history
        }
    }

    deinit {
        appScanTask?.cancel()
        residueScanTask?.cancel()
        associationScanTask?.cancel()
        executionTask?.cancel()
        footprintTask?.cancel()
        recheckTask?.cancel()
    }

    func startScan(configuration: ApplicationScanConfiguration? = nil) {
        guard executionPhase != .running else { return }
        appScanTask?.cancel()
        residueScanTask?.cancel()
        associationScanTask?.cancel()
        footprintTask?.cancel()
        recheckTask?.cancel()
        let effectiveConfiguration = configuration ?? fallbackScanConfiguration ?? .standard
        analyzesAssociatedComponents = effectiveConfiguration.analyzeAssociatedComponents
        selectedApplicationID = nil
        selectedResidueIDs.removeAll()
        residueReport = nil
        residuePhase = .idle
        associationReport = nil
        associationPhase = analyzesAssociatedComponents ? .scanning : .disabled
        scanReport = nil
        lastExecutionReport = nil
        lastExecutionReceipt = nil
        executionReceiptBuildError = nil
        executionPhase = .idle
        executionProgress = .idle
        historySaveWarning = nil
        footprintReport = nil
        postUninstallRecheck = nil
        postUninstallRecheckRunning = false
        scanProgress = .idle
        scanPhase = .scanning

        let scanner: any ApplicationScanning
        if configuration == nil {
            scanner = applicationScanner
        } else {
            scanner = ApplicationScanner(
                applicationRoots: effectiveConfiguration.applicationRoots(
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                ),
                notSelectedRoots: effectiveConfiguration.notSelectedApplicationRoots(
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                ),
                measurementConcurrency: effectiveConfiguration.measurementConcurrency
            )
        }

        appScanTask = Task { [weak self, scanner] in
            do {
                let report = try await scanner.scan { progress in
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.scanProgress = progress }
                }
                try Task.checkCancellation()
                self?.scanReport = report
                self?.scanPhase = .completed
                if let first = self?.applications.first {
                    self?.selectApplication(first.id)
                }
            } catch is CancellationError {
                self?.scanPhase = .cancelled
            } catch {
                self?.scanPhase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        appScanTask?.cancel()
    }

    func selectApplication(_ id: String) {
        guard executionPhase != .running,
              selectedApplicationID != id || residuePhase == .idle else { return }
        residueScanTask?.cancel()
        associationScanTask?.cancel()
        footprintTask?.cancel()
        selectedApplicationID = id
        selectedResidueIDs.removeAll()
        residueReport = nil
        residuePhase = .scanning
        associationReport = nil
        associationPhase = analyzesAssociatedComponents ? .scanning : .disabled
        footprintReport = nil

        guard let application = applications.first(where: { $0.id == id }) else {
            residuePhase = .idle
            return
        }

        residueScanTask = Task { [weak self, residueScanner] in
            let report = await residueScanner.scan(for: application)
            guard !Task.isCancelled, self?.selectedApplicationID == id else { return }
            self?.residueReport = report
            self?.residuePhase = .completed
            self?.scheduleFootprintComputation(applicationID: id)
        }


        let associationEnabled = analyzesAssociatedComponents
        associationScanTask = Task { [weak self, associationScanner] in
            let report = await associationScanner.scan(for: application, enabled: associationEnabled)
            guard !Task.isCancelled, self?.selectedApplicationID == id else { return }
            self?.associationReport = report
            self?.associationPhase = associationEnabled ? .completed : .disabled
            self?.scheduleFootprintComputation(applicationID: id)
        }
    }

    func isResidueSelected(_ candidate: AppResidueCandidate) -> Bool {
        selectedResidueIDs.contains(candidate.id) && !ignoreList.isIgnored(candidate)
    }

    func setResidueSelected(_ isSelected: Bool, candidate: AppResidueCandidate) {
        guard executionPhase != .running, ignoreList.isOperational else { return }
        if isSelected {
            guard !ignoreList.isIgnored(candidate) else { return }
            selectedResidueIDs.insert(candidate.id)
        } else {
            selectedResidueIDs.remove(candidate.id)
        }
    }

    func setAllResiduesSelected(_ isSelected: Bool) {
        guard executionPhase != .running, ignoreList.isOperational else { return }
        if isSelected {
            selectedResidueIDs = Set(residues.map(\.id))
        } else {
            selectedResidueIDs.removeAll()
        }
    }

    func startUninstall() {
        guard canUninstall,
              let application = selectedApplication,
              !ignoreList.isIgnored(application) else { return }
        let finalResidues = residues.filter { selectedResidueIDs.contains($0.id) }
        let frozenOperation: FrozenUninstallOperation
        do {
            frozenOperation = try operationPlanBuilder.freezeUninstall(
                application: application,
                residues: finalResidues,
                coverageRecords: (scanReport?.coverage ?? []) + (residueReport?.coverage ?? [])
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

        executionProgress = UninstallProgress(
            currentPath: String(localized: "正在复核应用身份"),
            completedCount: 0,
            totalCount: executionCandidates.count,
            movedBytes: 0,
            failureCount: 0
        )
        lastExecutionReport = nil
        lastExecutionReceipt = nil
        executionReceiptBuildError = nil
        historySaveWarning = nil
        postUninstallRecheck = nil
        postUninstallRecheckRunning = false
        executionPhase = .running

        let frozenPlan = frozenOperation.plan
        executionTask = Task { [weak self, executor, historyStore, executionReceiptBuilder] in
            let report = await executor.moveToTrash(candidates: executionCandidates) { progress in
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.executionProgress = progress }
            }

            let receipt: ExecutionReceipt?
            let receiptError: ExecutionReceiptBuildError?
            do {
                receipt = try executionReceiptBuilder.build(
                    plan: frozenPlan,
                    resultSet: report.executionResultSet
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

            let movedResidueCount = max(0, report.movedCount - (report.applicationMoved ? 1 : 0))
            let entry = UninstallHistoryEntry(
                id: UUID(),
                applicationName: report.applicationName,
                bundleIdentifier: report.bundleIdentifier,
                finishedAt: report.finishedAt,
                applicationMoved: report.applicationMoved,
                movedResidueCount: movedResidueCount,
                movedBytes: report.movedBytes,
                failedCount: report.failures.count,
                cancelled: report.cancelled
            )

            var saveWarning: String?
            do {
                try await historyStore.append(
                    entry,
                    plan: frozenPlan,
                    receipt: receipt,
                    receiptError: receiptError?.localizedDescription,
                    resultSet: report.executionResultSet
                )
            } catch {
                saveWarning = error.localizedDescription
            }

            self?.lastExecutionReport = report
            self?.lastExecutionReceipt = receipt
            self?.executionReceiptBuildError = receiptError
            self?.executionPhase = .completed
            self?.historySaveWarning = saveWarning
            self?.uninstallHistory.insert(entry, at: 0)
            if let count = self?.uninstallHistory.count, count > 50 {
                self?.uninstallHistory.removeLast(count - 50)
            }
            self?.selectedResidueIDs.removeAll()
        }
    }

    func cancelUninstall() {
        executionTask?.cancel()
    }

    var canExportOperationPlan: Bool {
        scanPhase == .completed
            && residuePhase == .completed
            && executionPhase == .idle
            && ignoreList.isOperational
            && canUninstall
    }

    /// Freezes an independent read-only export plan. It never writes the execution
    /// plan slot; final uninstall confirmation freezes again from the then-current state.
    func makeOperationPlanExport() throws -> OperationPlanTextExport {
        guard scanPhase == .completed, residuePhase == .completed else {
            throw OperationPlanExportPreparationError.scanNotCompleted
        }
        guard executionPhase != .running else {
            throw OperationPlanExportPreparationError.executionInProgress
        }
        guard ignoreList.isOperational else {
            throw OperationPlanExportPreparationError.ignoreListUnavailable
        }
        guard canUninstall, let application = selectedApplication else {
            throw OperationPlanExportPreparationError.noEligibleSelection
        }
        let selectedResidues = residues.filter { selectedResidueIDs.contains($0.id) }
        let exportOperation = try operationPlanBuilder.freezeUninstall(
            application: application,
            residues: selectedResidues,
            coverageRecords: (scanReport?.coverage ?? []) + (residueReport?.coverage ?? [])
        )
        return try operationPlanTextExporter.export(exportOperation.plan)
    }

    func returnToSelection() {
        guard executionPhase != .running else { return }
        executionPhase = .idle
        executionProgress = .idle
        lastExecutionReport = nil
        lastExecutionReceipt = nil
        executionReceiptBuildError = nil
        historySaveWarning = nil
        postUninstallRecheck = nil
        postUninstallRecheckRunning = false
    }

    func reconcileIgnoredSelection() {
        selectedResidueIDs = Set(residues.lazy
            .filter { self.selectedResidueIDs.contains($0.id) }
            .map(\.id))
        if let currentID = selectedApplicationID,
           let rawApplication = scanReport?.applications.first(where: { $0.id == currentID }),
           ignoreList.isIgnored(rawApplication) {
            residueScanTask?.cancel()
            associationScanTask?.cancel()
            footprintTask?.cancel()
            selectedApplicationID = nil
            selectedResidueIDs.removeAll()
            residueReport = nil
            residuePhase = .idle
            associationReport = nil
            associationPhase = analyzesAssociatedComponents ? .scanning : .disabled
            footprintReport = nil
        } else if let currentID = selectedApplicationID {
            scheduleFootprintComputation(applicationID: currentID)
        }
    }

    // MARK: - SC-PD3 占用全景与卸载后复查

    /// 复查触发条件（冻结 §4.1）：仅本体已成功移入废纸篓且执行已完成。
    var canRunPostUninstallRecheck: Bool {
        executionPhase == .completed
            && !postUninstallRecheckRunning
            && lastExecutionReport?.applicationMoved == true
    }

    func runPostUninstallRecheck() {
        guard canRunPostUninstallRecheck,
              let anchor = UninstallRecheckAnchor.extract(
                plan: frozenOperationPlan,
                report: lastExecutionReport
              ) else { return }
        recheckTask?.cancel()
        postUninstallRecheck = nil
        postUninstallRecheckRunning = true
        recheckTask = Task { [weak self, residueScanner, associationScanner] in
            let report = await Task.detached(priority: .userInitiated) {
                await UninstallRecheckEngine(
                    residueScanner: residueScanner,
                    associationScanner: associationScanner
                ).run(anchor: anchor)
            }.value
            guard !Task.isCancelled else { return }
            self?.postUninstallRecheck = report
            self?.postUninstallRecheckRunning = false
        }
    }

    /// 残留与关联报告齐备后派生占用全景（复用既有扫描结果；身份复验与聚合在后台执行）。
    private func scheduleFootprintComputation(applicationID: String) {
        guard let application = applications.first(where: { $0.id == applicationID }),
              residuePhase == .completed,
              let residueSnapshot = residueReport,
              associationPhase == .completed || associationPhase == .disabled else { return }

        let scanFailed: Bool = {
            if case .failed = scanPhase { return true }
            return false
        }()
        let input = AppFootprintEngineInput(
            application: application,
            applicationScanFailed: scanFailed,
            residueReport: residueSnapshot,
            associationReport: associationReport,
            associationAnalysisEnabled: analyzesAssociatedComponents,
            selectableResidues: residues,
            ignoredResidueCount: ignoredResidueCount,
            applicationCoverage: scanReport?.coverage ?? []
        )
        footprintTask?.cancel()
        let probe = footprintProbe
        footprintTask = Task.detached(priority: .userInitiated) { [weak self] in
            let identityProbe = probe.makeProbe(application)
            let report = AppFootprintEngine.build(input: input, identityProbe: identityProbe)
            await MainActor.run {
                guard !Task.isCancelled,
                      let self,
                      self.selectedApplicationID == applicationID else { return }
                self.footprintReport = report
            }
        }
    }

}
