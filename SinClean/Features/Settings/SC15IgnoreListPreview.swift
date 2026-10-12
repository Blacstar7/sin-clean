#if DEBUG
import SwiftUI

@MainActor
struct SC15IgnoreListPreview: View {
    @StateObject private var ignoreList: IgnoreListStore

    init() {
        let rules = Self.fixtureRules
        _ignoreList = StateObject(wrappedValue: IgnoreListStore(
            repository: InMemoryIgnoreRuleRepository(rules: rules),
            initialRules: rules,
            autoload: false
        ))
    }

    var body: some View {
        ZStack {
            AuroraBackground()

            HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
                previewMainList
                    .frame(width: 520)

                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text("设置 · 忽略列表")
                                .font(.largeTitle.bold())
                            Text("纯内存 DEBUG 预览；撤销与清空不会读写真实忽略文件。")
                                .foregroundStyle(.secondary)
                        }
                        IgnoreListSettingsSection(ignoreList: ignoreList)
                    }
                    .padding(.bottom, AppTheme.Spacing.xl)
                }
            }
            .padding(AppTheme.Spacing.xl)
        }
        .frame(minWidth: 1_320, minHeight: 820)
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
    }

    private var previewMainList: some View {
        let candidates = Self.fixtureCandidates
        let visibleCandidates = candidates.filter { !ignoreList.isIgnored($0) }
        let ignoredCandidateCount = candidates.count - visibleCandidates.count

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            FeatureHeader(
                eyebrow: "SC-1.5 · 展示层过滤",
                title: "磁盘清理",
                description: "原始扫描仍报告 8 个候选；忽略规则只隐藏操作层中的精确匹配项。",
                symbol: "internaldrive.fill",
                tint: AppTheme.accent
            )

            HStack(spacing: AppTheme.Spacing.md) {
                SC15PreviewMetric(title: "原始候选", value: candidates.count.formatted())
                SC15PreviewMetric(title: "当前可见", value: visibleCandidates.count.formatted())
                SC15PreviewMetric(title: "已忽略", value: ignoredCandidateCount.formatted())
            }

            IgnoreListStatusBanner(
                loadState: ignoreList.loadState,
                ignoredCount: ignoredCandidateCount,
                manageAction: {}
            )

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("可执行选择集合")
                    .font(.headline)
                Text("下列项目保持默认未勾选；被忽略项目不会出现在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(visibleCandidates) { candidate in
                            SC15PreviewCandidateRow(
                                name: Self.displayName(for: candidate),
                                path: candidate.path
                            )
                        }
                    }
                }
                .frame(maxHeight: 270)
            }
            .cardSurface()

            Label("Coverage：4 个范围 · 权限缺口：1 · 原始 report 未改写", systemImage: "checkmark.shield.fill")
                .font(.callout)
                .foregroundStyle(AppTheme.healthy)
                .padding(AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.healthy.opacity(0.09), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))

            Spacer(minLength: 0)
        }
    }

    private static let fixtureRules: [IgnoreRule] = [
        IgnoreRule(
            id: UUID(uuidString: "15000000-0000-0000-0000-000000000001")!,
            kind: .cleanupCandidate(
                locationID: "user-caches",
                path: "/Users/demo/Library/Caches/com.example.Editor/cache.bin"
            ),
            displayName: "cache.bin",
            originalPath: "/Users/demo/Library/Caches/com.example.Editor/cache.bin",
            createdAt: Date(timeIntervalSince1970: 1_788_888_100)
        ),
        IgnoreRule(
            id: UUID(uuidString: "15000000-0000-0000-0000-000000000002")!,
            kind: .cleanupCandidate(
                locationID: "user-logs",
                path: "/Users/demo/Library/Logs/Example/legacy-session.log"
            ),
            displayName: "legacy-session.log",
            originalPath: "/Users/demo/Library/Logs/Example/legacy-session.log",
            createdAt: Date(timeIntervalSince1970: 1_788_888_200)
        ),
        IgnoreRule(
            id: UUID(uuidString: "15000000-0000-0000-0000-000000000003")!,
            kind: .fixedPath(path: "/Users/demo/Downloads/Keep This Installer.dmg"),
            displayName: "Keep This Installer.dmg",
            originalPath: "/Users/demo/Downloads/Keep This Installer.dmg",
            createdAt: Date(timeIntervalSince1970: 1_788_888_300)
        ),
        IgnoreRule(
            id: UUID(uuidString: "15000000-0000-0000-0000-000000000004")!,
            kind: .applicationBundleIdentifier("com.example.AuroraNotes"),
            displayName: "Aurora Notes",
            originalPath: "/Applications/Aurora Notes.app",
            createdAt: Date(timeIntervalSince1970: 1_788_888_400)
        )
    ]

    private static let fixtureCandidates: [CleanupFileCandidate] = {
        let context = ScanContext()

        func candidate(
            id: String,
            locationID: String,
            rootPath: String,
            path: String,
            reasonCode: CandidateRuleCode
        ) -> CleanupFileCandidate {
            CleanupFileCandidate(
                id: id,
                locationID: locationID,
                rootPath: rootPath,
                path: path,
                allocatedBytes: 1_048_576,
                logicalBytes: 1_000_000,
                modifiedAt: Date(timeIntervalSince1970: 1_788_888_000),
                modifiedSeconds: 1_788_888_000,
                modifiedNanoseconds: 0,
                deviceID: 1,
                inode: UInt64(id.dropFirst("preview-".count)) ?? 1,
                risk: .safe,
                evidenceOrigin: CandidateEvidenceOrigin(
                    context: context,
                    scopeID: "disk:\(locationID)",
                    reasonCode: reasonCode
                )
            )
        }

        return [
            candidate(
                id: "preview-1", locationID: "user-caches",
                rootPath: "/Users/demo/Library/Caches",
                path: "/Users/demo/Library/Caches/com.example.Editor/cache.bin",
                reasonCode: .userCaches
            ),
            candidate(
                id: "preview-2", locationID: "user-logs",
                rootPath: "/Users/demo/Library/Logs",
                path: "/Users/demo/Library/Logs/Example/legacy-session.log",
                reasonCode: .userLogs
            ),
            candidate(
                id: "preview-3", locationID: "downloaded-installers",
                rootPath: "/Users/demo/Downloads",
                path: "/Users/demo/Downloads/Keep This Installer.dmg",
                reasonCode: .downloadedInstallers
            ),
            candidate(
                id: "preview-4", locationID: "user-caches",
                rootPath: "/Users/demo/Library/Caches",
                path: "/Users/demo/Library/Caches/com.example.WebKit/cache.db",
                reasonCode: .userCaches
            ),
            candidate(
                id: "preview-5", locationID: "user-logs",
                rootPath: "/Users/demo/Library/Logs",
                path: "/Users/demo/Library/Logs/Example/session.log",
                reasonCode: .userLogs
            ),
            candidate(
                id: "preview-6", locationID: "downloaded-installers",
                rootPath: "/Users/demo/Downloads",
                path: "/Users/demo/Downloads/Archive.pkg",
                reasonCode: .downloadedInstallers
            ),
            candidate(
                id: "preview-7", locationID: "crash-reports",
                rootPath: "/Users/demo/Library/Application Support/CrashReporter",
                path: "/Users/demo/Library/Application Support/CrashReporter/System.ips",
                reasonCode: .crashReports
            ),
            candidate(
                id: "preview-8", locationID: "downloaded-installers",
                rootPath: "/Users/demo/Downloads",
                path: "/Users/demo/Downloads/Reference.zip",
                reasonCode: .downloadedInstallers
            )
        ]
    }()

    private static func displayName(for candidate: CleanupFileCandidate) -> String {
        switch candidate.id {
        case "preview-4": "WebKit 临时缓存"
        case "preview-5": "诊断日志"
        case "preview-6": "旧安装包"
        case "preview-7": "崩溃报告"
        case "preview-8": "参考资料压缩包"
        default: URL(fileURLWithPath: candidate.path).lastPathComponent
        }
    }
}

private struct SC15PreviewMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct SC15PreviewCandidateRow: View {
    let name: String
    let path: String

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "square")
                .foregroundStyle(.secondary)
                .accessibilityLabel("未勾选")
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.medium))
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.recessedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
#endif
