import Foundation
import SwiftUI

// SC-3.3 空间分析结果状态。
// 独立持有：不与清理域共享状态，不构造清理候选，不触发任何文件操作。

@MainActor
final class SpaceAnalysisResultsViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case cancelled

        var title: String {
            switch self {
            case .idle: String(localized: "尚未扫描")
            case .scanning: String(localized: "正在扫描")
            case .finished: String(localized: "扫描完成")
            case .cancelled: String(localized: "已取消")
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: SpaceAnalysisScanProgress?
    @Published private(set) var outcome: SpaceAnalysisScanOutcome?
    @Published private(set) var expandedPaths: Set<String> = []

    @Published var sortDescriptor: SpaceAnalysisSortDescriptor = .defaultValue
    @Published var typeGroup: SpaceAnalysisTypeGroup = .all
    @Published var largeFileRule: SpaceAnalysisLargeFileRule = .defaultValue

    private let scanner: any SpaceAnalysisScanning
    private let ignoreList: IgnoreListStore?
    private var scanTask: Task<Void, Never>?

    init(
        scanner: any SpaceAnalysisScanning = SpaceAnalysisScanner(),
        ignoreList: IgnoreListStore? = nil
    ) {
        self.scanner = scanner
        self.ignoreList = ignoreList
    }

    var isScanning: Bool { phase == .scanning }

    var summary: SpaceAnalysisScanSummary? { outcome?.summary }

    /// SC-3.4：本轮扫描的去重与占位账目。
    var deduplication: SpaceAnalysisDeduplicationSummary { outcome?.deduplication ?? .empty }

    /// SC-3.4：容量数字的精度口径，必须与容量条一并呈现。
    var precisionNote: String { deduplication.precisionNote }

    var hasHardLinks: Bool { deduplication.hasHardLinks }
    var hasDatalessPlaceholder: Bool { deduplication.hasDatalessPlaceholder }

    var scannedScopeCount: Int {
        Set(outcome?.nodes.filter { $0.depth == 0 }.map(\.path) ?? []).count
    }

    // MARK: - 扫描控制（协作式取消）

    func startScan(scopes: [SpaceAnalysisScope]) {
        guard phase != .scanning else { return }
        guard !scopes.isEmpty else { return }
        scanTask?.cancel()
        phase = .scanning
        progress = nil
        outcome = nil
        expandedPaths = []

        let scanner = self.scanner
        scanTask = Task { [weak self] in
            let result = await scanner.scan(scopes: scopes) { update in
                await MainActor.run {
                    guard let self, self.phase == .scanning else { return }
                    self.progress = update
                }
            }
            await MainActor.run {
                self?.apply(result)
            }
        }
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        scanTask?.cancel()
    }

    func clearResult() {
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
        progress = nil
        outcome = nil
        expandedPaths = []
    }

    private func apply(_ result: SpaceAnalysisScanOutcome) {
        outcome = result
        phase = result.summary.cancelled ? .cancelled : .finished
        progress = nil
        scanTask = nil
        expandedPaths = Set(result.nodes.filter { $0.depth == 0 }.map(\.path))
    }

    // MARK: - 树展开

    func toggleExpansion(_ path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
        }
    }

    func expandAll() {
        expandedPaths = Set(outcome?.nodes.filter { $0.childDirectoryCount > 0 }.map(\.path) ?? [])
    }

    func collapseAll() {
        // 全部折叠后只保留根行；聚合值来自扫描结果，不因折叠而重算。
        expandedPaths = []
    }

    // MARK: - 忽略列表（仅精确路径规则参与排除）

    var ignoredPathSet: Set<String> {
        guard let ignoreList else { return [] }
        var result: Set<String> = []
        for rule in ignoreList.rules {
            switch rule.kind {
            case .fixedPath(let path), .applicationPath(let path):
                result.insert(IgnorePath.normalized(path))
            default:
                break
            }
        }
        return result
    }

    // MARK: - 大文件列表（阈值 + 忽略排除 + 排序 + 筛选）

    var largeFileCandidates: [SpaceAnalysisEntry] {
        guard let outcome else { return [] }
        return outcome.entries.filter { largeFileRule.matches($0) }
    }

    var excludedByIgnoreCount: Int {
        let ignored = ignoredPathSet
        guard !ignored.isEmpty else { return 0 }
        return largeFileCandidates.filter { ignored.contains(IgnorePath.normalized($0.path)) }.count
    }

    var largeFiles: [SpaceAnalysisEntry] {
        let ignored = ignoredPathSet
        guard !ignored.isEmpty else { return largeFileCandidates }
        return largeFileCandidates.filter { !ignored.contains(IgnorePath.normalized($0.path)) }
    }

    var displaySelection: SpaceAnalysisDisplaySelection {
        let sorted = sortDescriptor.sorted(largeFiles)
        let filtered = sorted.filter { typeGroup.matches($0) }
        let total = filtered.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        return SpaceAnalysisDisplaySelection(
            entries: filtered,
            totalBytes: total,
            itemCount: filtered.count,
            isFiltered: typeGroup != .all
        )
    }

    // MARK: - 目录树行（按展开状态过滤，聚合值不受折叠影响）

    var treeRows: [SpaceAnalysisTreeNode] {
        guard let nodes = outcome?.nodes, !nodes.isEmpty else { return [] }
        let childrenByParent = Dictionary(grouping: nodes.filter { $0.depth > 0 }) { node in
            Self.parentPath(of: node.path) ?? ""
        }
        var rows: [SpaceAnalysisTreeNode] = []
        func append(_ node: SpaceAnalysisTreeNode) {
            rows.append(node)
            guard expandedPaths.contains(node.path) else { return }
            let children = (childrenByParent[node.path] ?? []).sorted { lhs, rhs in
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                return lhs.path < rhs.path
            }
            for child in children { append(child) }
        }
        for root in nodes.filter({ $0.depth == 0 }).sorted(by: { $0.path < $1.path }) {
            append(root)
        }
        return rows
    }

    static func parentPath(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return nil }
        return parent
    }

    // MARK: - 容量条（分母 = 本次扫描已统计总量）

    var capacityBar: SpaceAnalysisCapacityBar {
        guard let outcome, !outcome.nodes.isEmpty else {
            return SpaceAnalysisCapacityBar(
                segments: [],
                denominatorBytes: 0,
                denominatorKind: .empty,
                isComplete: false,
                unreadableDirectoryCount: 0
            )
        }
        let summary = outcome.summary
        let isComplete = summary.unreadableDirectoryCount == 0 && !summary.cancelled
        let denominator = summary.scannedTotalBytes
        let roots = outcome.nodes.filter { $0.depth == 0 }
        guard denominator > 0, !roots.isEmpty else {
            return SpaceAnalysisCapacityBar(
                segments: [],
                denominatorBytes: 0,
                denominatorKind: .empty,
                isComplete: isComplete,
                unreadableDirectoryCount: summary.unreadableDirectoryCount
            )
        }

        var segments: [SpaceAnalysisCapacitySegment] = []
        if roots.count > 1 {
            segments = roots
                .sorted { lhs, rhs in
                    if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                    return lhs.path < rhs.path
                }
                .prefix(SpaceAnalysisCapacityBar.segmentLimit)
                .map { segment(for: $0, denominator: denominator, isAggregate: false) }
        } else if let root = roots.first {
            let children = outcome.nodes
                .filter { $0.depth == 1 && $0.rootPath == root.rootPath }
                .sorted { lhs, rhs in
                    if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                    return lhs.path < rhs.path
                }
            let headline = Array(children.prefix(SpaceAnalysisCapacityBar.segmentLimit - 2))
            segments = headline.map { segment(for: $0, denominator: denominator, isAggregate: false) }
            if root.ownFileBytes > 0 {
                segments.append(SpaceAnalysisCapacitySegment(
                    path: root.path + "#own",
                    displayName: String(localized: "\(root.displayName) 直属文件"),
                    bytes: root.ownFileBytes,
                    fraction: Double(root.ownFileBytes) / Double(denominator),
                    isAggregate: false
                ))
            }
            let accounted = segments.reduce(Int64(0)) { $0 + $1.bytes }
            let remainder = denominator - accounted
            if remainder > 0 {
                segments.append(SpaceAnalysisCapacitySegment(
                    path: root.path + "#other",
                    displayName: String(localized: "其他"),
                    bytes: remainder,
                    fraction: Double(remainder) / Double(denominator),
                    isAggregate: true
                ))
            }
        }

        return SpaceAnalysisCapacityBar(
            segments: segments,
            denominatorBytes: denominator,
            denominatorKind: .scannedTotal,
            isComplete: isComplete,
            unreadableDirectoryCount: summary.unreadableDirectoryCount
        )
    }

    private func segment(
        for node: SpaceAnalysisTreeNode,
        denominator: Int64,
        isAggregate: Bool
    ) -> SpaceAnalysisCapacitySegment {
        SpaceAnalysisCapacitySegment(
            path: node.path,
            displayName: node.displayName,
            bytes: node.totalBytes,
            fraction: denominator > 0 ? Double(node.totalBytes) / Double(denominator) : 0,
            isAggregate: isAggregate
        )
    }

    // MARK: - 诚实文案

    var capabilityNote: String {
        String(localized: "空间分析只读取所选范围内的目录与文件元数据，用于展示目录树、容量条与大文件列表。本轮不移动、不删除、不修改任何文件，也不接入 Quick Look、Finder 或废纸篓。硬链接按 (设备号, inode) 去重后为精确值；APFS 克隆无法通过公开接口查询，故容量为上界；云端占位显示为当前占用。")
    }

    var exclusionNote: String {
        var parts: [String] = []
        parts.append(String(localized: "大文件阈值 \(largeFileRule.thresholdText)"))
        if excludedByIgnoreCount > 0 {
            parts.append(String(localized: "已按忽略列表排除 \(excludedByIgnoreCount) 项"))
        }
        if let summary {
            if summary.unreadableDirectoryCount > 0 {
                parts.append(String(localized: "\(summary.unreadableDirectoryCount) 个目录不可读，容量为不完整统计"))
            }
            if summary.skippedSymbolicLinkCount > 0 {
                parts.append(String(localized: "跳过 \(summary.skippedSymbolicLinkCount) 个符号链接（不跟随目标）"))
            }
            if summary.cancelled {
                parts.append(String(localized: "本次扫描已取消，以下为部分数据"))
            }
        }
        if let hardLinkNote = deduplication.hardLinkNote {
            parts.append(hardLinkNote)
        }
        if let datalessNote = deduplication.datalessNote {
            parts.append(datalessNote)
        }
        if deduplication.crossDeviceGroupCount > 0 {
            parts.append(String(localized: "跨设备同号 inode \(deduplication.crossDeviceGroupCount.formatted()) 例，未合并计算"))
        }
        return parts.joined(separator: " · ")
    }
}
