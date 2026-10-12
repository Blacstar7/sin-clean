#if DEBUG
import SwiftUI

// SC-PD3 占用全景与卸载后复查 预览夹具（冻结语义 §10）。
// 七态：完整／部分／无法判断／关联关闭／本体失败／卸载后未发现／卸载后仍发现。
// 全内存：夹具扫描器、夹具身份探针、内存历史存储；不触真实文件系统与真实偏好存储。

@MainActor
struct SCPD3AppFootprintPreview: View {
    enum Mode: String, CaseIterable {
        case full
        case partial
        case cannotJudge
        case associationOff
        case bodyFailed
        case recheckNone
        case recheckFound
    }

    let mode: Mode

    @StateObject private var viewModel: UninstallerViewModel
    @StateObject private var ignoreList: IgnoreListStore
    @State private var started = false

    init(mode: Mode) {
        self.mode = mode
        let ignoreList = IgnoreListStore(repository: InMemoryIgnoreRuleRepository(), autoload: false)
        _ignoreList = StateObject(wrappedValue: ignoreList)
        _viewModel = StateObject(wrappedValue: Self.makeViewModel(ignoreList: ignoreList, mode: mode))
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
            guard mode == .bodyFailed || mode == .recheckNone || mode == .recheckFound else { return }
            await Self.wait(for: viewModel, until: { $0.canUninstall })
            await Self.wait(for: viewModel, until: { $0.residuePhase == .completed && !$0.residues.isEmpty })
            viewModel.setAllResiduesSelected(true)
            viewModel.startUninstall()
            guard mode == .recheckNone || mode == .recheckFound else { return }
            await Self.wait(for: viewModel, until: { $0.executionPhase == .completed && $0.canRunPostUninstallRecheck })
            viewModel.runPostUninstallRecheck()
        }
        .preferredColorScheme(.dark)
    }

    private static func wait(
        for viewModel: UninstallerViewModel,
        until condition: @MainActor (UninstallerViewModel) -> Bool
    ) async {
        for _ in 0..<400 where !condition(viewModel) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 夹具装配

    private static func makeViewModel(ignoreList: IgnoreListStore, mode: Mode) -> UninstallerViewModel {
        let fixtures = SCPD3FootprintFixtures.make(mode: mode)
        return UninstallerViewModel(
            applicationScanner: SCPD3MemoryApplicationScanner(report: fixtures.applicationReport),
            residueScanner: SCPD3MemoryResidueScanner(
                selectionReport: fixtures.residueReport,
                recheckReport: fixtures.recheckResidueReport
            ),
            associationScanner: SCPD3MemoryAssociationScanner(
                selectionReport: fixtures.associationReport,
                recheckReport: fixtures.recheckAssociationReport
            ),
            executor: SCPD3PreviewUninstallExecutor(applicationSucceeds: mode != .bodyFailed),
            historyStore: SCPD3MemoryUninstallHistoryStore(),
            ignoreList: ignoreList,
            footprintProbe: SCPD3FootprintFixtures.identityProbe,
            fallbackScanConfiguration: mode == .associationOff
                ? ApplicationScanConfiguration(
                    includeSystemApplications: true,
                    includeUserApplications: true,
                    analyzeAssociatedComponents: false,
                    measurementConcurrency: 4
                )
                : nil
        )
    }
}

// MARK: - 夹具数据

private enum SCPD3FootprintFixtures {
    typealias Mode = SCPD3AppFootprintPreview.Mode

    static let now = Date(timeIntervalSince1970: 1_788_888_888)
    static let bundleIdentifier = "com.example.AuroraNotes"
    static let applicationPath = "/Applications/Aurora Notes.app"

