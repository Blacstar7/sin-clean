#if DEBUG
import SwiftUI

// SC-3.3 空间分析结果预览：全部为注入的内存数据，使用 /Preview/ 假路径，
// 不读取真实用户目录、不打开目录面板、不调用生产扫描器或任何文件操作。
@MainActor
struct SC33SpaceAnalysisPreview: View {
    enum Mode: String, CaseIterable {
        case idle
        case scanning
        case results
        case partial
        case cancelled
        // SC-3.4 新增状态
        case hardlink
        case clone
        case dataless
        case crossVolume = "crossvolume"
    }

    @StateObject private var navigation = AppNavigationState()
    @StateObject private var ignoreList: IgnoreListStore
    @StateObject private var cleanupViewModel: CleanupViewModel
    @StateObject private var scopeViewModel: SpaceAnalysisScopeViewModel
    @StateObject private var resultsViewModel: SpaceAnalysisResultsViewModel
    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        let ignoreList = IgnoreListStore(
            repository: InMemoryIgnoreRuleRepository(),
            autoload: false
        )
        let scopes = [
            SpaceAnalysisScope(displayName: "文稿", path: "/Preview/Home/Documents", source: .common),
            SpaceAnalysisScope(displayName: "下载", path: "/Preview/Home/Downloads", source: .common)
        ]
        _ignoreList = StateObject(wrappedValue: ignoreList)
        _cleanupViewModel = StateObject(wrappedValue: CleanupViewModel(
            scanner: SC33DisabledDiskScanner(),
            executor: SC33DisabledCleanupExecutor(),
            historyStore: SC33InMemoryCleanupHistoryStore(),
            ignoreList: ignoreList
        ))
        _scopeViewModel = StateObject(wrappedValue: SpaceAnalysisScopeViewModel(
            homeDirectory: URL(fileURLWithPath: "/Preview/Home", isDirectory: true),
            validator: SC33PreviewScopeValidator(),
            directoryChooser: SC33CancelledDirectoryChooser(),
            initialScopes: scopes,
            initialRejection: nil
        ))
        let stub = SC33PreviewScanner(
            behavior: {
                switch mode {
                case .idle: .never
                case .scanning: .hangs
                case .results: .immediate(SC33PreviewData.outcome(partial: false, cancelled: false))
                case .partial: .immediate(SC33PreviewData.outcome(partial: true, cancelled: false))
                case .cancelled: .immediate(SC33PreviewData.outcome(partial: true, cancelled: true))
                case .hardlink: .immediate(SC33PreviewData.hardLinkOutcome())
                case .clone: .immediate(SC33PreviewData.cloneOutcome())
                case .dataless: .immediate(SC33PreviewData.datalessOutcome())
                case .crossVolume: .immediate(SC33PreviewData.crossVolumeOutcome())
                }
            }()
        )
        _resultsViewModel = StateObject(wrappedValue: SpaceAnalysisResultsViewModel(
            scanner: stub,
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
        .task {
            navigation.selectSpaceCleanupPage(.spaceAnalysis)
            if mode != .idle, resultsViewModel.phase == .idle {
                resultsViewModel.startScan(scopes: scopeViewModel.selectedScopes)
            }
        }
    }
}

// MARK: - 预览扫描器

private enum SC33PreviewScannerBehavior: Sendable {
    case never
    case hangs
    case immediate(SpaceAnalysisScanOutcome)
}

private actor SC33PreviewScanner: SpaceAnalysisScanning {
    private let behavior: SC33PreviewScannerBehavior

    init(behavior: SC33PreviewScannerBehavior) {
        self.behavior = behavior
    }

    func scan(
        scopes: [SpaceAnalysisScope],
        progress: @escaping @Sendable (SpaceAnalysisScanProgress) async -> Void
    ) async -> SpaceAnalysisScanOutcome {
        switch behavior {
        case .never:
            return SpaceAnalysisScanOutcome(
                entries: [],
                nodes: [],
                summary: SpaceAnalysisScanSummary(
                    inspectedEntryCount: 0,
                    unreadableDirectoryCount: 0,
                    skippedSymbolicLinkCount: 0,
                    unknownSizeCount: 0,
                    scannedTotalBytes: 0,
                    startedAt: Date(timeIntervalSince1970: 1_789_000_000),
                    finishedAt: Date(timeIntervalSince1970: 1_789_000_000),
                    cancelled: false
                )
            )
        case .hangs:
            await progress(SpaceAnalysisScanProgress(
                currentRoot: "文稿",
                finishedRootCount: 0,
                totalRootCount: scopes.count,
                inspectedEntryCount: 12_480,
                scannedBytes: 6_400_000_000,
                unreadableDirectoryCount: 0
            ))
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            return SpaceAnalysisScanOutcome(
                entries: [],
                nodes: [],
                summary: SpaceAnalysisScanSummary(
                    inspectedEntryCount: 0,
                    unreadableDirectoryCount: 0,
                    skippedSymbolicLinkCount: 0,
                    unknownSizeCount: 0,
                    scannedTotalBytes: 0,
                    startedAt: Date(),
                    finishedAt: Date(),
                    cancelled: true
                )
            )
        case .immediate(let outcome):
            await progress(SpaceAnalysisScanProgress(
                currentRoot: "扫描完成",
                finishedRootCount: scopes.count,
                totalRootCount: scopes.count,
                inspectedEntryCount: outcome.summary.inspectedEntryCount,
                scannedBytes: outcome.summary.scannedTotalBytes,
                unreadableDirectoryCount: outcome.summary.unreadableDirectoryCount
            ))
            return outcome
        }
    }
}

// MARK: - 预览数据（固定、确定）

private enum SC33PreviewData {
    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: text) ?? Date(timeIntervalSince1970: 1_789_000_000)
    }

    static func outcome(partial: Bool, cancelled: Bool) -> SpaceAnalysisScanOutcome {
        let documents = "/Preview/Home/Documents"
        let downloads = "/Preview/Home/Downloads"

        var nodes: [SpaceAnalysisTreeNode] = [
            SpaceAnalysisTreeNode(path: documents, displayName: "文稿", depth: 0,
                                  totalBytes: 18_400_000_000, ownFileBytes: 1_200_000_000,
                                  childDirectoryCount: 3, fileCount: 42, isReadable: true, rootPath: documents),
            SpaceAnalysisTreeNode(path: "\(documents)/视频项目", displayName: "视频项目", depth: 1,
                                  totalBytes: 12_000_000_000, ownFileBytes: 12_000_000_000,
                                  childDirectoryCount: 0, fileCount: 6, isReadable: true, rootPath: documents),
            SpaceAnalysisTreeNode(path: "\(documents)/设计资料", displayName: "设计资料", depth: 1,
                                  totalBytes: 5_200_000_000, ownFileBytes: 5_200_000_000,
                                  childDirectoryCount: 0, fileCount: 31, isReadable: true, rootPath: documents),
            SpaceAnalysisTreeNode(path: downloads, displayName: "下载", depth: 0,
                                  totalBytes: 9_600_000_000, ownFileBytes: 9_600_000_000,
                                  childDirectoryCount: 0, fileCount: 18, isReadable: true, rootPath: downloads)
        ]
        if partial {
            nodes.append(SpaceAnalysisTreeNode(path: "\(documents)/只读归档", displayName: "只读归档", depth: 1,
                                               totalBytes: 0, ownFileBytes: 0,
                                               childDirectoryCount: 0, fileCount: 0, isReadable: false, rootPath: documents))
        }

        let entries: [SpaceAnalysisEntry] = [
            SpaceAnalysisEntry(path: "\(documents)/视频项目/发布会-4K.mov", displayName: "发布会-4K.mov",
                               kind: .regularFile, allocatedBytes: 8_600_000_000, logicalBytes: 8_590_000_000,
                               modifiedAt: date("2026-05-12 09:20"), rootPath: documents),
            SpaceAnalysisEntry(path: "\(downloads)/Xcode_26_beta.xip", displayName: "Xcode_26_beta.xip",
                               kind: .regularFile, allocatedBytes: 7_400_000_000, logicalBytes: 7_390_000_000,
                               modifiedAt: date("2026-06-02 14:05"), rootPath: downloads),
            SpaceAnalysisEntry(path: "\(documents)/设计资料/品牌手册.psd", displayName: "品牌手册.psd",
                               kind: .regularFile, allocatedBytes: 3_200_000_000, logicalBytes: 3_190_000_000,
                               modifiedAt: date("2026-04-18 11:32"), rootPath: documents),
            SpaceAnalysisEntry(path: "\(documents)/视频项目/素材备份.zip", displayName: "素材备份.zip",
                               kind: .regularFile, allocatedBytes: 2_400_000_000, logicalBytes: 2_390_000_000,
                               modifiedAt: date("2026-03-09 16:48"), rootPath: documents),
            SpaceAnalysisEntry(path: "\(documents)/年度报告.pdf", displayName: "年度报告.pdf",
                               kind: .regularFile, allocatedBytes: 480_000_000, logicalBytes: 479_000_000,
                               modifiedAt: date("2026-01-22 08:15"), rootPath: documents),
            SpaceAnalysisEntry(path: "\(downloads)/旧归档.log", displayName: "旧归档.log",
                               kind: .regularFile, allocatedBytes: 220_000_000, logicalBytes: 219_000_000,
                               modifiedAt: nil, rootPath: downloads)
        ]

        return SpaceAnalysisScanOutcome(
            entries: entries,
            nodes: nodes,
            summary: SpaceAnalysisScanSummary(
                inspectedEntryCount: 27_412,
                unreadableDirectoryCount: partial ? 1 : 0,
                skippedSymbolicLinkCount: partial ? 3 : 0,
                unknownSizeCount: 0,
                scannedTotalBytes: nodes.filter { $0.depth == 0 }.reduce(Int64(0)) { $0 + $1.totalBytes },
                startedAt: date("2026-09-16 18:30"),
                finishedAt: date("2026-09-16 18:31"),
                cancelled: cancelled
            )
        )
    }
}

