#if DEBUG
import Foundation
import SwiftUI

@MainActor
struct SC22PlanExportPreview: View {
    private enum Domain: String, CaseIterable, Identifiable {
        case cleanup = "磁盘清理"
        case uninstall = "应用卸载"

        var id: Self { self }
    }

    @StateObject private var cleanupIgnoreList: IgnoreListStore
    @StateObject private var uninstallIgnoreList: IgnoreListStore
    @StateObject private var cleanupViewModel: CleanupViewModel
    @StateObject private var uninstallViewModel: UninstallerViewModel
    @State private var domain: Domain = .cleanup
    @State private var prepared = false

    private let cleanupCandidate: CleanupFileCandidate
    private let uninstallResidue: AppResidueCandidate

    init() {
        let fixture = Self.makeFixture()
        let cleanupIgnoreList = IgnoreListStore(repository: InMemoryIgnoreRuleRepository(), autoload: false)
        let uninstallIgnoreList = IgnoreListStore(repository: InMemoryIgnoreRuleRepository(), autoload: false)
        _cleanupIgnoreList = StateObject(wrappedValue: cleanupIgnoreList)
        _uninstallIgnoreList = StateObject(wrappedValue: uninstallIgnoreList)
        _cleanupViewModel = StateObject(wrappedValue: CleanupViewModel(
            scanner: SC22MemoryDiskScanner(report: fixture.cleanupReport),
            executor: SC22NoOpCleanupExecutor(),
            historyStore: SC22MemoryCleanupHistoryStore(),
            ignoreList: cleanupIgnoreList
        ))
        _uninstallViewModel = StateObject(wrappedValue: UninstallerViewModel(
            applicationScanner: SC22MemoryApplicationScanner(report: fixture.applicationReport),
            residueScanner: SC22MemoryResidueScanner(report: fixture.residueReport),
            associationScanner: SC22MemoryAssociationScanner(report: fixture.associationReport),
            executor: SC22NoOpUninstallExecutor(),
            historyStore: SC22MemoryUninstallHistoryStore(),
            ignoreList: uninstallIgnoreList
        ))
        cleanupCandidate = fixture.cleanupCandidate
        uninstallResidue = fixture.residue
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("SC-2.2 计划导出 · 纯内存预览")
                        .font(.headline)
                    Text("保存面板验收只取消；不运行生产扫描、执行器或废纸篓 API。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("清理已选 \(cleanupViewModel.selectedFileCount)", systemImage: "checkmark.square")
                Label("卸载残留已选 \(uninstallViewModel.selectedResidueCount)", systemImage: "shippingbox")
                Picker("预览领域", selection: $domain) {
                    ForEach(Domain.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .accessibilityLabel("切换计划导出预览领域")
                .accessibilityHint("在磁盘清理和应用卸载导出入口之间切换")
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md)
            .background(AppTheme.cardSurface)

            Divider()

            Group {
                switch domain {
                case .cleanup:
                    CleanupView(previewViewModel: cleanupViewModel, ignoreList: cleanupIgnoreList)
                case .uninstall:
                    UninstallerView(previewViewModel: uninstallViewModel, ignoreList: uninstallIgnoreList)
                }
            }
            .environmentObject(AppSettings())
            .environmentObject(AppNavigationState())
        }
        .background(AuroraBackground())
        .preferredColorScheme(.dark)
        .task {
            guard !prepared else { return }
            prepared = true
            cleanupViewModel.startScan()
            uninstallViewModel.startScan()
            for _ in 0..<20_000 {
                if cleanupViewModel.phase == .completed,
                   uninstallViewModel.residuePhase == .completed,
                   uninstallViewModel.associationPhase == .completed {
                    cleanupViewModel.setSelected(true, candidate: cleanupCandidate)
                    uninstallViewModel.setResidueSelected(true, candidate: uninstallResidue)
                    return
                }
                await Task.yield()
            }
        }
    }

    private static func makeFixture() -> SC22PreviewFixture {
        let now = Date(timeIntervalSince1970: 1_800_100_000)
        let cleanupContext = ScanContext()
        let cleanupRoot = "/Users/preview/Library/Caches"
        let cleanupScope = ScanScope(
            id: "disk:user-caches",
            scanner: .disk,
            phase: .discover,
            rootPath: cleanupRoot,
            policy: ScanPolicy(recursive: true, acceptedTypes: ["regularFile"], matching: CandidateRuleCode.userCaches.rawValue)
        )
        let cleanupCandidate = CleanupFileCandidate(
            id: "sc22-cleanup-cache",
            locationID: "user-caches",
            rootPath: cleanupRoot,
            path: "\(cleanupRoot)/com.example.editor/render-cache.bin",
            allocatedBytes: 42_467_328,
            logicalBytes: 40_104_811,
            modifiedAt: now,
            modifiedSeconds: Int64(now.timeIntervalSince1970),
            modifiedNanoseconds: 123_000_000,
            deviceID: 1,
            inode: 7_201,
            risk: .safe,
            evidenceOrigin: CandidateEvidenceOrigin(
                context: cleanupContext,
                scopeID: cleanupScope.id,
                reasonCode: .userCaches
            )
        )
        let cleanupCoverage = ScanCoverage(
            context: cleanupContext,
            scope: cleanupScope,
            status: .completed,
            startedAt: now.addingTimeInterval(-3),
            finishedAt: now,
            issues: [],
            issueCount: 0,
            accessIssueCount: 0
        )
        let cleanupResult = CleanupScanResult(
            id: "user-caches",
            name: "用户与应用缓存",
            description: "纯内存候选，用于验证统一计划导出入口",
            sourcePath: cleanupRoot,
            risk: .safe,
            totalBytes: cleanupCandidate.allocatedBytes,
            fileCount: 1,
            candidates: [cleanupCandidate],
            coverage: [cleanupCoverage]
        )
        let cleanupReport = CleanupScanReport(results: [cleanupResult], startedAt: now.addingTimeInterval(-3), finishedAt: now)

        let applicationContext = ScanContext()
        let applicationRoot = "/Applications"
        let bundleIdentifier = "com.example.ExportPreview"
        let applicationScope = ScanScope(
            id: "application:/Applications",
            scanner: .application,
            phase: .discover,
            rootPath: applicationRoot,
            policy: ScanPolicy(recursive: true, maximumDepth: 2, acceptedTypes: ["directory"], extensions: ["app"], matching: CandidateRuleCode.applicationDirectory.rawValue)
        )
        let application = InstalledApplication(
            id: "sc22-preview-application",
            name: "Export Preview",
            path: "/Applications/Export Preview.app",
            rootPath: applicationRoot,
            bundleIdentifier: bundleIdentifier,
            version: "2.2",
            buildNumber: "220",
            allocatedBytes: 150_994_944,
            logicalBytes: 154_140_672,
            modifiedSeconds: Int64(now.timeIntervalSince1970),
            modifiedNanoseconds: 456_000_000,
            deviceID: 1,
            inode: 7_202,
            signatureState: .valid,
            signer: "Developer ID Application: Preview Studio",
            teamIdentifier: "PREVIEWTEAM",
            evidenceOrigin: CandidateEvidenceOrigin(
                context: applicationContext,
                scopeID: applicationScope.id,
                reasonCode: .applicationDirectory,
                matchedValue: ".app"
            )
        )
        let applicationCoverage = ScanCoverage(
            context: applicationContext,
            scope: applicationScope,
            status: .completed,
            startedAt: now.addingTimeInterval(-5),
            finishedAt: now.addingTimeInterval(-4),
            issues: [],
            issueCount: 0,
            accessIssueCount: 0
        )
        let applicationReport = ApplicationScanReport(
            applications: [application],
            coverage: [applicationCoverage],
            startedAt: now.addingTimeInterval(-5),
            finishedAt: now.addingTimeInterval(-4)
        )

        let residueContext = ScanContext()
        let residueRoot = "/Users/preview/Library/Caches"
        let residueScope = ScanScope(
            id: CandidateRuleCode.residueCache.rawValue,
            scanner: .residue,
            phase: .inspect,
            rootPath: residueRoot,
            targetPath: "\(residueRoot)/\(bundleIdentifier)",
            applicationID: application.id,
            bundleIdentifier: bundleIdentifier,
            policy: ScanPolicy(recursive: false, matching: CandidateRuleCode.residueCache.rawValue)
        )
        let residue = AppResidueCandidate(
            id: "sc22-preview-residue",
            bundleIdentifier: bundleIdentifier,
            kind: .cache,
            path: "\(residueRoot)/\(bundleIdentifier)",
            rootPath: residueRoot,
            allocatedBytes: 12_582_912,
            logicalBytes: 13_000_000,
            modifiedSeconds: Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970),
            modifiedNanoseconds: 789_000_000,
            deviceID: 1,
            inode: 7_203,
            isDirectory: true,
            matchReason: "固定路径与 Bundle Identifier 精确匹配",
            evidenceOrigin: CandidateEvidenceOrigin(
                context: residueContext,
                scopeID: residueScope.id,
                reasonCode: .residueCache,
                matchedValue: bundleIdentifier
            )
        )
        let residueIssue = ScanIssue(
            scopeID: residueScope.id,
            path: "\(residueRoot)/restricted-sibling",
            phase: .inspect,
            kind: .accessFailure,
            restrictionReason: nil,
            underlyingErrorDomain: NSPOSIXErrorDomain,
            underlyingErrorCode: 13,
            message: "同一范围内另一路径无法读取。",
            affectsCompleteness: true,
            projectsToLegacyAccessIssues: true
        )
        let residueCoverage = ScanCoverage(
            context: residueContext,
            scope: residueScope,
            status: .partial,
            startedAt: now.addingTimeInterval(-3),
            finishedAt: now.addingTimeInterval(-1),
            issues: [residueIssue],
            issueCount: 2,
            accessIssueCount: 1
        )
        let residueReport = ResidueScanReport(candidates: [residue], coverage: [residueCoverage])

        let associationContext = ScanContext()
        let association = AppAssociatedItem(
            id: "sc22-preview-association",
            kind: .packageReceipt,
            path: "com.example.ExportPreview.pkg",
            identifier: "com.example.ExportPreview.pkg",
            relationship: .exactNamespace,
            isInsideApplicationBundle: false,
            evidenceOrigin: CandidateEvidenceOrigin(
                context: associationContext,
                scopeID: "association:receipts",
                reasonCode: .receiptNamespace,
                matchedValue: bundleIdentifier
            ),
            associatedBundleIdentifier: bundleIdentifier,
            observedModifiedAt: now.addingTimeInterval(-172_800)
        )
        let associationReport = AppAssociationReport(items: [association], coverage: [])

        return SC22PreviewFixture(
            cleanupCandidate: cleanupCandidate,
            cleanupReport: cleanupReport,
            applicationReport: applicationReport,
            residue: residue,
            residueReport: residueReport,
            associationReport: associationReport
        )
    }
}

