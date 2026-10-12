#if DEBUG
import SwiftUI

@MainActor
struct SC14UninstallEvidencePreview: View {
    @StateObject private var viewModel: UninstallerViewModel
    @StateObject private var ignoreList: IgnoreListStore
    @State private var started = false

    init() {
        let ignoreList = IgnoreListStore(repository: InMemoryIgnoreRuleRepository(), autoload: false)
        _ignoreList = StateObject(wrappedValue: ignoreList)
        _viewModel = StateObject(wrappedValue: Self.makeViewModel(ignoreList: ignoreList))
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            UninstallerView(previewViewModel: viewModel, ignoreList: ignoreList)
                .environmentObject(AppNavigationState())
        }
        .task {
            guard !started else { return }
            started = true
            viewModel.startScan()
        }
        .preferredColorScheme(.dark)
    }

    private static func makeViewModel(ignoreList: IgnoreListStore) -> UninstallerViewModel {
        let now = Date(timeIntervalSince1970: 1_788_888_888)
        let appContext = ScanContext()
        let residueContext = ScanContext()
        let associationContext = ScanContext()
        let bundleIdentifier = "com.example.AuroraNotes"
        let applicationRoot = "/Applications"
        let applicationPath = "/Applications/Aurora Notes.app"
        let application = InstalledApplication(
            id: "preview-application",
            name: "Aurora Notes",
            path: applicationPath,
            rootPath: applicationRoot,
            bundleIdentifier: bundleIdentifier,
            version: "4.2",
            buildNumber: "417",
            allocatedBytes: 186_646_528,
            logicalBytes: 190_840_832,
            modifiedSeconds: Int64(now.timeIntervalSince1970),
            modifiedNanoseconds: 123_000_000,
            deviceID: 1,
            inode: 4_170,
            signatureState: .valid,
            signer: "Developer ID Application: Example Studio",
            teamIdentifier: "EXAMPLETEAM",
            evidenceOrigin: CandidateEvidenceOrigin(
                context: appContext,
                scopeID: applicationRoot,
                reasonCode: .applicationDirectory,
                matchedValue: ".app"
            )
        )

        let applicationScope = ScanScope(
            id: applicationRoot,
            scanner: .application,
            phase: .discover,
            rootPath: applicationRoot,
            applicationID: application.id,
            bundleIdentifier: bundleIdentifier,
            policy: ScanPolicy(
                recursive: true,
                maximumDepth: 2,
                skipsHiddenFiles: true,
                acceptedTypes: ["directory"],
                extensions: ["app"],
                matching: CandidateRuleCode.applicationDirectory.rawValue
            )
        )
        let applicationCoverage = ScanCoverage(
            context: appContext,
            scope: applicationScope,
            status: .completed,
            startedAt: now.addingTimeInterval(-8),
            finishedAt: now.addingTimeInterval(-6),
            issues: [],
            issueCount: 0,
            accessIssueCount: 0
        )

        let residueScopeID = CandidateRuleCode.residueCache.rawValue
        let residuePath = "/Users/preview/Library/Caches/\(bundleIdentifier)"
        let residue = AppResidueCandidate(
            id: "preview-residue",
            bundleIdentifier: bundleIdentifier,
            kind: .cache,
            path: residuePath,
            rootPath: "/Users/preview/Library/Caches",
            allocatedBytes: 27_312_128,
            logicalBytes: 31_457_280,
            modifiedSeconds: Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970),
            modifiedNanoseconds: 456_000_000,
            deviceID: 1,
            inode: 4_171,
            isDirectory: true,
            matchReason: "固定路径与 Bundle Identifier 精确匹配",
            evidenceOrigin: CandidateEvidenceOrigin(
                context: residueContext,
                scopeID: residueScopeID,
                reasonCode: .residueCache,
                matchedValue: bundleIdentifier
            )
        )

        let residueScope = ScanScope(
            id: residueScopeID,
            scanner: .residue,
            phase: .discover,
            rootPath: "/Users/preview/Library/Caches",
            targetPath: residuePath,
            applicationID: application.id,
            bundleIdentifier: bundleIdentifier,
            policy: ScanPolicy(recursive: false, matching: CandidateRuleCode.residueCache.rawValue)
        )
        let residueIssues = [
            ScanIssue(
                scopeID: residueScopeID,
                path: "/Users/preview/Library/Caches/example-sibling",
                phase: .discover,
                kind: .accessFailure,
                restrictionReason: nil,
                underlyingErrorDomain: NSPOSIXErrorDomain,
                underlyingErrorCode: 13,
                message: "同一范围内另一路径无法读取；当前候选已完成快照。",
                affectsCompleteness: true,
                projectsToLegacyAccessIssues: true
            ),
            ScanIssue(
                scopeID: residueScopeID,
                path: "/Users/preview/Library/Caches/example-link",
                phase: .discover,
                kind: .safetySkip,
                restrictionReason: .symbolicLink,
                underlyingErrorDomain: nil,
                underlyingErrorCode: nil,
                message: "检测到符号链接，已按安全规则跳过。",
                affectsCompleteness: true,
                projectsToLegacyAccessIssues: false
            )
        ]
        let residueCoverage = ScanCoverage(
            context: residueContext,
            scope: residueScope,
            status: .partial,
            startedAt: now.addingTimeInterval(-5),
            finishedAt: now.addingTimeInterval(-3),
            issues: residueIssues,
            issueCount: 3,
            accessIssueCount: 1
        )

        let externalPath = "/Library/LaunchAgents/com.example.AuroraNotes.sync.plist"
        let externalScopeID = "用户登录代理|/Library/LaunchAgents"
        let externalItem = AppAssociatedItem(
            id: "preview-external-association",
            kind: .userLaunchAgent,
            path: externalPath,
            identifier: "com.example.AuroraNotes.sync",
            relationship: .exactLabel,
            isInsideApplicationBundle: false,
            evidenceOrigin: CandidateEvidenceOrigin(
                context: associationContext,
                scopeID: externalScopeID,
                reasonCode: .launchLabelNamespace,
                matchedValue: "com.example.AuroraNotes.sync"
            ),
            associatedBundleIdentifier: bundleIdentifier,
            observedModifiedAt: now.addingTimeInterval(-172_800)
        )
        let externalScope = ScanScope(
            id: externalScopeID,
            scanner: .association,
            phase: .associate,
            rootPath: "/Library/LaunchAgents",
            applicationID: application.id,
            bundleIdentifier: bundleIdentifier,
            policy: ScanPolicy(
                recursive: false,
                skipsHiddenFiles: true,
                acceptedTypes: ["regularFile"],
                extensions: ["plist"],
                matching: "Label namespace first, otherwise absolute application path reference",
                maximumReadBytes: 2_000_000
            )
        )
        let externalIssue = ScanIssue(
            scopeID: externalScopeID,
            path: "/Library/LaunchAgents/com.example.AuroraNotes.invalid.plist",
            phase: .associate,
            kind: .parseFailure,
            restrictionReason: nil,
            underlyingErrorDomain: NSCocoaErrorDomain,
            underlyingErrorCode: 3840,
            message: "同一范围内另一个 plist 无法解析，已保留结构化诊断。",
            affectsCompleteness: true,
            projectsToLegacyAccessIssues: false
        )
        let externalCoverage = ScanCoverage(
            context: associationContext,
            scope: externalScope,
            status: .partial,
            startedAt: now.addingTimeInterval(-3),
            finishedAt: now.addingTimeInterval(-1),
            issues: [externalIssue],
            issueCount: 2,
            accessIssueCount: 0
        )

        let embeddedPath = "\(applicationPath)/Contents/Library/LoginItems/Aurora Notes Helper.app"
        let embeddedRoot = "\(applicationPath)/Contents/Library/LoginItems"
        let embeddedScopeID = "内嵌登录项|\(embeddedRoot)"
        let embeddedItem = AppAssociatedItem(
            id: "preview-embedded-association",
            kind: .embeddedLoginItem,
            path: embeddedPath,
            identifier: nil,
            relationship: .insideApplication,
            isInsideApplicationBundle: true,
            evidenceOrigin: CandidateEvidenceOrigin(
                context: associationContext,
                scopeID: embeddedScopeID,
                reasonCode: .embeddedLoginApp,
                matchedValue: "Aurora Notes Helper.app"
            ),
            associatedBundleIdentifier: bundleIdentifier,
            observedModifiedAt: now.addingTimeInterval(-259_200)
        )
        let embeddedCoverage = ScanCoverage(
            context: associationContext,
            scope: ScanScope(
                id: embeddedScopeID,
                scanner: .association,
                phase: .associate,
                rootPath: embeddedRoot,
                applicationID: application.id,
                bundleIdentifier: bundleIdentifier,
                policy: ScanPolicy(
                    recursive: false,
                    skipsHiddenFiles: true,
                    acceptedTypes: ["directory"],
                    extensions: ["app"],
                    matching: "embedded app directory"
                )
            ),
            status: .completed,
            startedAt: now.addingTimeInterval(-3),
            finishedAt: now.addingTimeInterval(-2),
            issues: [],
            issueCount: 0,
            accessIssueCount: 0
        )

        let applicationReport = ApplicationScanReport(
            applications: [application],
            coverage: [applicationCoverage],
            startedAt: now.addingTimeInterval(-8),
            finishedAt: now.addingTimeInterval(-6)
        )
        let residueReport = ResidueScanReport(candidates: [residue], coverage: [residueCoverage])
        let associationReport = AppAssociationReport(
            items: [externalItem, embeddedItem],
            coverage: [externalCoverage, embeddedCoverage]
        )

        return UninstallerViewModel(
            applicationScanner: SC14MemoryApplicationScanner(report: applicationReport),
            residueScanner: SC14MemoryResidueScanner(report: residueReport),
            associationScanner: SC14MemoryAssociationScanner(report: associationReport),
            executor: SC14NoOpUninstallExecutor(),
            historyStore: SC14MemoryUninstallHistoryStore(),
            ignoreList: ignoreList
        )
    }
}

