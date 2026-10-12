#if DEBUG
import SwiftUI

// SC-PD1 存储去向诊断预览：五态注入（完整／部分覆盖／无突出来源／取消／空结果）。
// 全部为注入的内存数据，使用 /Preview/ 假路径；不读取真实用户目录、不写任何文件、
// 不触发真实权限对话框、不执行任何文件操作。夹具数据固定确定：同参数同结果，
// 且各类别字节之和恒等于 summary.scannedTotalBytes（守恒夹具）。
@MainActor
struct SCPD1SpaceAnalysisDiagnosisPreview: View {
    enum Mode: String, CaseIterable {
        case full
        case partial
        case none
        case cancelled
        case empty
    }

    @StateObject private var navigation = AppNavigationState()
    @StateObject private var ignoreList: IgnoreListStore
    @StateObject private var cleanupViewModel: CleanupViewModel
    @StateObject private var scopeViewModel: SpaceAnalysisScopeViewModel
    @StateObject private var resultsViewModel: SpaceAnalysisResultsViewModel
    @StateObject private var trashViewModel: SpaceAnalysisTrashViewModel
    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        let ignoreList = IgnoreListStore(
            repository: InMemoryIgnoreRuleRepository(),
            autoload: false
        )
        let scopes = [
            SpaceAnalysisScope(displayName: "个人文件夹（预览）", path: "/Preview/Home", source: .common),
            SpaceAnalysisScope(displayName: "应用程序（预览）", path: "/Preview/Applications", source: .chosenDirectory)
        ]
        _ignoreList = StateObject(wrappedValue: ignoreList)
        _cleanupViewModel = StateObject(wrappedValue: CleanupViewModel(
            scanner: SCPD1DisabledDiskScanner(),
            executor: SCPD1DisabledCleanupExecutor(),
            historyStore: SCPD1InMemoryCleanupHistoryStore(),
            ignoreList: ignoreList
        ))
        _scopeViewModel = StateObject(wrappedValue: SpaceAnalysisScopeViewModel(
            homeDirectory: URL(fileURLWithPath: "/Preview/Home", isDirectory: true),
            validator: SCPD1PreviewScopeValidator(),
            directoryChooser: SCPD1CancelledDirectoryChooser(),
            initialScopes: scopes,
            initialRejection: nil
        ))
        let stub = SCPD1PreviewScanner(outcome: SCPD1PreviewData.outcome(mode: mode))
        _resultsViewModel = StateObject(wrappedValue: SpaceAnalysisResultsViewModel(
            scanner: stub,
            ignoreList: ignoreList
        ))
        _trashViewModel = StateObject(wrappedValue: SpaceAnalysisTrashViewModel(ignoreList: ignoreList))
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
        .task {
            navigation.selectSpaceCleanupPage(.spaceAnalysis)
            if resultsViewModel.phase == .idle {
                resultsViewModel.startScan(scopes: scopeViewModel.selectedScopes)
            }
        }
    }
}

// MARK: - 预览扫描器（立即返回注入的内存态 outcome）

