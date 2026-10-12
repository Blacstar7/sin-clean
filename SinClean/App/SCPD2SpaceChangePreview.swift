#if DEBUG
import SwiftUI

// SC-PD2 空间变化追踪预览：八态注入（首次／增长／缩小／无明显变化／不可比较／
// 记录关闭／损坏／清除确认）。全部为注入的内存数据：/Preview/ 假路径＋内存文件访问＋
// 固定盐与固定时钟；不读取真实用户目录、不写任何真实文件、不触发权限对话框、
// 不执行任何文件操作。夹具固定确定：同参数同结果；类别字节之和恒等于
// summary.scannedTotalBytes（守恒夹具，经 PD1 引擎校验通过）。
@MainActor
struct SCPD2SpaceChangePreview: View {
    enum Mode: String, CaseIterable {
        case first
        case growth
        case shrink
        case noChange
        case notComparable
        case disabled
        case damaged
        case clearConfirm
    }

    @StateObject private var navigation = AppNavigationState()
    @StateObject private var ignoreList: IgnoreListStore
    @StateObject private var cleanupViewModel: CleanupViewModel
    @StateObject private var scopeViewModel: SpaceAnalysisScopeViewModel
    @StateObject private var resultsViewModel: SpaceAnalysisResultsViewModel
    @StateObject private var trashViewModel: SpaceAnalysisTrashViewModel
    @StateObject private var historyStore: SpaceChangeHistoryStore
    private let mode: Mode
    /// 预览设置夹具：disabled 态用隔离 UserDefaults 套件（不触碰真实偏好域），其余态为普通实例。
    private let previewSettings: AppSettings

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
            scanner: SCPD2DisabledDiskScanner(),
            executor: SCPD2DisabledCleanupExecutor(),
            historyStore: SCPD2InMemoryCleanupHistoryStore(),
            ignoreList: ignoreList
        ))
        _scopeViewModel = StateObject(wrappedValue: SpaceAnalysisScopeViewModel(
            homeDirectory: URL(fileURLWithPath: "/Preview/Home", isDirectory: true),
            validator: SCPD2PreviewScopeValidator(),
            directoryChooser: SCPD2CancelledDirectoryChooser(),
            initialScopes: scopes,
            initialRejection: nil
        ))
        let stub = SCPD2PreviewScanner(outcome: SCPD2PreviewData.currentOutcome())
        _resultsViewModel = StateObject(wrappedValue: SpaceAnalysisResultsViewModel(
            scanner: stub,
            ignoreList: ignoreList
        ))
        _trashViewModel = StateObject(wrappedValue: SpaceAnalysisTrashViewModel(ignoreList: ignoreList))
        _historyStore = StateObject(wrappedValue: SpaceChangeHistoryStore(
            fileAccess: SCPD2PreviewStorage.seedAccess(mode: mode),
            randomSource: SCPD2FixedRandomSource(),
            paths: SpaceChangeStoragePaths(
                baseDirectory: URL(fileURLWithPath: "/Preview/Storage", isDirectory: true)
            ),
            clock: { SCPD2PreviewData.date("2026-09-20 12:00") }
        ))
        if mode == .disabled {
            let suite = UserDefaults(suiteName: "scpd2-preview-disabled-suite") ?? .standard
            let settings = AppSettings(store: suite)
            settings.spaceChangeRecordingEnabled = false
            previewSettings = settings
        } else {
            previewSettings = AppSettings()
        }
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            if mode == .clearConfirm {
                SCPD2ClearConfirmSettingsPreview()
            } else {
                SpaceCleanupView {
                    CleanupView(previewViewModel: cleanupViewModel, ignoreList: ignoreList)
                }
            }
        }
        .tint(AppTheme.accent)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .environmentObject(navigation)
        .environmentObject(scopeViewModel)
        .environmentObject(resultsViewModel)
        .environmentObject(trashViewModel)
        .environmentObject(historyStore)
        .environmentObject(previewSettings)
        .task {
            navigation.selectSpaceCleanupPage(.spaceAnalysis)
            if mode != .clearConfirm, resultsViewModel.phase == .idle {
                resultsViewModel.startScan(scopes: scopeViewModel.selectedScopes)
            }
        }
    }
}

// MARK: - 清除确认态（设置页直渲染；历史存储为内存夹具，真实记录不受影响）

@MainActor
private struct SCPD2ClearConfirmSettingsPreview: View {
    @StateObject private var historyStore = SpaceChangeHistoryStore(
        fileAccess: SCPD2PreviewStorage.seedAccess(mode: .clearConfirm),
        randomSource: SCPD2FixedRandomSource(),
        paths: SpaceChangeStoragePaths(
            baseDirectory: URL(fileURLWithPath: "/Preview/Storage", isDirectory: true)
        ),
        clock: { SCPD2PreviewData.date("2026-09-20 12:00") }
    )