    static func makeApplication(mode: Mode) -> InstalledApplication {
        InstalledApplication(
            id: "scpd3-preview-application",
            name: "Aurora Notes",
            path: applicationPath,
            rootPath: "/Applications",
            bundleIdentifier: mode == .cannotJudge ? "com.example..Aurora" : bundleIdentifier,
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
                context: ScanContext(),
                scopeID: "/Applications",
                reasonCode: .applicationDirectory,
                matchedValue: ".app"
            )
        )
    }

    static func completedCoverage(
        context: ScanContext,
        scope: ScanScope
    ) -> ScanCoverage {
        ScanCoverage(
            context: context,
            scope: scope,
            status: .completed,
            startedAt: now.addingTimeInterval(-5),
            finishedAt: now.addingTimeInterval(-3),
            issues: [],
            issueCount: 0,
            accessIssueCount: 0
        )
    }

    static func makeResidueCandidate(
        id: String, kind: AppResidueKind, path: String, rootPath: String,
        bytes: Int64, inode: UInt64, isDirectory: Bool
    ) -> AppResidueCandidate {
        AppResidueCandidate(
            id: id,
            bundleIdentifier: bundleIdentifier,
            kind: kind,
            path: path,
            rootPath: rootPath,
            allocatedBytes: bytes,
            logicalBytes: bytes + 4_096,
            modifiedSeconds: Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970),
            modifiedNanoseconds: 456_000_000,
            deviceID: 1,
            inode: inode,
            isDirectory: isDirectory,
            matchReason: "路径与 Bundle Identifier 完全一致",
            evidenceOrigin: CandidateEvidenceOrigin(
                context: ScanContext(),
                scopeID: kind.evidenceRule.rawValue,
                reasonCode: kind.evidenceRule,
                matchedValue: bundleIdentifier
            )
        )
    }

    static func makeAssociationItem(
        id: String, kind: AppAssociationKind, path: String, identifier: String?,
        relationship: AppAssociationRelationship, insideBundle: Bool
    ) -> AppAssociatedItem {
        AppAssociatedItem(
            id: id,
            kind: kind,
            path: path,
            identifier: identifier,
            relationship: relationship,
            isInsideApplicationBundle: insideBundle,
            evidenceOrigin: CandidateEvidenceOrigin(
                context: ScanContext(),
                scopeID: "\(kind.rawValue)|\(path)",
                reasonCode: insideBundle ? .embeddedLoginApp : .launchLabelNamespace,
                matchedValue: identifier
            ),
            associatedBundleIdentifier: bundleIdentifier,
            observedModifiedAt: now.addingTimeInterval(-172_800)
        )
    }

    static func make(mode: Mode) -> (
        applicationReport: ApplicationScanReport,
        residueReport: ResidueScanReport,
        associationReport: AppAssociationReport,
        recheckResidueReport: ResidueScanReport,
        recheckAssociationReport: AppAssociationReport
    ) {
        let application = makeApplication(mode: mode)
        let appContext = ScanContext()

        let applicationCoverage = completedCoverage(
            context: appContext,
            scope: ScanScope(
                id: "/Applications",
                scanner: .application,
                phase: .discover,
                rootPath: "/Applications",
                applicationID: application.id,
                bundleIdentifier: application.bundleIdentifier,
                policy: ScanPolicy(
                    recursive: true,
                    maximumDepth: 2,
                    skipsHiddenFiles: true,
                    acceptedTypes: ["directory"],
                    extensions: ["app"],
                    matching: CandidateRuleCode.applicationDirectory.rawValue
                )
            )
        )
        let applicationReport = ApplicationScanReport(
            applications: [application],
            coverage: [applicationCoverage],
            startedAt: now.addingTimeInterval(-8),
            finishedAt: now.addingTimeInterval(-6)
        )

        // 残留（选择期）：缓存目录＋偏好设置 plist
        let cachePath = "/Users/preview/Library/Caches/\(bundleIdentifier)"
        let cacheCandidate = makeResidueCandidate(
            id: "scpd3-residue-cache",
            kind: .cache,
            path: cachePath,
            rootPath: "/Users/preview/Library/Caches",
            bytes: 27_312_128,
            inode: 4_171,
            isDirectory: true
        )
        let preferencesCandidate = makeResidueCandidate(
            id: "scpd3-residue-preferences",
            kind: .preferences,
            path: "/Users/preview/Library/Preferences/\(bundleIdentifier).plist",
            rootPath: "/Users/preview/Library/Preferences",
            bytes: 4_096,
            inode: 4_172,
            isDirectory: false
        )

        var residueCoverage: [ScanCoverage] = [
            completedCoverage(
                context: cacheCandidate.evidenceOrigin.context,
                scope: ScanScope(
                    id: AppResidueKind.cache.evidenceRule.rawValue,
                    scanner: .residue,
                    phase: .discover,
                    rootPath: "/Users/preview/Library/Caches",
                    targetPath: cachePath,
                    applicationID: application.id,
                    bundleIdentifier: bundleIdentifier,
                    policy: ScanPolicy(recursive: false, matching: AppResidueKind.cache.evidenceRule.rawValue)
                )
            ),
            completedCoverage(
                context: preferencesCandidate.evidenceOrigin.context,
                scope: ScanScope(
                    id: AppResidueKind.preferences.evidenceRule.rawValue,
                    scanner: .residue,
                    phase: .discover,
                    rootPath: "/Users/preview/Library/Preferences",
                    targetPath: preferencesCandidate.path,
                    applicationID: application.id,
                    bundleIdentifier: bundleIdentifier,
                    policy: ScanPolicy(recursive: false, matching: AppResidueKind.preferences.evidenceRule.rawValue)
                )
            )
        ]
        if mode == .partial {
            residueCoverage.append(ScanCoverage(
                context: ScanContext(),
                scope: ScanScope(
                    id: "measure|residue.cache.exactBundlePath",
                    scanner: .residue,
                    phase: .measure,
                    rootPath: cachePath,
                    targetPath: cachePath,
                    applicationID: application.id,
                    bundleIdentifier: bundleIdentifier,
                    policy: ScanPolicy(recursive: true, matching: "sum regular file blocks; no symbolic links")
                ),
                status: .partial,
                startedAt: now.addingTimeInterval(-4),
                finishedAt: now.addingTimeInterval(-2),
                issues: [
                    ScanIssue(
                        scopeID: "measure|residue.cache.exactBundlePath",
                        path: "\(cachePath)/locked-subdir",
                        phase: .measure,
                        kind: .accessFailure,
                        restrictionReason: nil,
                        underlyingErrorDomain: NSPOSIXErrorDomain,
                        underlyingErrorCode: 13,
                        message: "Permission denied",
                        affectsCompleteness: true,
                        projectsToLegacyAccessIssues: true
                    )
                ],
                issueCount: 1,
                accessIssueCount: 1
            ))
        }
        let residueReport = ResidueScanReport(
            candidates: [cacheCandidate, preferencesCandidate],
            coverage: residueCoverage
        )

        // 关联（选择期）：外部 LaunchAgent＋包内登录项
        let externalItem = makeAssociationItem(
            id: "scpd3-association-launchagent",
            kind: .userLaunchAgent,
            path: "/Users/preview/Library/LaunchAgents/\(bundleIdentifier).sync.plist",
            identifier: "\(bundleIdentifier).sync",
            relationship: .exactLabel,
            insideBundle: false
        )
        let embeddedItem = makeAssociationItem(
            id: "scpd3-association-embedded",
            kind: .embeddedLoginItem,
            path: "\(applicationPath)/Contents/Library/LoginItems/Aurora Notes Helper.app",
            identifier: nil,
            relationship: .insideApplication,
            insideBundle: true
        )
        let associationReport = AppAssociationReport(
            items: [externalItem, embeddedItem],
            coverage: [
                completedCoverage(
                    context: externalItem.evidenceOrigin.context,
                    scope: ScanScope(
                        id: "用户登录代理|/Users/preview/Library/LaunchAgents",
                        scanner: .association,
                        phase: .associate,
                        rootPath: "/Users/preview/Library/LaunchAgents",
                        applicationID: application.id,
                        bundleIdentifier: bundleIdentifier,
                        policy: ScanPolicy(recursive: false, matching: "Label namespace first, otherwise absolute application path reference")
                    )
                ),
                completedCoverage(
                    context: embeddedItem.evidenceOrigin.context,
                    scope: ScanScope(
                        id: "内嵌登录项|\(applicationPath)/Contents/Library/LoginItems",
                        scanner: .association,
                        phase: .associate,
                        rootPath: "\(applicationPath)/Contents/Library/LoginItems",
                        applicationID: application.id,
                        bundleIdentifier: bundleIdentifier,
                        policy: ScanPolicy(recursive: false, matching: "embedded app directory")
                    )
                )
            ]
        )

        // 复查期（recheck| 前缀触发）：未发现 或 仍发现
        let recheckResidueReport: ResidueScanReport
        let recheckAssociationReport: AppAssociationReport
        if mode == .recheckFound {
            let containerCandidate = makeResidueCandidate(
                id: "scpd3-recheck-container",
                kind: .container,
                path: "/Users/preview/Library/Containers/\(bundleIdentifier)",
                rootPath: "/Users/preview/Library/Containers",
                bytes: 52_428_800,
                inode: 4_950,
                isDirectory: true
            )
            let recheckHelper = makeAssociationItem(
                id: "scpd3-recheck-helper",
                kind: .privilegedHelper,
                path: "/Library/PrivilegedHelperTools/\(bundleIdentifier).helper",
                identifier: "\(bundleIdentifier).helper",
                relationship: .exactNamespace,
                insideBundle: false
            )
            recheckResidueReport = ResidueScanReport(
                candidates: [containerCandidate],
                coverage: [
                    completedCoverage(
                        context: containerCandidate.evidenceOrigin.context,
                        scope: ScanScope(
                            id: AppResidueKind.container.evidenceRule.rawValue,
                            scanner: .residue,
                            phase: .discover,
                            rootPath: "/Users/preview/Library/Containers",
                            targetPath: containerCandidate.path,
                            applicationID: application.id,
                            bundleIdentifier: bundleIdentifier,
                            policy: ScanPolicy(recursive: false, matching: AppResidueKind.container.evidenceRule.rawValue)
                        )
                    )
                ]
            )
            recheckAssociationReport = AppAssociationReport(
                items: [recheckHelper],
                coverage: [
                    completedCoverage(
                        context: recheckHelper.evidenceOrigin.context,
                        scope: ScanScope(
                            id: "特权辅助工具|/Library/PrivilegedHelperTools",
                            scanner: .association,
                            phase: .associate,
                            rootPath: "/Library/PrivilegedHelperTools",
                            applicationID: application.id,
                            bundleIdentifier: bundleIdentifier,
                            policy: ScanPolicy(recursive: false, matching: "exact or dot-delimited Bundle Identifier namespace")
                        )
                    )
                ]
            )
        } else {
            recheckResidueReport = ResidueScanReport(candidates: [], coverage: [])
            recheckAssociationReport = AppAssociationReport(items: [], coverage: [])
        }

        return (
            applicationReport: applicationReport,
            residueReport: residueReport,
            associationReport: associationReport,
            recheckResidueReport: recheckResidueReport,
            recheckAssociationReport: recheckAssociationReport
        )
    }
}