// MARK: - SC-3.4 场景数据（纯内存）

extension SC33PreviewData {
    /// 含硬链接：两个路径共享同一物理文件，容量只计一次。
    static func hardLinkOutcome() -> SpaceAnalysisScanOutcome {
        let documents = "/Preview/Home/Documents"
        let group = "16777232:5085303"
        let nodes: [SpaceAnalysisTreeNode] = [
            SpaceAnalysisTreeNode(path: documents, displayName: "文稿", depth: 0, totalBytes: 6_000_000_000,
                                  ownFileBytes: 6_000_000_000, childDirectoryCount: 0, fileCount: 3,
                                  isReadable: true, rootPath: documents)
        ]
        let entries: [SpaceAnalysisEntry] = [
            SpaceAnalysisEntry(path: "\(documents)/发布会.mov", displayName: "发布会.mov", kind: .regularFile,
                               allocatedBytes: 4_800_000_000, logicalBytes: 4_790_000_000,
                               modifiedAt: date("2026-05-12 09:20"), rootPath: documents, linkGroupID: group),
            SpaceAnalysisEntry(path: "\(documents)/发布会-副本.mov", displayName: "发布会-副本.mov", kind: .regularFile,
                               allocatedBytes: 4_800_000_000, logicalBytes: 4_790_000_000,
                               modifiedAt: date("2026-05-12 09:20"), rootPath: documents, linkGroupID: group),
            SpaceAnalysisEntry(path: "\(documents)/说明.txt", displayName: "说明.txt", kind: .regularFile,
                               allocatedBytes: 1_200_000_000, logicalBytes: 1_190_000_000,
                               modifiedAt: date("2026-04-01 10:00"), rootPath: documents)
        ]
        return SpaceAnalysisScanOutcome(
            entries: entries,
            nodes: nodes,
            summary: SpaceAnalysisScanSummary(
                inspectedEntryCount: 3, unreadableDirectoryCount: 0, skippedSymbolicLinkCount: 0,
                unknownSizeCount: 0, scannedTotalBytes: 6_000_000_000,
                startedAt: date("2026-09-16 21:40"), finishedAt: date("2026-09-16 21:41"), cancelled: false
            ),
            deduplication: SpaceAnalysisDeduplicationSummary(
                hardLinkGroupCount: 1, hardLinkMemberCount: 1, deduplicatedBytes: 4_800_000_000,
                crossDeviceGroupCount: 0, datalessPlaceholderCount: 0, datalessLogicalBytes: 0,
                capacityIsUpperBound: true
            )
        )
    }

