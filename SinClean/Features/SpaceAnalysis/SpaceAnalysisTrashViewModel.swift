import AppKit
import Foundation
import SwiftUI

// SC-3.5 手动处理状态：逐项选择、审阅、执行与收据。
// 口径见 work/SC-3.5-frozen-semantics.md；默认不选，且不提供任何批量捷径。

@MainActor
final class SpaceAnalysisTrashViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case executing
        case finished

        var title: String {
            switch self {
            case .idle: String(localized: "未开始")
            case .executing: String(localized: "正在移入废纸篓")
            case .finished: String(localized: "执行结束")
            }
        }
    }

    /// 选择集以路径为键，默认空。
    @Published private(set) var selection: Set<String> = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var receipt: SpaceAnalysisTrashReceipt?
    @Published private(set) var planItems: [SpaceAnalysisTrashPlanItem] = []
    @Published private(set) var planExcludedCount = 0
    @Published private(set) var planFrozenAt: Date?

    private let executor: SpaceAnalysisTrashExecutor
    private let ignoreList: IgnoreListStore?
    private var executionTask: Task<Void, Never>?

    init(
        executor: SpaceAnalysisTrashExecutor = SpaceAnalysisTrashExecutor(),
        ignoreList: IgnoreListStore? = nil
    ) {
        self.executor = executor
        self.ignoreList = ignoreList
    }

    var isExecuting: Bool { phase == .executing }
    var selectedCount: Int { selection.count }

    /// 命中忽略列表（精确路径规则）的路径一律不可勾选，也不得进入计划。
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

    func isSelectable(_ entry: SpaceAnalysisEntry) -> Bool {
        !ignoredPathSet.contains(IgnorePath.normalized(entry.path))
    }

    func isSelected(_ entry: SpaceAnalysisEntry) -> Bool {
        selection.contains(entry.path)
    }

    /// 逐项切换选择；不可选项目一律拒绝。
    func toggleSelection(_ entry: SpaceAnalysisEntry) {
        guard isSelectable(entry) else { return }
        if selection.contains(entry.path) {
            selection.remove(entry.path)
        } else {
            selection.insert(entry.path)
        }
        planItems = []
        planFrozenAt = nil
        planExcludedCount = 0
    }

    func clearSelection() {
        selection.removeAll()
        planItems = []
        planFrozenAt = nil
        planExcludedCount = 0
    }

    var canExecute: Bool {
        phase != .executing && !selection.isEmpty
    }

    /// 冻结计划：捕获身份快照；非常规文件与忽略列表命中项在执行前再次被排除。
    @discardableResult
    func freezePlan(entries: [SpaceAnalysisEntry]) -> Int {
        let ignored = ignoredPathSet
        var items: [SpaceAnalysisTrashPlanItem] = []
        var excluded = 0
        for entry in entries where selection.contains(entry.path) {
            guard !ignored.contains(IgnorePath.normalized(entry.path)) else {
                excluded += 1
                continue
            }
            do {
                items.append(try SpaceAnalysisTrashCandidateFactory.planItem(from: entry))
            } catch {
                excluded += 1
            }
        }
        planItems = items
        planExcludedCount = excluded
        planFrozenAt = Date()
        return items.count
    }

    /// 执行冻结计划。必须由用户显式触发；取消无副作用地保留选择集。
    func execute(entries: [SpaceAnalysisEntry]) {
        guard canExecute else { return }
        let frozen = planItems
        guard !frozen.isEmpty || freezePlan(entries: entries) > 0 else { return }
        let plan = SpaceAnalysisTrashPlan(
            frozenAt: planFrozenAt ?? Date(),
            items: planItems,
            deduplicatedBytes: deduplicatedBytes(of: planItems),
            allowedRootPaths: Set(planItems.map(\.rootPath))
        )
        phase = .executing
        receipt = nil
        let executor = self.executor
        executionTask = Task { [weak self] in
            let result = await executor.execute(plan: plan) { _, _ in }
            await MainActor.run {
                guard let self else { return }
                self.receipt = result
                self.phase = .finished
                // 已成功移入废纸篓的项目从选择集移除；未执行或被拒的保留，便于用户复核。
                let moved = Set(result.items.filter(\.movedToTrash).map(\.path))
                self.selection.subtract(moved)
                self.planItems = []
                self.planFrozenAt = nil
                self.executionTask = nil
            }
        }
    }

    func cancelExecution() {
        executionTask?.cancel()
    }

    func clearReceipt() {
        receipt = nil
        phase = .idle
    }

    /// 去重后的字节合计：同一 (deviceID, inode) 只计一次。
    func deduplicatedBytes(of items: [SpaceAnalysisTrashPlanItem]) -> Int64 {
        var seen: Set<String> = []
        var total: Int64 = 0
        for item in items {
            let key = "\(item.deviceID):\(item.inode)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            total += item.allocatedBytes
        }
        return total
    }

    var selectedDeduplicatedBytes: Int64 { deduplicatedBytes(of: planItems) }

    /// 含重复成员的字节合计：硬链接成员各计一次，与去重后数字并列呈现。
    var selectedRawBytes: Int64 {
        planItems.reduce(Int64(0)) { $0 + $1.allocatedBytes }
    }

    // MARK: - 只读入口

    var capabilityNote: String {
        String(localized: "手动处理只把您逐项选择的项目移入系统废纸篓；不提供永久删除、全选或批量清空，也不会在分析或选择阶段移动任何文件。")
    }

    var reviewNote: String {
        var parts: [String] = []
        parts.append(String(localized: "已选择 \(selection.count.formatted()) 项"))
        if planFrozenAt != nil {
            parts.append(String(localized: "计划已冻结：去重后合计 \(SpaceAnalysisByteText.bytes(selectedDeduplicatedBytes))，含重复成员合计 \(SpaceAnalysisByteText.bytes(selectedRawBytes))"))
        }
        if planExcludedCount > 0 {
            parts.append(String(localized: "\(planExcludedCount.formatted()) 项因忽略列表或已非常规文件被排除"))
        }
        if planItems.contains(where: \.sharesPhysicalFile) {
            parts.append(String(localized: "含硬链接成员：与另一路径共享同一物理文件，移入废纸篓后另一路径仍指向该文件"))
        }
        if planItems.contains(where: \.isDatalessPlaceholder) {
            parts.append(String(localized: "含云端占位：移入废纸篓可能触发下载或占用额外空间"))
        }
        return parts.joined(separator: String(localized: " · "))
    }
}