private extension SCPD3FootprintFixtures {
    /// 身份探针夹具：回显应用自身字段 → 恒「可验证」（cannotJudge 态由 P1a 触发）。
    static let identityProbe = AppFootprintIdentityProbing { application in
        AppFootprintIdentityProbe(
            exists: true,
            isDirectory: true,
            deviceID: application.deviceID,
            inode: application.inode,
            logicalBytes: application.logicalBytes,
            modifiedSeconds: application.modifiedSeconds,
            modifiedNanoseconds: application.modifiedNanoseconds,
            bundleIdentifierReread: application.bundleIdentifier
        )
    }
}

// MARK: - 内存扫描器与执行器（形状与 SC-1.4 夹具一致）

private struct SCPD3MemoryApplicationScanner: ApplicationScanning {
    let report: ApplicationScanReport

    func scan(
        progress: @escaping @Sendable (ApplicationScanProgress) async -> Void
    ) async throws -> ApplicationScanReport {
        await progress(ApplicationScanProgress(
            currentPath: "SC-PD3 内存预览",
            discoveredCount: report.applications.count,
            measuredCount: report.applications.count
        ))
        return report
    }
}

private struct SCPD3MemoryResidueScanner: AppResidueScanning {
    let selectionReport: ResidueScanReport
    let recheckReport: ResidueScanReport

