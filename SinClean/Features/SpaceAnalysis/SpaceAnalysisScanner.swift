import Darwin
import Foundation

// SC-3.3 空间分析扫描器。
// 只读遍历：不跟随符号链接、不移动文件、不调用 Finder / Quick Look / 废纸篓。
// 与清理域扫描器完全独立，不复用 CleanupFileCandidate、ScanLocation 或 DiskScanner。

struct SpaceAnalysisScanProgress: Sendable, Hashable {
    let currentRoot: String
    let finishedRootCount: Int
    let totalRootCount: Int
    let inspectedEntryCount: Int
    let scannedBytes: Int64
    let unreadableDirectoryCount: Int
}

struct SpaceAnalysisScanOutcome: Sendable {
    let entries: [SpaceAnalysisEntry]
    let nodes: [SpaceAnalysisTreeNode]
    let summary: SpaceAnalysisScanSummary
    /// SC-3.4：去重与占位账目；口径见 work/SC-3.4-frozen-semantics.md。
    let deduplication: SpaceAnalysisDeduplicationSummary

    init(
        entries: [SpaceAnalysisEntry],
        nodes: [SpaceAnalysisTreeNode],
        summary: SpaceAnalysisScanSummary,
        deduplication: SpaceAnalysisDeduplicationSummary = .empty
    ) {
        self.entries = entries
        self.nodes = nodes
        self.summary = summary
        self.deduplication = deduplication
    }
}

protocol SpaceAnalysisScanning: Sendable {
    func scan(
        scopes: [SpaceAnalysisScope],
        progress: @escaping @Sendable (SpaceAnalysisScanProgress) async -> Void
    ) async -> SpaceAnalysisScanOutcome
}

