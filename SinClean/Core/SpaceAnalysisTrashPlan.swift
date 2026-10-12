import Darwin
import Foundation

// SC-3.5 操作计划与执行收据模型。
// 口径见 work/SC-3.5-frozen-semantics.md：计划冻结身份快照，收据只描述发生的事实。

/// 可执行项目的身份快照。执行时据此复用 ExecutionSafetyCore 的执行前复验。
struct SpaceAnalysisTrashPlanItem: Identifiable, Hashable, Sendable {
    var id: String { path }

    let path: String
    let displayName: String
    let rootPath: String
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let deviceID: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let sharesPhysicalFile: Bool
    let isDatalessPlaceholder: Bool
}

/// 冻结后的操作计划：执行期间不得变更。
struct SpaceAnalysisTrashPlan: Hashable, Sendable {
    let frozenAt: Date
    let items: [SpaceAnalysisTrashPlanItem]
    /// 去重后的字节合计（沿用 SC-3.4 口径）。
    let deduplicatedBytes: Int64
    /// 允许的执行根路径集合，交给安全核心做白名单判定。
    let allowedRootPaths: Set<String>

    var itemCount: Int { items.count }
    var hasDatalessPlaceholder: Bool { items.contains { $0.isDatalessPlaceholder } }
    var hasSharedPhysicalFile: Bool { items.contains { $0.sharesPhysicalFile } }
}

struct SpaceAnalysisTrashReceiptItem: Identifiable, Hashable, Sendable {
    var id: String { path }

    let path: String
    let displayName: String
    /// 直接取自 ExecutionResultReasonCode.rawValue，绝不由本地化文案反推。
    let reasonCode: String
    let text: String
    let bytes: Int64
    let movedToTrash: Bool
    let finishedAt: Date
}

struct SpaceAnalysisTrashReceipt: Hashable, Sendable {
    let planFrozenAt: Date
    let startedAt: Date
    let finishedAt: Date
    let items: [SpaceAnalysisTrashReceiptItem]
    let cancelled: Bool

    var movedCount: Int { items.filter(\.movedToTrash).count }
    var skippedCount: Int { items.count - movedCount }
    var movedBytes: Int64 { items.filter(\.movedToTrash).reduce(Int64(0)) { $0 + $1.bytes } }

    /// 供界面直接展示的逐项摘要，语义与收据条目一致。
    var summaryLines: [String] {
        items.map { item in
            "\(item.movedToTrash ? String(localized: "已移入废纸篓") : String(localized: "未移动"))｜\(item.displayName)｜\(item.reasonCode)｜\(SpaceAnalysisByteText.bytes(item.bytes))"
        }
    }
}

/// 把扫描条目转换为可供安全核心复验的身份快照。
///
/// 该函数只做字段搬运：`deviceID`／`inode`／`logicalBytes`／修改时间必须来自扫描时的 `lstat` 快照，
/// 不得在执行时重新读取后再回填，否则安全核心的「身份一致／元数据一致」校验将失去意义。
enum SpaceAnalysisTrashCandidateFactory {
    static func planItem(from entry: SpaceAnalysisEntry) throws -> SpaceAnalysisTrashPlanItem {
        var info = stat()
        guard entry.path.withCString({ Darwin.lstat($0, &info) }) == 0 else {
            throw SpaceAnalysisTrashPlanError.pathLookupFailed(path: entry.path, errorCode: errno)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw SpaceAnalysisTrashPlanError.notARegularFile(path: entry.path)
        }
        return SpaceAnalysisTrashPlanItem(
            path: entry.path,
            displayName: entry.displayName,
            rootPath: entry.rootPath,
            allocatedBytes: entry.allocatedBytes,
            logicalBytes: Int64(info.st_size),
            deviceID: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            sharesPhysicalFile: entry.linkGroupID != nil,
            isDatalessPlaceholder: entry.isDatalessPlaceholder
        )
    }
}

enum SpaceAnalysisTrashPlanError: LocalizedError, Sendable {
    case pathLookupFailed(path: String, errorCode: Int32)
    case notARegularFile(path: String)

    var errorDescription: String? {
        switch self {
        case .pathLookupFailed(let path, _):
            String(localized: "无法读取“\(path)”的当前状态，已从计划中排除。")
        case .notARegularFile(let path):
            String(localized: "“\(path)”不是常规文件（可能是目录或符号链接），本轮不处理。")
        }
    }
}
