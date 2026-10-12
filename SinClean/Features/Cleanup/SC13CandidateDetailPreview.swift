#if DEBUG
import Foundation
import SwiftUI

@MainActor
struct SC13CandidateDetailPreview: View {
    enum Mode {
        case detail
        case empty
        case stale
    }

    @StateObject private var viewModel: CleanupViewModel
    @StateObject private var actionCoordinator: CandidateFileActionCoordinator
    @StateObject private var ignoreList: IgnoreListStore
    @State private var didPresentStaleAlert = false

    private let result: CleanupScanResult
    private let highlightedCandidateID: String?
    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        let fixture = Self.makeFixture(empty: mode == .empty)
        result = fixture.result
        highlightedCandidateID = fixture.result.candidates.first?.id

        let scanner = SC13PreviewScanner(report: CleanupScanReport(
            results: [fixture.result],
            startedAt: fixture.context.startedAt,
            finishedAt: fixture.context.startedAt
        ))
        let ignoreList = IgnoreListStore(repository: InMemoryIgnoreRuleRepository(), autoload: false)
        _ignoreList = StateObject(wrappedValue: ignoreList)
        _viewModel = StateObject(wrappedValue: CleanupViewModel(
            scanner: scanner,
            executor: SC13PreviewExecutor(),
            historyStore: SC13PreviewHistoryStore(),
            ignoreList: ignoreList
        ))
        _actionCoordinator = StateObject(wrappedValue: CandidateFileActionCoordinator(
            validator: SC13PreviewIdentityValidator(isValid: mode != .stale),
            externalActions: SC13PreviewExternalActions()
        ))
    }

    var body: some View {
        CandidateReviewSheet(
            result: result,
            viewModel: viewModel,
            actionCoordinator: actionCoordinator,
            ignoreList: ignoreList,
            initialHighlightedCandidateID: highlightedCandidateID
        )
        .frame(minWidth: 760, minHeight: 590)
        .preferredColorScheme(.dark)
        .onAppear {
            guard mode == .stale,
                  !didPresentStaleAlert,
                  let candidate = result.candidates.first else { return }
            didPresentStaleAlert = true
            actionCoordinator.revealInFinder(candidate)
        }
    }

    private static func makeFixture(empty: Bool) -> (
        context: ScanContext,
        result: CleanupScanResult
    ) {
        let context = ScanContext()
        let scope = ScanScope(
            id: "disk:user-caches",
            scanner: .disk,
            phase: .discover,
            rootPath: "/Users/demo/Library/Caches",
            policy: ScanPolicy(
                recursive: true,
                acceptedTypes: ["regularFile"],
                excludedPackageExtensions: ["app", "bundle", "framework"],
                matching: CandidateRuleCode.userCaches.rawValue,
                directoryOpenTimeout: 1
            )
        )
        let longPath = "/Users/demo/Library/Caches/com.example.creative-suite/Session Data/Very Long Workspace Name/Exports/2026-09-12/preview-render-cache-file.data"
        let first = CleanupFileCandidate(
            id: longPath,
            locationID: "user-caches",
            rootPath: scope.rootPath,
            path: longPath,
            allocatedBytes: 18_874_368,
            logicalBytes: 18_103_221,
            modifiedAt: Date(timeIntervalSince1970: 1_757_648_523),
            modifiedSeconds: 1_757_648_523,
            modifiedNanoseconds: 421_000_000,
            deviceID: 1,
            inode: 42,
            risk: .safe,
            evidenceOrigin: CandidateEvidenceOrigin(
                context: context,
                scopeID: scope.id,
                reasonCode: .userCaches
            )
        )
        let secondPath = "/Users/demo/Library/Caches/com.example.editor/index.cache"
        let second = CleanupFileCandidate(
            id: secondPath,
            locationID: "user-caches",
            rootPath: scope.rootPath,
            path: secondPath,
            allocatedBytes: 5_242_880,
            logicalBytes: 5_100_000,
            modifiedAt: Date(timeIntervalSince1970: 1_757_640_000),
            modifiedSeconds: 1_757_640_000,
            modifiedNanoseconds: 0,
            deviceID: 1,
            inode: 43,
            risk: .safe,
            evidenceOrigin: CandidateEvidenceOrigin(
                context: context,
                scopeID: scope.id,
                reasonCode: .userCaches
            )
        )
        let issues = [
            ScanIssue(
                scopeID: scope.id,
                path: "/Users/demo/Library/Caches/restricted",
                phase: .discover,
                kind: .accessFailure,
                restrictionReason: nil,
                underlyingErrorDomain: NSPOSIXErrorDomain,
                underlyingErrorCode: 13,
                message: "Permission denied",
                affectsCompleteness: true,
                projectsToLegacyAccessIssues: true
            ),
            ScanIssue(
                scopeID: scope.id,
                path: "/Users/demo/Library/Caches/broken-metadata",
                phase: .discover,
                kind: .parseFailure,
                restrictionReason: nil,
                underlyingErrorDomain: NSCocoaErrorDomain,
                underlyingErrorCode: 3840,
                message: "无法解析元数据",
                affectsCompleteness: true,
                projectsToLegacyAccessIssues: false
            ),
            ScanIssue(
                scopeID: scope.id,
                path: "/Users/demo/Library/Caches/example.app",
                phase: .discover,
                kind: .policySkip,
                restrictionReason: .packageBoundary,
                underlyingErrorDomain: nil,
                underlyingErrorCode: nil,
                message: "按固定包目录边界停止下探",
                affectsCompleteness: false,
                projectsToLegacyAccessIssues: false
            )
        ]
        let coverage = ScanCoverage(
            context: context,
            scope: scope,
            status: empty ? .completed : .partial,
            startedAt: context.startedAt,
            finishedAt: context.startedAt,
            issues: empty ? [] : issues,
            issueCount: empty ? 0 : 6,
            accessIssueCount: empty ? 0 : 1
        )
        let candidates = empty ? [] : [first, second]
        return (
            context,
            CleanupScanResult(
                id: "user-caches",
                name: "用户与应用缓存",
                description: "应用运行产生的缓存文件",
                sourcePath: scope.rootPath,
                risk: .safe,
                totalBytes: candidates.reduce(0) { $0 + $1.allocatedBytes },
                fileCount: candidates.count,
                candidates: candidates,
                coverage: [coverage]
            )
        )
    }
}

private struct SC13PreviewScanner: DiskScanning {
    let report: CleanupScanReport

    func scan(
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> CleanupScanReport {
        report
    }
}

private actor SC13PreviewExecutor: CleanupExecuting {
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

private actor SC13PreviewHistoryStore: CleanupHistoryStoring {
    func load() async -> [CleanupHistoryEntry] { [] }
    func append(_ entry: CleanupHistoryEntry) async throws {}
}

private struct SC13PreviewIdentityValidator: CandidateFileIdentityValidating {
    let isValid: Bool

    func validate(_ candidate: CleanupFileCandidate) -> CandidateFileIdentityValidation {
        isValid
            ? .valid(URL(fileURLWithPath: candidate.path))
            : .rejected(.modificationTimeChanged)
    }
}

@MainActor
private final class SC13PreviewExternalActions: CandidateExternalActionPerforming {
    func revealInFinder(_ url: URL) {}

    func preview(
        candidate: CleanupFileCandidate,
        validator: any CandidateFileIdentityValidating,
        invalidationHandler: @escaping @MainActor () -> Void
    ) -> Bool {
        true
    }

    func endCandidateReview() {}
}
#endif