    var body: some View {
        SettingsView(embedded: false)
            .environmentObject(AppSettings())
            .environmentObject(IgnoreListStore(
                repository: InMemoryIgnoreRuleRepository(),
                autoload: false
            ))
            .environmentObject(OnboardingViewModel(
                store: InMemoryOnboardingCompletionStore(completed: true)
            ))
            .environmentObject(historyStore)
    }
}

// MARK: - 预览扫描器（立即返回注入的内存态 outcome）

private actor SCPD2PreviewScanner: SpaceAnalysisScanning {
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

private enum SCPD2PreviewData {
    static let previewSalt = String(repeating: "ab", count: 32)

    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: text) ?? Date(timeIntervalSince1970: 1_789_000_000)
    }

    /// 当前扫描夹具：用户文件 10G＋安装包 2G＋缓存 1G＋应用与应用数据 7G（3G 数据＋4G 包）
    /// ＋云端占位 1 条（0 字节计入）；总量 20G，守恒。
    static func currentOutcome() -> SpaceAnalysisScanOutcome {
        let home = "/Preview/Home"
        let applications = "/Preview/Applications"
        let entries: [SpaceAnalysisEntry] = [
            SpaceAnalysisEntry(
                path: "\(home)/Movies/影片.mov", displayName: "影片.mov",
                kind: .regularFile, allocatedBytes: 10_000_000_000, logicalBytes: 9_990_000_000,
                modifiedAt: date("2026-09-18 10:00"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Downloads/工具.dmg", displayName: "工具.dmg",
                kind: .regularFile, allocatedBytes: 2_000_000_000, logicalBytes: 1_990_000_000,
                modifiedAt: date("2026-09-17 09:00"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Downloads/云端-归档.zip", displayName: "云端-归档.zip",
                kind: .regularFile, allocatedBytes: 0, logicalBytes: 5_000_000_000,
                modifiedAt: date("2026-09-16 08:00"), rootPath: home,
                isDatalessPlaceholder: true
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Caches/blob.cache", displayName: "blob.cache",
                kind: .regularFile, allocatedBytes: 1_000_000_000, logicalBytes: 990_000_000,
                modifiedAt: date("2026-09-19 11:00"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(home)/Library/Application Support/App/store.bin", displayName: "store.bin",
                kind: .regularFile, allocatedBytes: 3_000_000_000, logicalBytes: 2_990_000_000,
                modifiedAt: date("2026-09-15 07:00"), rootPath: home
            ),
            SpaceAnalysisEntry(
                path: "\(applications)/工具.app", displayName: "工具.app",
                kind: .package, allocatedBytes: 4_000_000_000, logicalBytes: 4_000_000_000,
                modifiedAt: date("2026-09-14 06:00"), rootPath: applications
            )
        ]
        let homeNode = SpaceAnalysisTreeNode(
            path: home, displayName: "个人文件夹（预览）", depth: 0,
            totalBytes: 16_000_000_000, ownFileBytes: 0, childDirectoryCount: 4, fileCount: 5,
            isReadable: true, rootPath: home
        )
        let applicationsNode = SpaceAnalysisTreeNode(
            path: applications, displayName: "应用程序（预览）", depth: 0,
            totalBytes: 4_000_000_000, ownFileBytes: 4_000_000_000, childDirectoryCount: 0,
            fileCount: 1, isReadable: true, rootPath: applications
        )
        return SpaceAnalysisScanOutcome(
            entries: entries,
            nodes: [homeNode, applicationsNode],
            summary: SpaceAnalysisScanSummary(
                inspectedEntryCount: entries.count,
                unreadableDirectoryCount: 0,
                skippedSymbolicLinkCount: 0,
                unknownSizeCount: 0,
                scannedTotalBytes: 20_000_000_000,
                startedAt: date("2026-09-20 11:59"),
                finishedAt: date("2026-09-20 12:00"),
                cancelled: false
            ),
            deduplication: SpaceAnalysisDeduplicationSummary(
                hardLinkGroupCount: 0,
                hardLinkMemberCount: 0,
                deduplicatedBytes: 0,
                crossDeviceGroupCount: 0,
                datalessPlaceholderCount: 1,
                datalessLogicalBytes: 5_000_000_000,
                capacityIsUpperBound: true
            )
        )
    }

    /// 基准快照夹具：按模式给定类别基线（字节单位），守恒由构造保证。
    static func baselineSnapshot(
        createdAt: Date,
        scopes: [String],
        userFiles: Int64,
        installersAndArchives: Int64,
        cachesAndLogs: Int64,
        appsAndAppData: Int64
    ) -> SpaceChangeSnapshot? {
        guard let fingerprint = SpaceChangeFingerprint.compute(
            normalizedScopes: scopes, saltHex: previewSalt
        ) else { return nil }
        let total = userFiles + installersAndArchives + cachesAndLogs + appsAndAppData
        var bytesByID: [String: Int64] = [
            SpaceAnalysisDiagnosisCategoryID.userFiles.rawValue: userFiles,
            SpaceAnalysisDiagnosisCategoryID.installersAndArchives.rawValue: installersAndArchives,
            SpaceAnalysisDiagnosisCategoryID.cachesAndLogs.rawValue: cachesAndLogs,
            SpaceAnalysisDiagnosisCategoryID.appsAndAppData.rawValue: appsAndAppData
        ]
        let categories = SpaceChangeSemantics.categoryIDOrder.map { id in
            SpaceChangeCategoryMeasurement(
                id: id, bytes: bytesByID.removeValue(forKey: id) ?? 0, entryCount: 2
            )
        }
        return SpaceChangeSnapshot(
            createdAtEpochSeconds: createdAt.timeIntervalSince1970,
            scopeFingerprint: fingerprint,
            ruleVersion: SpaceChangeSemantics.ruleVersion,
            capacitySemanticsVersion: SpaceChangeSemantics.capacitySemanticsVersion,
            totalBytes: total,
            categories: categories,
            coverageComplete: true,
            unreadableDirectoryCount: 0,
            capacityIsUpperBound: true,
            datalessPlaceholderCount: 0
        )
    }

    static let currentScopes = ["/Preview/Applications", "/Preview/Home"]
    static let otherScopes = ["/Preview/Home"]
}

// MARK: - 内存文件访问与种子


private struct SCPD2FixedRandomSource: SpaceChangeRandomSource {
    func randomSaltHex(byteCount: Int) -> String? {
        String(repeating: "ab", count: byteCount)
    }
}

private enum SCPD2PreviewStorage {
    static func historyURLPath() -> String {
        URL(fileURLWithPath: "/Preview/Storage", isDirectory: true)
            .appending(path: "space-change-history.json").path
    }

    static func saltURLPath() -> String {
        URL(fileURLWithPath: "/Preview/Storage", isDirectory: true)
            .appending(path: "space-change-salt.txt").path
    }

    static func seedAccess(mode: SCPD2SpaceChangePreview.Mode) -> SCPD2IsolatedPreviewFileAccess {
        let saltData = Data((SCPD2PreviewData.previewSalt + "\n").utf8)
        let historyPath = historyURLPath()
        switch mode {
        case .first:
            // 仅盐，无历史：首次记录态。
            return SCPD2IsolatedPreviewFileAccess(seeded: [saltURLPath(): saltData])
        case .growth:
            // 基线：用户文件 8G＋安装包 2G＋缓存 1G＋应用 6G＝17G；当前 20G → 总量 +3G，
            // 增长榜：用户文件 +2G、应用与应用数据 +1G；无缩小。
            let baseline = SCPD2PreviewData.baselineSnapshot(
                createdAt: SCPD2PreviewData.date("2026-09-19 12:00"),
                scopes: SCPD2PreviewData.currentScopes,
                userFiles: 8_000_000_000,
                installersAndArchives: 2_000_000_000,
                cachesAndLogs: 1_000_000_000,
                appsAndAppData: 6_000_000_000
            )
            return seededAccess(snapshot: baseline, saltData: saltData, historyPath: historyPath)
        case .shrink:
            // 基线：用户文件 13G＋安装包 3G＋缓存 1G＋应用 5G＝22G；当前 20G → 总量 −2G，
            // 缩小榜：用户文件 −3G、安装包 −1G；增长榜：应用与应用数据 +2G（如实并列呈现）。
            let baseline = SCPD2PreviewData.baselineSnapshot(
                createdAt: SCPD2PreviewData.date("2026-09-19 12:00"),
                scopes: SCPD2PreviewData.currentScopes,
                userFiles: 13_000_000_000,
                installersAndArchives: 3_000_000_000,
                cachesAndLogs: 1_000_000_000,
                appsAndAppData: 5_000_000_000
            )
            return seededAccess(snapshot: baseline, saltData: saltData, historyPath: historyPath)
        case .noChange:
            let baseline = SCPD2PreviewData.baselineSnapshot(
                createdAt: SCPD2PreviewData.date("2026-09-19 12:00"),
                scopes: SCPD2PreviewData.currentScopes,
                userFiles: 10_000_000_000,
                installersAndArchives: 2_000_000_000,
                cachesAndLogs: 1_000_000_000,
                appsAndAppData: 7_000_000_000
            )
            return seededAccess(snapshot: baseline, saltData: saltData, historyPath: historyPath)
        case .notComparable, .disabled:
            // notComparable：基线范围集合不同（仅个人文件夹）。
            // disabled：正常可比基线，但设置开关关闭（--scpd2-preview-disabled 注入）。
            let scopes = mode == .notComparable
                ? SCPD2PreviewData.otherScopes
                : SCPD2PreviewData.currentScopes
            let baseline = SCPD2PreviewData.baselineSnapshot(
                createdAt: SCPD2PreviewData.date("2026-09-19 12:00"),
                scopes: scopes,
                userFiles: 8_000_000_000,
                installersAndArchives: 2_000_000_000,
                cachesAndLogs: 1_000_000_000,
                appsAndAppData: 6_000_000_000
            )
            return seededAccess(snapshot: baseline, saltData: saltData, historyPath: historyPath)
        case .damaged:
            return SCPD2IsolatedPreviewFileAccess(seeded: [
                saltURLPath(): saltData,
                historyPath: Data("not a json".utf8)
            ])
        case .clearConfirm:
            let first = SCPD2PreviewData.baselineSnapshot(
                createdAt: SCPD2PreviewData.date("2026-09-18 12:00"),
                scopes: SCPD2PreviewData.currentScopes,
                userFiles: 7_000_000_000, installersAndArchives: 1_000_000_000,
                cachesAndLogs: 1_000_000_000, appsAndAppData: 5_000_000_000
            )
            let second = SCPD2PreviewData.baselineSnapshot(
                createdAt: SCPD2PreviewData.date("2026-09-19 12:00"),
                scopes: SCPD2PreviewData.currentScopes,
                userFiles: 8_000_000_000, installersAndArchives: 2_000_000_000,
                cachesAndLogs: 1_000_000_000, appsAndAppData: 6_000_000_000
            )
            let third = SCPD2PreviewData.baselineSnapshot(
                createdAt: SCPD2PreviewData.date("2026-09-20 10:00"),
                scopes: SCPD2PreviewData.currentScopes,
                userFiles: 10_000_000_000, installersAndArchives: 2_000_000_000,
                cachesAndLogs: 1_000_000_000, appsAndAppData: 7_000_000_000
            )
            let snapshots = [first, second, third].compactMap { $0 }
            guard let encoded = try? SpaceChangeHistoryStore.encodedDocument(snapshots) else {
                return SCPD2IsolatedPreviewFileAccess(seeded: [saltURLPath(): saltData])
            }
            return SCPD2IsolatedPreviewFileAccess(seeded: [
                saltURLPath(): saltData,
                historyPath: encoded
            ])
        }
    }

    private static func seededAccess(
        snapshot: SpaceChangeSnapshot?,
        saltData: Data,
        historyPath: String
    ) -> SCPD2IsolatedPreviewFileAccess {
        guard let snapshot, let encoded = try? SpaceChangeHistoryStore.encodedDocument([snapshot]) else {
            return SCPD2IsolatedPreviewFileAccess(seeded: [saltURLPath(): saltData])
        }
        return SCPD2IsolatedPreviewFileAccess(seeded: [
            saltURLPath(): saltData,
            historyPath: encoded
        ])
    }
}

// MARK: - 预览依赖（纯内存，禁用的生产路径）

private struct SCPD2PreviewScopeValidator: SpaceAnalysisScopeValidating {
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
private struct SCPD2CancelledDirectoryChooser: SpaceAnalysisDirectoryChoosing {
    func chooseDirectories() -> SpaceAnalysisDirectoryChoice { .cancelled }
}

private struct SCPD2DisabledDiskScanner: DiskScanning {
    func scan(
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> CleanupScanReport {
        throw SCPD2PreviewError.disabled
    }
}

private actor SCPD2DisabledCleanupExecutor: CleanupExecuting {
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

private actor SCPD2InMemoryCleanupHistoryStore: CleanupHistoryStoring {
    func load() async -> [CleanupHistoryEntry] { [] }
    func append(_ entry: CleanupHistoryEntry) async throws {}
}

private enum SCPD2PreviewError: LocalizedError {
    case disabled

    var errorDescription: String? {
        "SC-PD2 DEBUG 预览已禁用磁盘扫描和文件执行。"
    }
}
#endif