    /// 含克隆可能：容量口径必须声明为上界。
    static func cloneOutcome() -> SpaceAnalysisScanOutcome {
        let documents = "/Preview/Home/Documents"
        let nodes: [SpaceAnalysisTreeNode] = [
            SpaceAnalysisTreeNode(path: documents, displayName: "文稿", depth: 0, totalBytes: 3_200_000_000,
                                  ownFileBytes: 3_200_000_000, childDirectoryCount: 0, fileCount: 2,
                                  isReadable: true, rootPath: documents)
        ]
        let entries: [SpaceAnalysisEntry] = [
            SpaceAnalysisEntry(path: "\(documents)/母版.psd", displayName: "母版.psd", kind: .regularFile,
                               allocatedBytes: 2_000_000_000, logicalBytes: 1_999_000_000,
                               modifiedAt: date("2026-03-09 16:48"), rootPath: documents),
            SpaceAnalysisEntry(path: "\(documents)/母版-副本.psd", displayName: "母版-副本.psd", kind: .regularFile,
                               allocatedBytes: 1_200_000_000, logicalBytes: 1_199_000_000,
                               modifiedAt: date("2026-03-10 08:00"), rootPath: documents)
        ]
        return SpaceAnalysisScanOutcome(
            entries: entries,
            nodes: nodes,
            summary: SpaceAnalysisScanSummary(
                inspectedEntryCount: 2, unreadableDirectoryCount: 0, skippedSymbolicLinkCount: 0,
                unknownSizeCount: 0, scannedTotalBytes: 3_200_000_000,
                startedAt: date("2026-09-16 21:42"), finishedAt: date("2026-09-16 21:43"), cancelled: false
            ),
            deduplication: SpaceAnalysisDeduplicationSummary(
                hardLinkGroupCount: 0, hardLinkMemberCount: 0, deduplicatedBytes: 0,
                crossDeviceGroupCount: 0, datalessPlaceholderCount: 0, datalessLogicalBytes: 0,
                capacityIsUpperBound: true
            )
        )
    }

