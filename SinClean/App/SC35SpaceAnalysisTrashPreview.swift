#if DEBUG
import AppKit
import Foundation
import SwiftUI

// SC-3.5 手动处理预览：覆盖「未选择／已选择待审阅／执行中／部分失败／全部成功／已取消」六个状态。
//
// 边界声明：
// - 扫描器、安全核心、执行器、收据全部走**生产实现**，预览不替换任何生产语义。
// - 唯一被操作的对象是预览自身在 /tmp 下新建的夹具目录与其合成文件，
//   不读取、不选择、不移动任何真实用户文件；被移动的夹具路径由预览日志逐条打印。
// - 大文件阈值在预览内被下调为 1 MB，使夹具无需写到 50 MB 以上即可进入同一代码路径。
// - 为验证「审阅后文件被外部移走」的失败表达，部分失败模式会用同一条系统废纸篓调用
//   移走一个夹具；预览中不存在任何永久删除调用。
@MainActor
struct SC35SpaceAnalysisTrashPreview: View {
    enum Mode: String, CaseIterable {
        case unselected
        case selected
        case executing
        case partialFailure = "partial"
        case succeeded
        case cancelled
    }

    @StateObject private var navigation = AppNavigationState()
    @StateObject private var ignoreList: IgnoreListStore
    @StateObject private var cleanupViewModel: CleanupViewModel
    @StateObject private var scopeViewModel: SpaceAnalysisScopeViewModel
    @StateObject private var resultsViewModel: SpaceAnalysisResultsViewModel
    @StateObject private var trashViewModel: SpaceAnalysisTrashViewModel

    private let mode: Mode
    private let fixtureRoot: String