private struct SC14MemoryApplicationScanner: ApplicationScanning {
    let report: ApplicationScanReport

    func scan(
        progress: @escaping @Sendable (ApplicationScanProgress) async -> Void
    ) async throws -> ApplicationScanReport {
        await progress(ApplicationScanProgress(
            currentPath: "SC-1.4 内存预览",
            discoveredCount: report.applications.count,
            measuredCount: report.applications.count
        ))
        return report
    }
}

private struct SC14MemoryResidueScanner: AppResidueScanning {
    let report: ResidueScanReport
    func scan(for application: InstalledApplication) async -> ResidueScanReport { report }
}

private struct SC14MemoryAssociationScanner: AppAssociationScanning {
    let report: AppAssociationReport
    func scan(for application: InstalledApplication) async -> AppAssociationReport { report }
}

private struct SC14NoOpUninstallExecutor: UninstallExecuting {
    func moveToTrash(
        candidates: [UninstallItemCandidate],
        progress: @escaping @Sendable (UninstallProgress) async -> Void
    ) async -> UninstallExecutionReport {
        UninstallExecutionReport(
            applicationName: candidates.first?.applicationName ?? "预览",
            bundleIdentifier: candidates.first?.bundleIdentifier ?? "",
            requestedCount: candidates.count,
            movedCount: 0,
            movedBytes: 0,
            applicationMoved: false,
            failures: [],
            cancelled: true,
            finishedAt: Date()
        )
    }
}

private actor SC14MemoryUninstallHistoryStore: UninstallHistoryStoring {
    func load() async -> [UninstallHistoryEntry] { [] }
    func append(_ entry: UninstallHistoryEntry) async throws {}
}
#endif