    /// 含云端占位：当前不占用空间，逻辑大小单独呈现。
    static func datalessOutcome() -> SpaceAnalysisScanOutcome {
        let documents = "/Preview/Home/Documents"
        let nodes: [SpaceAnalysisTreeNode] = [
            SpaceAnalysisTreeNode(path: documents, displayName: "文稿", depth: 0, totalBytes: 700_000_000,
                                  ownFileBytes: 700_000_000, childDirectoryCount: 0, fileCount: 2,
                                  isReadable: true, rootPath: documents)
        ]
        let entries: [SpaceAnalysisEntry] = [
            SpaceAnalysisEntry(path: "\(documents)/归档项目.mov", displayName: "归档项目.mov", kind: .regularFile,
                               allocatedBytes: 0, logicalBytes: 12_400_000_000,
                               modifiedAt: date("2026-02-14 07:30"), rootPath: documents,
                               isDatalessPlaceholder: true),
            SpaceAnalysisEntry(path: "\(documents)/本地素材.bin", displayName: "本地素材.bin", kind: .regularFile,
                               allocatedBytes: 700_000_000, logicalBytes: 699_000_000,
                               modifiedAt: date("2026-06-01 12:00"), rootPath: documents)
        ]
        return SpaceAnalysisScanOutcome(
            entries: entries,
            nodes: nodes,
            summary: SpaceAnalysisScanSummary(
                inspectedEntryCount: 2, unreadableDirectoryCount: 0, skippedSymbolicLinkCount: 0,
                unknownSizeCount: 0, scannedTotalBytes: 700_000_000,
                startedAt: date("2026-09-16 21:44"), finishedAt: date("2026-09-16 21:45"), cancelled: false
            ),
            deduplication: SpaceAnalysisDeduplicationSummary(
                hardLinkGroupCount: 0, hardLinkMemberCount: 0, deduplicatedBytes: 0,
                crossDeviceGroupCount: 0, datalessPlaceholderCount: 1,
                datalessLogicalBytes: 12_400_000_000, capacityIsUpperBound: true
            )
        )
    }

