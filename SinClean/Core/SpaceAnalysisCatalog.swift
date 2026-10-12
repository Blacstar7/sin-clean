import Foundation

// SC-3.3 空间分析结果模型与语义。
// 与清理域完全分离：不复用 CleanupFileCandidate、CleanupScanResult、ScanLocation 或 CleanupViewModel。
// 六项语义的冻结值见 work/SC-3.3-frozen-semantics.md，本文件即其可执行表达。

// MARK: - 条目类型

enum SpaceAnalysisEntryKind: String, CaseIterable, Identifiable, Sendable {
    case regularFile = "文件"
    case directory = "目录"
    case package = "包"
    case symbolicLink = "符号链接"
    case other = "其他"

    var id: Self { self }
}

// MARK: - 条目

struct SpaceAnalysisEntry: Identifiable, Hashable, Sendable {
    var id: String { path }

    let path: String
    let displayName: String
    let kind: SpaceAnalysisEntryKind
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let modifiedAt: Date?
    let rootPath: String
    /// SC-3.4：同一 (st_dev, st_ino) 硬链接组的标识；nil 表示不属于任何硬链接组。
    let linkGroupID: String?
    /// SC-3.4：云端占位（SF_DATALESS 置位），当前未下载。
    let isDatalessPlaceholder: Bool

    init(
        path: String,
        displayName: String,
        kind: SpaceAnalysisEntryKind,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        modifiedAt: Date?,
        rootPath: String,
        linkGroupID: String? = nil,
        isDatalessPlaceholder: Bool = false
    ) {
        self.path = path
        self.displayName = displayName
        self.kind = kind
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.modifiedAt = modifiedAt
        self.rootPath = rootPath
        self.linkGroupID = linkGroupID
        self.isDatalessPlaceholder = isDatalessPlaceholder
    }
}

// MARK: - 目录树节点

struct SpaceAnalysisTreeNode: Identifiable, Hashable, Sendable {
    var id: String { path }

    let path: String
    let displayName: String
    let depth: Int
    let totalBytes: Int64
    let ownFileBytes: Int64
    let childDirectoryCount: Int
    let fileCount: Int
    let isReadable: Bool
    let rootPath: String
}

// MARK: - SC-3.4 去重与占位摘要

/// 一轮扫描的去重与占位账目。数值口径见 work/SC-3.4-frozen-semantics.md。
struct SpaceAnalysisDeduplicationSummary: Hashable, Sendable {
    /// 识别到的硬链接组数（同一 (st_dev, st_ino) 为同一组）。
    let hardLinkGroupCount: Int
    /// 硬链接组内被计入分母之外的成员数。
    let hardLinkMemberCount: Int
    /// 因硬链接去重而未计入分母的字节数。
    let deduplicatedBytes: Int64
    /// 被设备边界阻止合并的组键碰撞次数；正常为 0。
    let crossDeviceGroupCount: Int
    /// 云端占位条目数。
    let datalessPlaceholderCount: Int
    /// 云端占位条目的逻辑大小合计（当前未占用）。
    let datalessLogicalBytes: Int64
    /// 是否存在需要带上界措辞的场景（APFS 克隆无法查询，只要扫描到常规文件即成立）。
    let capacityIsUpperBound: Bool

    static let empty = SpaceAnalysisDeduplicationSummary(
        hardLinkGroupCount: 0,
        hardLinkMemberCount: 0,
        deduplicatedBytes: 0,
        crossDeviceGroupCount: 0,
        datalessPlaceholderCount: 0,
        datalessLogicalBytes: 0,
        capacityIsUpperBound: false
    )

    var hasHardLinks: Bool { hardLinkGroupCount > 0 }
    var hasDatalessPlaceholder: Bool { datalessPlaceholderCount > 0 }

    /// 界面上用于说明容量精度的措辞。
    var precisionNote: String {
        if capacityIsUpperBound {
            return String(localized: "分配大小之和；若存在 APFS 克隆，实际占用可能更小（macOS 未提供克隆查询接口）")
        }
        return String(localized: "分配大小之和")
    }

