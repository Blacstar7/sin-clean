#if DEBUG
import SwiftUI

@MainActor
struct SC32SpaceAnalysisScopePreview: View {
    enum Mode {
        case empty
        case selected
        case conflict
        case duplicate
    }

    @StateObject private var navigation = AppNavigationState()
    @StateObject private var ignoreList: IgnoreListStore
    @StateObject private var cleanupViewModel: CleanupViewModel
    @StateObject private var scopeViewModel: SpaceAnalysisScopeViewModel

    init(mode: Mode) {
        let ignoreList = IgnoreListStore(
            repository: InMemoryIgnoreRuleRepository(),
            autoload: false
        )
        let selectedScopes: [SpaceAnalysisScope]
        let rejection: SpaceAnalysisScopeRejection?
        switch mode {
        case .empty:
            selectedScopes = []
            rejection = nil
        case .selected:
            selectedScopes = [
                SpaceAnalysisScope(displayName: "文稿", path: "/Preview/Home/Documents", source: .common),
                SpaceAnalysisScope(displayName: "设计资料", path: "/Preview/Projects/Design", source: .chosenDirectory)
            ]
            rejection = nil
        case .conflict:
            selectedScopes = [
                SpaceAnalysisScope(displayName: "项目资料", path: "/Preview/Projects", source: .chosenDirectory)
            ]
            rejection = .coveredBySelectedParent(
                path: "/Preview/Projects/Design",
                parentPath: "/Preview/Projects"
            )
        case .duplicate:
            selectedScopes = [
                SpaceAnalysisScope(displayName: "文稿", path: "/Preview/Home/Documents", source: .common)
            ]
            rejection = .duplicate(path: "/Preview/Home/Documents")
        }

        _ignoreList = StateObject(wrappedValue: ignoreList)
        _cleanupViewModel = StateObject(wrappedValue: CleanupViewModel(
            scanner: SC32DisabledDiskScanner(),
            executor: SC32DisabledCleanupExecutor(),
            historyStore: SC32InMemoryCleanupHistoryStore(),
            ignoreList: ignoreList
        ))
        _scopeViewModel = StateObject(wrappedValue: SpaceAnalysisScopeViewModel(
            homeDirectory: URL(fileURLWithPath: "/Preview/Home", isDirectory: true),
            validator: SC32PreviewScopeValidator(),
            directoryChooser: SC32CancelledDirectoryChooser(),
            initialScopes: selectedScopes,
            initialRejection: rejection
        ))
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            SpaceCleanupView {
                CleanupView(previewViewModel: cleanupViewModel, ignoreList: ignoreList)
            }
        }
        .tint(AppTheme.accent)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .environmentObject(navigation)
        .environmentObject(scopeViewModel)
        .task {
            navigation.selectSpaceCleanupPage(.spaceAnalysis)
        }
    }
}

private struct SC32PreviewScopeValidator: SpaceAnalysisScopeValidating {
    // 纯词法预览校验：只比较注入的内存路径，不做任何文件系统查询，
    // 不读取真实用户目录。重复、覆盖与冲突判定与生产校验器使用同一套词法语义。
    func validate(
        _ candidate: SpaceAnalysisScopeCandidate,
        existingScopes: [SpaceAnalysisScope]
    ) -> SpaceAnalysisScopeValidationResult {
        guard candidate.path.hasPrefix("/") else {
            return .rejected(.pathIsNotAbsolute(path: candidate.path))
        }
        let normalized = SpaceAnalysisScopeValidator.lexicallyNormalizedAbsolutePath(candidate.path)
        guard normalized != "/" else {
            return .rejected(.systemRoot(path: normalized))
        }
        if existingScopes.contains(where: { $0.path == normalized }) {
            return .rejected(.duplicate(path: normalized))
        }
        if let parent = existingScopes.first(where: {
            SpaceAnalysisScopeValidator.isStrictAncestor($0.path, of: normalized)
        }) {
            return .rejected(.coveredBySelectedParent(
                path: normalized,
                parentPath: parent.path
            ))
        }
        if let child = existingScopes.first(where: {
            SpaceAnalysisScopeValidator.isStrictAncestor(normalized, of: $0.path)
        }) {
            return .rejected(.conflictsWithSelectedChild(
                path: normalized,
                childPath: child.path
            ))
        }
        return .accepted(SpaceAnalysisScope(
            displayName: candidate.displayName,
            path: normalized,
            source: candidate.source
        ))
    }
}

@MainActor
private struct SC32CancelledDirectoryChooser: SpaceAnalysisDirectoryChoosing {
    func chooseDirectories() -> SpaceAnalysisDirectoryChoice { .cancelled }
}

private struct SC32DisabledDiskScanner: DiskScanning {
    func scan(
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> CleanupScanReport {
        throw SC32PreviewError.disabled
    }
}

private actor SC32DisabledCleanupExecutor: CleanupExecuting {
    func moveToTrash(
        candidates: [CleanupFileCandidate],
        progress: @escaping @Sendable (CleanupExecutionProgress) async -> Void
    ) async -> CleanupExecutionReport {
        CleanupExecutionReport(
            requestedCount: candidates.count,
            requestedBytes: 0,
            movedCount: 0,
            movedBytes: 0,
            failures: [],
            cancelled: true,
            finishedAt: Date()
        )
    }
}

private actor SC32InMemoryCleanupHistoryStore: CleanupHistoryStoring {
    func load() async -> [CleanupHistoryEntry] { [] }
    func append(_ entry: CleanupHistoryEntry) async throws {}
}

private enum SC32PreviewError: LocalizedError {
    case disabled

    var errorDescription: String? {
        "SC-3.2 DEBUG 预览已禁用磁盘扫描和文件执行。"
    }
}
#endif