private struct SC22PreviewFixture {
    let cleanupCandidate: CleanupFileCandidate
    let cleanupReport: CleanupScanReport
    let applicationReport: ApplicationScanReport
    let residue: AppResidueCandidate
    let residueReport: ResidueScanReport
    let associationReport: AppAssociationReport
}

private struct SC22MemoryDiskScanner: DiskScanning {
    let report: CleanupScanReport
    func scan(progress: @escaping @Sendable (CleanupScanProgress) async -> Void) async throws -> CleanupScanReport { report }
}

private struct SC22MemoryApplicationScanner: ApplicationScanning {
    let report: ApplicationScanReport
    func scan(progress: @escaping @Sendable (ApplicationScanProgress) async -> Void) async throws -> ApplicationScanReport { report }
}

private struct SC22MemoryResidueScanner: AppResidueScanning {
    let report: ResidueScanReport
    func scan(for application: InstalledApplication) async -> ResidueScanReport { report }
}

private struct SC22MemoryAssociationScanner: AppAssociationScanning {
    let report: AppAssociationReport
    func scan(for application: InstalledApplication) async -> AppAssociationReport { report }
}

private actor SC22NoOpCleanupExecutor: CleanupExecuting {
    func moveToTrash(
        candidates: [CleanupFileCandidate],
        progress: @escaping @Sendable (CleanupExecutionProgress) async -> Void
    ) async -> CleanupExecutionReport {
        CleanupExecutionReport(
            requestedCount: candidates.count,
            requestedBytes: candidates.reduce(0) { $0 + $1.allocatedBytes },
            movedCount: 0,
            movedBytes: 0,
            failures: [],
            cancelled: true,
            finishedAt: Date()
        )
    }
}

private struct SC22NoOpUninstallExecutor: UninstallExecuting {
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

private actor SC22MemoryCleanupHistoryStore: CleanupHistoryStoring {
    func load() async -> [CleanupHistoryEntry] { [] }
    func append(_ entry: CleanupHistoryEntry) async throws {}
}

private actor SC22MemoryUninstallHistoryStore: UninstallHistoryStoring {
    func load() async -> [UninstallHistoryEntry] { [] }
    func append(_ entry: UninstallHistoryEntry) async throws {}
}
#endif