    func scan(for application: InstalledApplication) async -> ResidueScanReport {
        application.id.hasPrefix("recheck|") ? recheckReport : selectionReport
    }
}

private struct SCPD3MemoryAssociationScanner: AppAssociationScanning {
    let selectionReport: AppAssociationReport
    let recheckReport: AppAssociationReport

    func scan(for application: InstalledApplication) async -> AppAssociationReport {
        application.id.hasPrefix("recheck|") ? recheckReport : selectionReport
    }
}

/// 形状镜像生产 `UninstallExecutor` 的收据构建输入，保证收据构建器接受。
private struct SCPD3PreviewUninstallExecutor: UninstallExecuting {
    let applicationSucceeds: Bool

    func moveToTrash(
        candidates: [UninstallItemCandidate],
        progress: @escaping @Sendable (UninstallProgress) async -> Void
    ) async -> UninstallExecutionReport {
        let startedAt = Date()
        var results: [ExecutionItemResult] = []
        var failures: [UninstallFailure] = []
        var movedCount = 0
        var movedBytes: Int64 = 0

        for (index, candidate) in candidates.enumerated() {
            if index == 0 && !applicationSucceeds {
                let text = "应用仍在运行，请先退出应用后重试。"
                failures.append(UninstallFailure(path: candidate.path, reason: text))
                results.append(ExecutionItemResult(
                    itemID: candidate.id,
                    order: index,
                    originalPath: candidate.path,
                    status: .skipped,
                    reasonCode: .applicationStillRunning,
                    reasonText: text,
                    actualBytes: 0
                ))
            } else if index > 0 && !applicationSucceeds {
                let text = "应用本体未成功移入废纸篓，按照卸载边界，本残留保持不动且未执行。"
                failures.append(UninstallFailure(path: candidate.path, reason: text))
                results.append(ExecutionItemResult(
                    itemID: candidate.id,
                    order: index,
                    originalPath: candidate.path,
                    status: .notExecuted,
                    reasonCode: .notExecutedAfterApplicationFailure,
                    reasonText: text,
                    actualBytes: 0
                ))
            } else {
                movedCount += 1
                movedBytes += candidate.allocatedBytes
                results.append(ExecutionItemResult(
                    itemID: candidate.id,
                    order: index,
                    originalPath: candidate.path,
                    status: .succeeded,
                    reasonCode: .movedToTrash,
                    reasonText: "已通过执行前安全复验并移入废纸篓。",
                    actualBytes: candidate.allocatedBytes
                ))
            }
        }

        return UninstallExecutionReport(
            applicationName: candidates.first?.applicationName ?? "预览",
            bundleIdentifier: candidates.first?.bundleIdentifier ?? "",
            requestedCount: candidates.count,
            movedCount: movedCount,
            movedBytes: movedBytes,
            applicationMoved: applicationSucceeds && candidates.first?.kind == .applicationBundle,
            failures: failures,
            cancelled: false,
            finishedAt: Date(),
            startedAt: startedAt,
            itemResults: results
        )
    }
}

private actor SCPD3MemoryUninstallHistoryStore: UninstallHistoryStoring {
    func load() async -> [UninstallHistoryEntry] { [] }
    func append(_ entry: UninstallHistoryEntry) async throws {}
}
#endif