private actor SCPD1PreviewScanner: SpaceAnalysisScanning {
    private let outcome: SpaceAnalysisScanOutcome

    init(outcome: SpaceAnalysisScanOutcome) {
        self.outcome = outcome
    }

    func scan(
        scopes: [SpaceAnalysisScope],
        progress: @escaping @Sendable (SpaceAnalysisScanProgress) async -> Void
    ) async -> SpaceAnalysisScanOutcome {
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

// MARK: - 固定夹具数据（守恒：类别字节之和恒等于 scannedTotalBytes）

private enum SCPD1PreviewData {
    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: text) ?? Date(timeIntervalSince1970: 1_789_000_000)
    }

    static let hardLinkGroup = "16777232:5085303"

    /// full 基准条目（none 模式在此基础上移除 30 GB 的婚礼 4K 视频）。
    /// 类别字节：用户文件 43.8G（含硬链接首成员 2G、重复成员 0、占位 0）
    /// ＋ 安装包与归档 8.5G ＋ 缓存与日志 1.2G ＋ 设备与开发 8.4G
    /// ＋ 通信与内容 2.5G ＋ 应用与应用数据 6.5G ＋ 其他 0.04G。
    private static func baseEntries(includeProminentMovie: Bool) -> [SpaceAnalysisEntry] {
        let home = "/Preview/Home"
        var entries: [SpaceAnalysisEntry] = []
        if includeProminentMovie {
            entries.append(SpaceAnalysisEntry(
                path: "\(home)/Movies/婚礼4K.mov", displayName: "婚礼4K.mov",
                kind: .regularFile, allocatedBytes: 30_000_000_000, logicalBytes: 29_990_000_000,
                modifiedAt: date("2026-07-20 10:00"), rootPath: home
            ))
        }
        entries.append(contentsOf: [
            SpaceAnalysisEntry(
                path: "\(home)/Documents/发布会-4K.mov", displayName: "发布会-4K.mov",
                kind: .regularFile, allocatedBytes: 8_600_000_000, logicalBytes: 8_590_000_000,
                modifiedAt: date("2026-05-12 09:20"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Documents/设计资料/品牌手册.psd", displayName: "品牌手册.psd",
                kind: .regularFile, allocatedBytes: 3_200_000_000, logicalBytes: 3_190_000_000,
                modifiedAt: date("2026-04-18 11:32"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Documents/素材.mov", displayName: "素材.mov",
                kind: .regularFile, allocatedBytes: 2_000_000_000, logicalBytes: 1_990_000_000,
                modifiedAt: date("2026-03-09 16:48"), rootPath: home,
                linkGroupID: hardLinkGroup
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Downloads/素材-链接.mov", displayName: "素材-链接.mov",
                kind: .regularFile, allocatedBytes: 2_000_000_000, logicalBytes: 1_990_000_000,
                modifiedAt: date("2026-03-09 16:48"), rootPath: home,
                linkGroupID: hardLinkGroup
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Documents/iCloud-归档.mov", displayName: "iCloud-归档.mov",
                kind: .regularFile, allocatedBytes: 0, logicalBytes: 12_400_000_000,
                modifiedAt: date("2026-02-14 07:30"), rootPath: home,
                isDatalessPlaceholder: true
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Downloads/最新版本", displayName: "最新版本",
                kind: .symbolicLink, allocatedBytes: 0, logicalBytes: 0,
                modifiedAt: date("2026-06-11 15:00"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Downloads/Xcode_26_beta.xip", displayName: "Xcode_26_beta.xip",
                kind: .regularFile, allocatedBytes: 7_400_000_000, logicalBytes: 7_390_000_000,
                modifiedAt: date("2026-06-02 14:05"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Downloads/工具/SinTool.dmg", displayName: "SinTool.dmg",
                kind: .regularFile, allocatedBytes: 1_100_000_000, logicalBytes: 1_090_000_000,
                modifiedAt: date("2026-05-01 09:40"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Downloads/虚拟机/Win11.vmdk", displayName: "Win11.vmdk",
                kind: .regularFile, allocatedBytes: 1_900_000_000, logicalBytes: 1_890_000_000,
                modifiedAt: date("2026-04-22 19:12"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Caches/com.sometool/blob.cache", displayName: "blob.cache",
                kind: .regularFile, allocatedBytes: 900_000_000, logicalBytes: 890_000_000,
                modifiedAt: date("2026-08-30 21:02"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Logs/serv.log", displayName: "serv.log",
                kind: .regularFile, allocatedBytes: 300_000_000, logicalBytes: 295_000_000,
                modifiedAt: date("2026-09-01 03:11"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Application Support/MobileSync/Backup/abc123/manifest.db",
                displayName: "manifest.db",
                kind: .regularFile, allocatedBytes: 2_200_000_000, logicalBytes: 2_190_000_000,
                modifiedAt: date("2026-08-14 22:40"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Developer/Xcode/DerivedData/App-abc/index.store",
                displayName: "index.store",
                kind: .regularFile, allocatedBytes: 1_500_000_000, logicalBytes: 1_490_000_000,
                modifiedAt: date("2026-09-10 11:26"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Developer/CoreSimulator/Devices/ABCD/data.bin",
                displayName: "data.bin",
                kind: .regularFile, allocatedBytes: 800_000_000, logicalBytes: 790_000_000,
                modifiedAt: date("2026-07-07 08:05"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Containers/com.docker.docker/Data/Docker.raw",
                displayName: "Docker.raw",
                kind: .regularFile, allocatedBytes: 2_800_000_000, logicalBytes: 2_790_000_000,
                modifiedAt: date("2026-09-12 17:33"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Mail/IMAP/账户A/大信箱.mbox", displayName: "大信箱.mbox",
                kind: .regularFile, allocatedBytes: 1_900_000_000, logicalBytes: 1_890_000_000,
                modifiedAt: date("2026-09-15 07:50"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Messages/附件暂存.staged", displayName: "附件暂存.staged",
                kind: .regularFile, allocatedBytes: 600_000_000, logicalBytes: 590_000_000,
                modifiedAt: date("2026-09-16 12:18"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Application Support/SomeApp/store.bin", displayName: "store.bin",
                kind: .regularFile, allocatedBytes: 1_300_000_000, logicalBytes: 1_290_000_000,
                modifiedAt: date("2026-08-01 10:10"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Group Containers/TEAM.group/shared.bin", displayName: "shared.bin",
                kind: .regularFile, allocatedBytes: 700_000_000, logicalBytes: 690_000_000,
                modifiedAt: date("2026-08-21 16:44"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "/Preview/Applications/预览工具.app", displayName: "预览工具.app",
                kind: .package, allocatedBytes: 4_500_000_000, logicalBytes: 4_500_000_000,
                modifiedAt: date("2026-06-20 13:00"), rootPath: "/Preview/Applications"
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Preferences/com.sometool.plist", displayName: "com.sometool.plist",
                kind: .regularFile, allocatedBytes: 40_000_000, logicalBytes: 39_000_000,
                modifiedAt: date("2026-09-17 02:00"), rootPath: home
            )
        ])
        return entries
    }

    static func outcome(mode: SCPD1SpaceAnalysisDiagnosisPreview.Mode) -> SpaceAnalysisScanOutcome {
        switch mode {
        case .empty:
            let home = "/Preview/Home"
            let nodes = [SpaceAnalysisTreeNode(
                path: home, displayName: "个人文件夹（预览）", depth: 0, totalBytes: 0,
                ownFileBytes: 0, childDirectoryCount: 0, fileCount: 0, isReadable: true, rootPath: home
            )]
            return SpaceAnalysisScanOutcome(
                entries: [], nodes: nodes,
                summary: SpaceAnalysisScanSummary(
                    inspectedEntryCount: 0, unreadableDirectoryCount: 0,
                    skippedSymbolicLinkCount: 0, unknownSizeCount: 0, scannedTotalBytes: 0,
                    startedAt: date("2026-09-19 09:00"), finishedAt: date("2026-09-19 09:00"),
                    cancelled: false
                )
            )
        case .full, .partial, .none, .cancelled:
            let includeProminentMovie = mode != .none
            let entries = baseEntries(includeProminentMovie: includeProminentMovie)
            let home = "/Preview/Home"
            let applications = "/Preview/Applications"
            let homeTotal = entries
                .filter { $0.rootPath == home }
                .reduce(Int64(0)) { partial, entry in
                    let counted: Int64
                    switch entry.kind {
                    case .regularFile:
                        counted = entry.allocatedBytes
                    case .package:
                        counted = entry.allocatedBytes
                    default:
                        counted = 0
                    }
                    return partial + counted
                }
            let applicationsTotal = entries
                .filter { $0.rootPath == applications }
                .reduce(Int64(0)) { $0 + $1.allocatedBytes }
            // 硬链接重复成员只计一次（守恒口径）。
            var seenGroups = Set<String>()
            var duplicateBytes: Int64 = 0
            for entry in entries where entry.linkGroupID != nil {
                if seenGroups.contains(entry.linkGroupID!) {
                    duplicateBytes += entry.allocatedBytes
                } else {
                    seenGroups.insert(entry.linkGroupID!)
                }
            }
            let denominator = homeTotal + applicationsTotal - duplicateBytes

            var nodes = [
                SpaceAnalysisTreeNode(
                    path: home, displayName: "个人文件夹（预览）", depth: 0,
                    totalBytes: homeTotal - duplicateBytes, ownFileBytes: 1_200_000_000,
                    childDirectoryCount: 6, fileCount: 18, isReadable: true, rootPath: home
                ),
                SpaceAnalysisTreeNode(
                    path: applications, displayName: "应用程序（预览）", depth: 0,
                    totalBytes: applicationsTotal, ownFileBytes: applicationsTotal,
                    childDirectoryCount: 0, fileCount: 1, isReadable: true, rootPath: applications
                )
            ]
            if mode == .partial {
                nodes.append(SpaceAnalysisTreeNode(
                    path: "\(home)/Library/受限归档", displayName: "受限归档", depth: 1,
                    totalBytes: 0, ownFileBytes: 0, childDirectoryCount: 0, fileCount: 0,
                    isReadable: false, rootPath: home
                ))
            }

            return SpaceAnalysisScanOutcome(
                entries: entries,
                nodes: nodes,
                summary: SpaceAnalysisScanSummary(
                    inspectedEntryCount: entries.count,
                    unreadableDirectoryCount: mode == .partial ? 1 : 0,
                    skippedSymbolicLinkCount: 1,
                    unknownSizeCount: 0,
                    scannedTotalBytes: denominator,
                    startedAt: date("2026-09-19 09:00"),
                    finishedAt: date("2026-09-19 09:01"),
                    cancelled: mode == .cancelled
                ),
                deduplication: SpaceAnalysisDeduplicationSummary(
                    hardLinkGroupCount: 1,
                    hardLinkMemberCount: 1,
                    deduplicatedBytes: 2_000_000_000,
                    crossDeviceGroupCount: 0,
                    datalessPlaceholderCount: 1,
                    datalessLogicalBytes: 12_400_000_000,
                    capacityIsUpperBound: true
                )
            )
        }
    }
}

// MARK: - 预览依赖（纯内存，禁用的生产路径）

private struct SCPD1PreviewScopeValidator: SpaceAnalysisScopeValidating {
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
private struct SCPD1CancelledDirectoryChooser: SpaceAnalysisDirectoryChoosing {
    func chooseDirectories() -> SpaceAnalysisDirectoryChoice { .cancelled }
}

private struct SCPD1DisabledDiskScanner: DiskScanning {
    func scan(
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> CleanupScanReport {
        throw SCPD1PreviewError.disabled
    }
}

private actor SCPD1DisabledCleanupExecutor: CleanupExecuting {
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

private actor SCPD1InMemoryCleanupHistoryStore: CleanupHistoryStoring {
    func load() async -> [CleanupHistoryEntry] { [] }
    func append(_ entry: CleanupHistoryEntry) async throws {}
}

private enum SCPD1PreviewError: LocalizedError {
    case disabled

    var errorDescription: String? {
        "SC-PD1 DEBUG 预览已禁用磁盘扫描和文件执行。"
    }
}
#endif