    /// 跨设备：多卷范围，设备边界阻止组键合并并如实计数。
    static func crossVolumeOutcome() -> SpaceAnalysisScanOutcome {
        let internalRoot = "/Preview/Home/Documents"
        let externalRoot = "/Preview/Volumes/External/Media"
        let nodes: [SpaceAnalysisTreeNode] = [
            SpaceAnalysisTreeNode(path: internalRoot, displayName: "文稿", depth: 0, totalBytes: 2_400_000_000,
                                  ownFileBytes: 2_400_000_000, childDirectoryCount: 0, fileCount: 1,
                                  isReadable: true, rootPath: internalRoot),
            SpaceAnalysisTreeNode(path: externalRoot, displayName: "外置卷素材", depth: 0, totalBytes: 5_100_000_000,
                                  ownFileBytes: 5_100_000_000, childDirectoryCount: 0, fileCount: 2,
                                  isReadable: true, rootPath: externalRoot)
        ]
        let entries: [SpaceAnalysisEntry] = [
            SpaceAnalysisEntry(path: "\(internalRoot)/本机备份.mov", displayName: "本机备份.mov", kind: .regularFile,
                               allocatedBytes: 2_400_000_000, logicalBytes: 2_390_000_000,
                               modifiedAt: date("2026-06-20 09:00"), rootPath: internalRoot),
            SpaceAnalysisEntry(path: "\(externalRoot)/外景素材.mov", displayName: "外景素材.mov", kind: .regularFile,
                               allocatedBytes: 3_900_000_000, logicalBytes: 3_890_000_000,
                               modifiedAt: date("2026-07-02 15:30"), rootPath: externalRoot),
            SpaceAnalysisEntry(path: "\(externalRoot)/外景素材-链接.mov", displayName: "外景素材-链接.mov", kind: .regularFile,
                               allocatedBytes: 1_200_000_000, logicalBytes: 1_190_000_000,
                               modifiedAt: date("2026-07-02 15:30"), rootPath: externalRoot)
        ]
        return SpaceAnalysisScanOutcome(
            entries: entries,
            nodes: nodes,
            summary: SpaceAnalysisScanSummary(
                inspectedEntryCount: 3, unreadableDirectoryCount: 0, skippedSymbolicLinkCount: 0,
                unknownSizeCount: 0, scannedTotalBytes: 7_500_000_000,
                startedAt: date("2026-09-16 21:46"), finishedAt: date("2026-09-16 21:47"), cancelled: false
            ),
            deduplication: SpaceAnalysisDeduplicationSummary(
                hardLinkGroupCount: 1, hardLinkMemberCount: 1, deduplicatedBytes: 1_200_000_000,
                crossDeviceGroupCount: 2, datalessPlaceholderCount: 0, datalessLogicalBytes: 0,
                capacityIsUpperBound: true
            )
        )
    }
}

// MARK: - 预览依赖（纯内存，禁用的生产路径）

private struct SC33PreviewScopeValidator: SpaceAnalysisScopeValidating {
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
private struct SC33CancelledDirectoryChooser: SpaceAnalysisDirectoryChoosing {
    func chooseDirectories() -> SpaceAnalysisDirectoryChoice { .cancelled }
}

private struct SC33DisabledDiskScanner: DiskScanning {
    func scan(
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> CleanupScanReport {
        throw SC33PreviewError.disabled
    }
}

private actor SC33DisabledCleanupExecutor: CleanupExecuting {
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
            finishedAt: Date(timeIntervalSince1970: 1_789_000_000)
        )
    }
}

private actor SC33InMemoryCleanupHistoryStore: CleanupHistoryStoring {
    func load() async -> [CleanupHistoryEntry] { [] }
    func append(_ entry: CleanupHistoryEntry) async throws {}
}

private enum SC33PreviewError: LocalizedError {
    case disabled

    var errorDescription: String? {
        "SC-3.3 DEBUG 预览已禁用磁盘扫描和文件执行。"
    }
}
#endif