    init(mode: Mode) {
        self.mode = mode
        let root = SC35PreviewFixtures.rootPath(for: mode)
        self.fixtureRoot = root

        let ignoreList = IgnoreListStore(
            repository: InMemoryIgnoreRuleRepository(),
            autoload: false
        )
        _ignoreList = StateObject(wrappedValue: ignoreList)
        _cleanupViewModel = StateObject(wrappedValue: CleanupViewModel(
            scanner: SC35DisabledDiskScanner(),
            executor: SC35DisabledCleanupExecutor(),
            historyStore: SC35InMemoryCleanupHistoryStore(),
            ignoreList: ignoreList
        ))
        _scopeViewModel = StateObject(wrappedValue: SpaceAnalysisScopeViewModel(
            homeDirectory: URL(fileURLWithPath: root, isDirectory: true),
            validator: SC35PreviewScopeValidator(),
            directoryChooser: SC35CancelledDirectoryChooser(),
            initialScopes: [
                SpaceAnalysisScope(
                    displayName: "手动处理夹具",
                    path: root,
                    source: .common
                )
            ],
            initialRejection: nil
        ))
        _resultsViewModel = StateObject(wrappedValue: SpaceAnalysisResultsViewModel(
            scanner: SpaceAnalysisScanner(),
            ignoreList: ignoreList
        ))
        _trashViewModel = StateObject(wrappedValue: SpaceAnalysisTrashViewModel(
            executor: SpaceAnalysisTrashExecutor(mover: SC35PreviewFixtures.mover(for: mode)),
            ignoreList: ignoreList
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
        .environmentObject(resultsViewModel)
        .environmentObject(trashViewModel)
        .task { await runFixtureScenario() }
    }

    // MARK: - 场景编排

    private func runFixtureScenario() async {
        navigation.selectSpaceCleanupPage(.spaceAnalysis)
        guard resultsViewModel.phase == .idle else { return }

        let created = SC35PreviewFixtures.prepare(root: fixtureRoot)
        print("SC-3.5 preview fixture root: \(fixtureRoot)")
        for path in created {
            print("SC-3.5 preview fixture file: \(path)")
        }

        resultsViewModel.largeFileRule = SC35PreviewFixtures.previewLargeFileRule
        resultsViewModel.startScan(scopes: scopeViewModel.selectedScopes)
        await waitForOutcome()

        let entries = resultsViewModel.largeFiles
        print("SC-3.5 preview large file entries: \(entries.count)")

        switch mode {
        case .unselected:
            break

        case .selected:
            selectAll(entries)
            trashViewModel.freezePlan(entries: entries)

        case .executing:
            selectAll(entries)
            trashViewModel.execute(entries: entries)

        case .partialFailure:
            selectAll(entries)
            trashViewModel.freezePlan(entries: entries)
            if let victim = entries.last {
                // 模拟「审阅之后、执行之前」文件被外部移走，验证逐项失败表达。
                SC35PreviewFixtures.simulateExternalRemoval(path: victim.path)
                print("SC-3.5 preview external removal: \(victim.path)")
            }
            trashViewModel.execute(entries: entries)
            await waitForFinished()

        case .succeeded:
            selectAll(entries)
            trashViewModel.execute(entries: entries)
            await waitForFinished()

        case .cancelled:
            selectAll(entries)
            trashViewModel.execute(entries: entries)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            trashViewModel.cancelExecution()
            await waitForFinished()
        }

        if let receipt = trashViewModel.receipt {
            for item in receipt.items {
                print("SC-3.5 preview receipt: moved=\(item.movedToTrash) code=\(item.reasonCode) path=\(item.path)")
            }
        }
    }

    private func selectAll(_ entries: [SpaceAnalysisEntry]) {
        for entry in entries {
            trashViewModel.toggleSelection(entry)
        }
    }

    private func waitForOutcome() async {
        for _ in 0..<200 {
            if resultsViewModel.outcome != nil { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitForFinished() async {
        for _ in 0..<400 {
            if trashViewModel.phase == .finished { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - 夹具

private enum SC35PreviewFixtures {
    /// 预览用阈值：1 MB。生产默认值仍为 100 MB，预览不改动任何生产默认。
    static let previewLargeFileRule = SpaceAnalysisLargeFileRule(minimumBytes: 1_048_576)

    static let fileNames = [
        "手动处理夹具甲.bin",
        "手动处理夹具乙.bin",
        "手动处理夹具丙.bin"
    ]

    static let fileSizes: [Int64] = [
        3 * 1_048_576 + 262_144,
        2 * 1_048_576 + 131_072,
        1 * 1_048_576 + 65_536
    ]

    static func rootPath(for mode: SC35SpaceAnalysisTrashPreview.Mode) -> String {
        "/tmp/SinClean-SC35-preview-\(mode.rawValue)-\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// 只对执行中模式施加延迟：延迟发生在唯一破坏性动作之前，因此该模式在证据采集期间不会移动任何文件。
    static func mover(for mode: SC35SpaceAnalysisTrashPreview.Mode) -> any TrashMoving {
        switch mode {
        case .executing:
            return SC35DelayedTrashMover(delay: 30)
        case .cancelled:
            return SC35DelayedTrashMover(delay: 1.5)
        case .unselected, .selected, .partialFailure, .succeeded:
            return SystemTrashMover()
        }
    }

    @discardableResult
    static func prepare(root: String) -> [String] {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: root, withIntermediateDirectories: true)
        var created: [String] = []
        for (index, name) in fileNames.enumerated() {
            let path = root + "/" + name
            let size = fileSizes[index]
            manager.createFile(atPath: path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: path) else { continue }
            var remaining = size
            let chunk = Data(repeating: UInt8(0x53 + index), count: 1_048_576)
            while remaining > 0 {
                let slice = remaining >= Int64(chunk.count)
                    ? chunk
                    : chunk.prefix(Int(remaining))
                handle.write(Data(slice))
                remaining -= Int64(slice.count)
            }
            try? handle.close()
            created.append(path)
        }
        return created
    }

    /// 模拟审阅后文件被外部移走：仍只使用既有系统废纸篓实现，不引入永久删除。
    static func simulateExternalRemoval(path: String) {
        try? SystemTrashMover().moveToTrash(URL(fileURLWithPath: path))
    }
}

// 预览专用延迟包装：既有 `TrashMoving` 是同步协议，因此这里同步等待。
// 该等待发生在执行器 actor 上（非主线程），且只用于 DEBUG 预览的时间窗；
// 生产路径不包含任何延迟。
private struct SC35DelayedTrashMover: TrashMoving {
    let delay: TimeInterval

    func moveToTrash(_ url: URL) throws {
        Thread.sleep(forTimeInterval: delay)
        try SystemTrashMover().moveToTrash(url)
    }
}

// MARK: - 预览占位实现（清理域一律禁用）

private struct SC35PreviewScopeValidator: SpaceAnalysisScopeValidating {
    func validate(
        _ candidate: SpaceAnalysisScopeCandidate,
        existingScopes: [SpaceAnalysisScope]
    ) -> SpaceAnalysisScopeValidationResult {
        .accepted(SpaceAnalysisScope(
            displayName: candidate.displayName,
            path: candidate.path,
            source: candidate.source
        ))
    }
}

@MainActor
private struct SC35CancelledDirectoryChooser: SpaceAnalysisDirectoryChoosing {
    func chooseDirectories() -> SpaceAnalysisDirectoryChoice { .cancelled }
}

private struct SC35DisabledDiskScanner: DiskScanning {
    func scan(
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> CleanupScanReport {
        throw SC35PreviewError.disabled
    }
}

private actor SC35DisabledCleanupExecutor: CleanupExecuting {
    func moveToTrash(
        candidates: [CleanupFileCandidate],
        progress: @escaping @Sendable (CleanupExecutionProgress) async -> Void
    ) -> CleanupExecutionReport {
        CleanupExecutionReport(
            requestedCount: candidates.count,
            requestedBytes: 0,
            movedCount: 0,
            movedBytes: 0,
            failures: [],
            cancelled: true,
            finishedAt: Date(timeIntervalSince1970: 1_789_000_000)
        )
    }
}

private actor SC35InMemoryCleanupHistoryStore: CleanupHistoryStoring {
    func load() async -> [CleanupHistoryEntry] { [] }
    func append(_ entry: CleanupHistoryEntry) async throws {}
}

private enum SC35PreviewError: LocalizedError {
    case disabled

    var errorDescription: String? {
        "SC-3.5 DEBUG 预览已禁用清理域磁盘扫描与文件执行。"
    }
}
#endif