    var hardLinkNote: String? {
        guard hasHardLinks else { return nil }
        return String(localized: "已按硬链接去重：\(hardLinkGroupCount.formatted()) 组、\(hardLinkMemberCount.formatted()) 个重复成员，少计 \(SpaceAnalysisByteText.bytes(deduplicatedBytes))")
    }

    var datalessNote: String? {
        guard hasDatalessPlaceholder else { return nil }
        return String(localized: "\(datalessPlaceholderCount.formatted()) 个云端占位条目尚未下载：当前不占用空间，逻辑大小合计 \(SpaceAnalysisByteText.bytes(datalessLogicalBytes))，下载后会占用更多空间")
    }
}

// MARK: - 容量条分母语义

enum SpaceAnalysisDenominatorKind: String, Sendable {
    case scannedTotal = "本次扫描已统计总量"
    case empty = "尚未统计到容量"

    var localizedTitle: String {
        switch self {
        case .scannedTotal: String(localized: "本次扫描已统计总量")
        case .empty: String(localized: "尚未统计到容量")
        }
    }
}

struct SpaceAnalysisCapacitySegment: Identifiable, Hashable, Sendable {
    var id: String { path }

    let path: String
    let displayName: String
    let bytes: Int64
    let fraction: Double
    let isAggregate: Bool
}

struct SpaceAnalysisCapacityBar: Hashable, Sendable {
    let segments: [SpaceAnalysisCapacitySegment]
    let denominatorBytes: Int64
    let denominatorKind: SpaceAnalysisDenominatorKind
    let isComplete: Bool
    let unreadableDirectoryCount: Int

    static let segmentLimit = 8

    // 分母为 0 时绝不显示 0%：分母类型本身会切到 .empty。
    var percentageText: String {
        switch denominatorKind {
        case .empty:
            String(localized: "尚未统计到容量")
        case .scannedTotal:
            isComplete
                ? String(localized: "已统计 \(SpaceAnalysisByteText.bytes(denominatorBytes))")
                : String(localized: "已统计 \(SpaceAnalysisByteText.bytes(denominatorBytes))（不完整）")
        }
    }
}

// MARK: - 扫描覆盖摘要（复用通用扫描基础设施，不修改其定义）

struct SpaceAnalysisScanSummary: Hashable, Sendable {
    let inspectedEntryCount: Int
    let unreadableDirectoryCount: Int
    let skippedSymbolicLinkCount: Int
    let unknownSizeCount: Int
    let scannedTotalBytes: Int64
    let startedAt: Date
    let finishedAt: Date
    let cancelled: Bool

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

// MARK: - SC-3.4 语义常量

enum SpaceAnalysisCapacityPrecision {
    /// 硬链接去重后的分配字节之和为精确值。
    static let hardLinkDeduplication = "精确值（按 (设备号, inode) 去重）"
    /// 存在克隆可能时为上界。
    static let cloneUpperBound = "上界（APFS 克隆无法查询）"
    /// 云端占位为当前占用。
    static let datalessCurrentUsage = "当前占用（未下载）"
}

// MARK: - 排序语义

enum SpaceAnalysisSortKey: String, CaseIterable, Identifiable, Sendable {
    case size = "大小"
    case modifiedAt = "修改时间"
    case name = "名称"

    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .size: String(localized: "大小")
        case .modifiedAt: String(localized: "修改时间")
        case .name: String(localized: "名称")
        }
    }
}

struct SpaceAnalysisSortDescriptor: Hashable, Sendable {
    var key: SpaceAnalysisSortKey
    var ascending: Bool

    static let defaultValue = SpaceAnalysisSortDescriptor(key: .size, ascending: false)