actor SpaceAnalysisScanner: SpaceAnalysisScanning {
    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "prefpane", "qlgenerator", "xpc"
    ]
    private static let maximumDepth = 64
    private static let cancellationCheckInterval = 256

    private let progressMinimumInterval: TimeInterval

    // SC-3.4 去重账本：跨范围共享，保证同一 (dev, ino) 在一次扫描内只计一次。
    private var linkLedger: [String: Int64] = [:]
    private var linkGroupCount = 0
    private var linkMemberCount = 0
    private var deduplicatedBytes: Int64 = 0
    private var linkInodeDevices: [UInt64: Set<UInt32>] = [:]

    init(progressMinimumInterval: TimeInterval = 0.1) {
        self.progressMinimumInterval = progressMinimumInterval
    }

    func scan(
        scopes: [SpaceAnalysisScope],
        progress: @escaping @Sendable (SpaceAnalysisScanProgress) async -> Void
    ) async -> SpaceAnalysisScanOutcome {
        let startedAt = Date()
        linkLedger.removeAll(keepingCapacity: false)
        linkGroupCount = 0
        linkMemberCount = 0
        deduplicatedBytes = 0
        linkInodeDevices.removeAll(keepingCapacity: false)
        var entries: [SpaceAnalysisEntry] = []
        var nodes: [SpaceAnalysisTreeNode] = []
        var inspected = 0
        var unreadable = 0
        var skippedLinks = 0
        var unknownSize = 0
        var scannedBytes: Int64 = 0
        var cancelled = false
        var lastPublishedAt = Date.distantPast

        for (index, scope) in scopes.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let output = await scanRoot(
                scope: scope,
                rootIndex: index,
                rootCount: scopes.count,
                baselineInspected: inspected,
                baselineBytes: scannedBytes,
                baselineUnreadable: unreadable,
                lastPublishedAt: lastPublishedAt,
                progress: progress
            )
            entries.append(contentsOf: output.entries)
            nodes.append(contentsOf: output.nodes)
            inspected += output.inspected
            unreadable += output.unreadable
            skippedLinks += output.skippedLinks
            unknownSize += output.unknownSize
            scannedBytes += output.bytes
            lastPublishedAt = output.lastPublishedAt
            if output.cancelled {
                cancelled = true
                break
            }
        }

        let finishedAt = Date()
        await progress(
            SpaceAnalysisScanProgress(
                currentRoot: cancelled ? String(localized: "已取消") : String(localized: "扫描完成"),
                finishedRootCount: cancelled ? 0 : scopes.count,
                totalRootCount: scopes.count,
                inspectedEntryCount: inspected,
                scannedBytes: scannedBytes,
                unreadableDirectoryCount: unreadable
            )
        )

        let crossDeviceGroups = linkInodeDevices.values.filter { $0.count > 1 }.count
        let deduplication = SpaceAnalysisDeduplicationSummary(
            hardLinkGroupCount: linkGroupCount,
            hardLinkMemberCount: linkMemberCount,
            deduplicatedBytes: deduplicatedBytes,
            crossDeviceGroupCount: crossDeviceGroups,
            datalessPlaceholderCount: entries.filter(\.isDatalessPlaceholder).count,
            datalessLogicalBytes: entries.filter(\.isDatalessPlaceholder).reduce(Int64(0)) { $0 + $1.logicalBytes },
            capacityIsUpperBound: entries.contains { $0.kind == .regularFile || $0.kind == .package }
        )

        return SpaceAnalysisScanOutcome(
            entries: entries,
            nodes: nodes,
            summary: SpaceAnalysisScanSummary(
                inspectedEntryCount: inspected,
                unreadableDirectoryCount: unreadable,
                skippedSymbolicLinkCount: skippedLinks,
                unknownSizeCount: unknownSize,
                scannedTotalBytes: scannedBytes,
                startedAt: startedAt,
                finishedAt: finishedAt,
                cancelled: cancelled
            ),
            deduplication: deduplication
        )
    }

    // MARK: - 单根遍历

    private struct MutableNode {
        let path: String
        let displayName: String
        let depth: Int
        let rootPath: String
        var parentIndex: Int?
        var ownFileBytes: Int64 = 0
        var fileCount: Int = 0
        var childDirectoryCount: Int = 0
        var isReadable: Bool = true
        var totalBytes: Int64 = 0
    }

    private struct RootOutput {
        var entries: [SpaceAnalysisEntry] = []
        var nodes: [SpaceAnalysisTreeNode] = []
        var inspected = 0
        var unreadable = 0
        var skippedLinks = 0
        var unknownSize = 0
        var bytes: Int64 = 0
        var cancelled = false
        var lastPublishedAt = Date.distantPast
    }

    private struct Frame {
        let path: String
        let depth: Int
        let nodeIndex: Int
    }

    private func scanRoot(
        scope: SpaceAnalysisScope,
        rootIndex: Int,
        rootCount: Int,
        baselineInspected: Int,
        baselineBytes: Int64,
        baselineUnreadable: Int,
        lastPublishedAt: Date,
        progress: @escaping @Sendable (SpaceAnalysisScanProgress) async -> Void
    ) async -> RootOutput {
        var output = RootOutput()
        output.lastPublishedAt = lastPublishedAt

        await progress(
            SpaceAnalysisScanProgress(
                currentRoot: scope.displayName,
                finishedRootCount: rootIndex,
                totalRootCount: rootCount,
                inspectedEntryCount: baselineInspected,
                scannedBytes: baselineBytes,
                unreadableDirectoryCount: baselineUnreadable
            )
        )
        // 该次发布同时重置节流基准，确保后续进度不会早于最小发布间隔。
        output.lastPublishedAt = Date()

        var mutableNodes: [MutableNode] = []
        var nodeIndexByPath: [String: Int] = [:]
        let rootPath = scope.path

        func makeNodeIndex(path: String, displayName: String, depth: Int, parentIndex: Int?) -> Int {
            if let existing = nodeIndexByPath[path] { return existing }
            mutableNodes.append(MutableNode(
                path: path,
                displayName: displayName,
                depth: depth,
                rootPath: rootPath,
                parentIndex: parentIndex
            ))
            let index = mutableNodes.count - 1
            nodeIndexByPath[path] = index
            if let parentIndex {
                mutableNodes[parentIndex].childDirectoryCount += 1
            }
            return index
        }

        let rootIndexInNodes = makeNodeIndex(
            path: rootPath,
            displayName: scope.displayName,
            depth: 0,
            parentIndex: nil
        )
        var stack: [Frame] = [Frame(path: rootPath, depth: 0, nodeIndex: rootIndexInNodes)]

        while let frame = stack.popLast() {
            if Task.isCancelled {
                output.cancelled = true
                break
            }
            guard frame.depth <= Self.maximumDepth else {
                mutableNodes[frame.nodeIndex].isReadable = false
                output.unreadable += 1
                continue
            }

            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: frame.path)
            } catch {
                // 不可读目录：标记为不可读并计数，绝不计为 0 字节。
                mutableNodes[frame.nodeIndex].isReadable = false
                output.unreadable += 1
                continue
            }

            for name in names {
                if output.inspected % Self.cancellationCheckInterval == 0, Task.isCancelled {
                    output.cancelled = true
                    break
                }
                let childPath = (frame.path as NSString).appendingPathComponent(name)
                var info = stat()
                guard childPath.withCString({ Darwin.lstat($0, &info) }) == 0 else {
                    output.unknownSize += 1
                    continue
                }
                let mode = info.st_mode & mode_t(S_IFMT)
                let allocated = Int64(info.st_blocks) * 512
                let logical = Int64(info.st_size)
                let modifiedAt = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                output.inspected += 1

                switch mode {
                case mode_t(S_IFLNK):
                    output.entries.append(SpaceAnalysisEntry(
                        path: childPath,
                        displayName: name,
                        kind: .symbolicLink,
                        allocatedBytes: allocated,
                        logicalBytes: logical,
                        modifiedAt: modifiedAt,
                        rootPath: rootPath
                    ))
                    output.skippedLinks += 1

                case mode_t(S_IFDIR):
                    let ext = (name as NSString).pathExtension.lowercased()
                    if Self.packageExtensions.contains(ext) {
                        // 包目录：不建子节点，容量由其内部只读递归统计。
                        let packageBytes = measurePackage(at: childPath)
                        output.entries.append(SpaceAnalysisEntry(
                            path: childPath,
                            displayName: name,
                            kind: .package,
                            allocatedBytes: packageBytes,
                            logicalBytes: packageBytes,
                            modifiedAt: modifiedAt,
                            rootPath: rootPath
                        ))
                        mutableNodes[frame.nodeIndex].ownFileBytes += packageBytes
                        output.bytes += packageBytes
                    } else {
                        let childIndex = makeNodeIndex(
                            path: childPath,
                            displayName: name,
                            depth: frame.depth + 1,
                            parentIndex: frame.nodeIndex
                        )
                        stack.append(Frame(path: childPath, depth: frame.depth + 1, nodeIndex: childIndex))
                    }

                case mode_t(S_IFREG):
                    // SC-3.4：硬链接以 (st_dev, st_ino) 为组键去重；只有首次计入的成员进入分母与树累计。
                    // 目录的 st_nlink 表示子目录数，不是硬链接语义，故仅对常规文件判定。
                    var linkGroupID: String?
                    var countsTowardTotal = true
                    if info.st_nlink > 1 {
                        let groupKey = "\(info.st_dev):\(info.st_ino)"
                        linkGroupID = groupKey
                        linkInodeDevices[info.st_ino, default: []].insert(UInt32(info.st_dev))
                        if linkLedger[groupKey] == nil {
                            linkLedger[groupKey] = allocated
                            linkGroupCount += 1
                        } else {
                            linkMemberCount += 1
                            deduplicatedBytes += allocated
                            countsTowardTotal = false
                        }
                    }
                    // SC-3.4：云端占位只以 SF_DATALESS 标志判定，不使用 st_blocks 启发式。
                    let isDatalessPlaceholder = (info.st_flags & UInt32(SF_DATALESS)) != 0
                    output.entries.append(SpaceAnalysisEntry(
                        path: childPath,
                        displayName: name,
                        kind: .regularFile,
                        allocatedBytes: allocated,
                        logicalBytes: logical,
                        modifiedAt: modifiedAt,
                        rootPath: rootPath,
                        linkGroupID: linkGroupID,
                        isDatalessPlaceholder: isDatalessPlaceholder
                    ))
                    mutableNodes[frame.nodeIndex].fileCount += 1
                    if countsTowardTotal {
                        mutableNodes[frame.nodeIndex].ownFileBytes += allocated
                        output.bytes += allocated
                    }

                default:
                    output.entries.append(SpaceAnalysisEntry(
                        path: childPath,
                        displayName: name,
                        kind: .other,
                        allocatedBytes: allocated,
                        logicalBytes: logical,
                        modifiedAt: modifiedAt,
                        rootPath: rootPath
                    ))
                }

                if output.inspected % Self.cancellationCheckInterval == 0 {
                    let now = Date()
                    if now.timeIntervalSince(output.lastPublishedAt) >= progressMinimumInterval {
                        output.lastPublishedAt = now
                        await progress(
                            SpaceAnalysisScanProgress(
                                currentRoot: scope.displayName,
                                finishedRootCount: rootIndex,
                                totalRootCount: rootCount,
                                inspectedEntryCount: baselineInspected + output.inspected,
                                scannedBytes: baselineBytes + output.bytes,
                                unreadableDirectoryCount: baselineUnreadable + output.unreadable
                            )
                        )
                    }
                }
            }

            if output.cancelled { break }
        }

        // 后序累加：自底向上把子节点总量并入父节点。
        for index in mutableNodes.indices.sorted(by: { mutableNodes[$0].depth > mutableNodes[$1].depth }) {
            mutableNodes[index].totalBytes += mutableNodes[index].ownFileBytes
            if let parent = mutableNodes[index].parentIndex {
                mutableNodes[parent].totalBytes += mutableNodes[index].totalBytes
            }
        }

        output.nodes = mutableNodes.map { node in
            SpaceAnalysisTreeNode(
                path: node.path,
                displayName: node.displayName,
                depth: node.depth,
                totalBytes: node.totalBytes,
                ownFileBytes: node.ownFileBytes,
                childDirectoryCount: node.childDirectoryCount,
                fileCount: node.fileCount,
                isReadable: node.isReadable,
                rootPath: node.rootPath
            )
        }

        if !output.cancelled {
            let now = Date()
            if now.timeIntervalSince(output.lastPublishedAt) >= progressMinimumInterval {
                output.lastPublishedAt = now
                await progress(
                    SpaceAnalysisScanProgress(
                        currentRoot: scope.displayName,
                        finishedRootCount: rootIndex + 1,
                        totalRootCount: rootCount,
                        inspectedEntryCount: baselineInspected + output.inspected,
                        scannedBytes: baselineBytes + output.bytes,
                        unreadableDirectoryCount: baselineUnreadable + output.unreadable
                    )
                )
            }
        }

        return output
    }

    // 包目录容量的只读递归统计：不建节点，不跟随符号链接。
    private func measurePackage(at path: String) -> Int64 {
        var total: Int64 = 0
        var stack: [String] = [path]
        var visitedDirectoryCount = 0
        while let current = stack.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current) else { continue }
            for name in names {
                let child = (current as NSString).appendingPathComponent(name)
                var info = stat()
                guard child.withCString({ Darwin.lstat($0, &info) }) == 0 else { continue }
                let mode = info.st_mode & mode_t(S_IFMT)
                if mode == mode_t(S_IFLNK) { continue }
                if mode == mode_t(S_IFDIR) {
                    stack.append(child)
                } else {
                    total += Int64(info.st_blocks) * 512
                }
            }
            visitedDirectoryCount += 1
            if visitedDirectoryCount % 128 == 0, Task.isCancelled { break }
        }
        return total
    }
}