    // 稳定性：任何相等都以 path 字典序升序作最终 tie-breaker；
    // modifiedAt 为 nil 的条目在两种方向下都排在末尾。
    func sorted(_ entries: [SpaceAnalysisEntry]) -> [SpaceAnalysisEntry] {
        entries.sorted { lhs, rhs in
            switch key {
            case .size:
                if lhs.allocatedBytes != rhs.allocatedBytes {
                    return ascending
                        ? lhs.allocatedBytes < rhs.allocatedBytes
                        : lhs.allocatedBytes > rhs.allocatedBytes
                }
            case .modifiedAt:
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case (nil, nil):
                    break
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                case (let left?, let right?):
                    if left != right {
                        return ascending ? left < right : left > right
                    }
                }
            case .name:
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
                }
            }
            return lhs.path < rhs.path
        }
    }
}

// MARK: - 类型筛选语义（白名单）

enum SpaceAnalysisTypeGroup: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case video = "视频"
    case image = "图片"
    case audio = "音频"
    case document = "文档"
    case archive = "压缩包"
    case installer = "安装包"
    case code = "代码"
    case other = "其他类型"

    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .all: String(localized: "全部")
        case .video: String(localized: "视频")
        case .image: String(localized: "图片")
        case .audio: String(localized: "音频")
        case .document: String(localized: "文档")
        case .archive: String(localized: "压缩包")
        case .installer: String(localized: "安装包")
        case .code: String(localized: "代码")
        case .other: String(localized: "其他类型")
        }
    }

    var fileExtensions: Set<String>? {
        switch self {
        case .all:
            nil
        case .video:
            ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg", "ts", "m2ts"]
        case .image:
            ["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "raw", "cr2", "nef", "arw", "psd", "svg"]
        case .audio:
            ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "wma", "alac", "mid", "midi"]
        case .document:
            ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "md", "csv", "epub"]
        case .archive:
            ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "tbz", "iso", "dmg", "pkg", "jar", "war"]
        case .installer:
            ["app", "appex", "bundle", "framework", "plugin", "prefpane", "qlgenerator", "mobileconfig", "xip", "mpkg"]
        case .code:
            ["swift", "m", "mm", "h", "c", "cpp", "hpp", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "java", "kt", "sh", "zsh", "json", "yml", "yaml", "xml", "plist", "html", "css", "scss", "sql", "toml"]
        case .other:
            []
        }
    }

    func matches(_ entry: SpaceAnalysisEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .other:
            let known = Self.allCases
                .filter { $0 != .all && $0 != .other }
                .compactMap(\.fileExtensions)
                .reduce(into: Set<String>()) { $0.formUnion($1) }
            let ext = Self.fileExtension(of: entry)
            return ext.isEmpty || !known.contains(ext)
        default:
            guard let extensions = fileExtensions, !extensions.isEmpty else { return false }
            return extensions.contains(Self.fileExtension(of: entry))
        }
    }

    static func fileExtension(of entry: SpaceAnalysisEntry) -> String {
        let ext = (entry.displayName as NSString).pathExtension
        return ext.lowercased()
    }
}

// MARK: - 大文件定义

struct SpaceAnalysisLargeFileRule: Hashable, Sendable {
    static let defaultValue = SpaceAnalysisLargeFileRule(minimumBytes: 100 * 1024 * 1024)

    static let options: [Int64] = [
        50 * 1024 * 1024,
        100 * 1024 * 1024,
        500 * 1024 * 1024,
        1024 * 1024 * 1024
    ]

    let minimumBytes: Int64

    // 边界：恰好等于阈值计入（>=）。
    func matches(_ entry: SpaceAnalysisEntry) -> Bool {
        entry.kind == .regularFile && entry.allocatedBytes >= minimumBytes
    }

    var thresholdText: String { SpaceAnalysisByteText.bytes(minimumBytes) }
}

// MARK: - 展示筛选结果

struct SpaceAnalysisDisplaySelection: Hashable, Sendable {
    let entries: [SpaceAnalysisEntry]
    let totalBytes: Int64
    let itemCount: Int
    let isFiltered: Bool
}

// MARK: - 字节显示

enum SpaceAnalysisByteText {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: value)
    }
}
