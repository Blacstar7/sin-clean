import Foundation

struct OperationPlanTextExport: Hashable, Sendable {
    let plan: OperationPlan
    let text: String
    let suggestedFilename: String
}

enum OperationPlanExportPreparationError: Error, Equatable, Sendable {
    case scanNotCompleted
    case executionInProgress
    case ignoreListUnavailable
    case noEligibleSelection
}

extension OperationPlanExportPreparationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .scanNotCompleted:
            return String(localized: "扫描尚未完成，不能生成计划快照。")
        case .executionInProgress:
            return String(localized: "操作正在执行，不能同时导出计划。")
        case .ignoreListUnavailable:
            return String(localized: "忽略列表当前不可用，不能确认导出范围。")
        case .noEligibleSelection:
            return String(localized: "当前没有可导出的有效选择。")
        }
    }
}

enum OperationPlanTextExportError: Error, Equatable, Sendable {
    case emptyPlan
    case invalidItemOrder(itemID: String)
    case invalidUninstallApplicationOrder
    case capacityMismatch
}

extension OperationPlanTextExportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyPlan:
            return String(localized: "空计划不能导出。")
        case .invalidItemOrder(let itemID):
            return String(localized: "计划项目顺序无效：\(itemID)")
        case .invalidUninstallApplicationOrder:
            return String(localized: "卸载计划的第一项不是应用本体。")
        case .capacityMismatch:
            return String(localized: "计划容量摘要与项目合计不一致。")
        }
    }
}

/// A pure formatter for an already-frozen operation plan. It never reads a scanner,
/// view model, selection, ignore repository, filesystem, or executor.
struct OperationPlanTextExporter: Sendable {
    func export(_ plan: OperationPlan) throws -> OperationPlanTextExport {
        try validate(plan)
        return OperationPlanTextExport(
            plan: plan,
            text: makeText(plan),
            suggestedFilename: makeFilename(plan)
        )
    }

    private func validate(_ plan: OperationPlan) throws {
        guard !plan.items.isEmpty else {
            throw OperationPlanTextExportError.emptyPlan
        }
        for (expectedOrder, item) in plan.items.enumerated() where item.order != expectedOrder {
            throw OperationPlanTextExportError.invalidItemOrder(itemID: item.id)
        }
        if plan.domain == .uninstall, plan.items.first?.category != .applicationBundle {
            throw OperationPlanTextExportError.invalidUninstallApplicationOrder
        }

        var total: Int64 = 0
        for item in plan.items {
            let (newTotal, overflow) = total.addingReportingOverflow(item.estimatedBytes)
            guard !overflow else { throw OperationPlanTextExportError.capacityMismatch }
            total = newTotal
        }
        guard total == plan.estimatedBytes else {
            throw OperationPlanTextExportError.capacityMismatch
        }
    }

    private func makeText(_ plan: OperationPlan) -> String {
        var lines: [String] = [
            String(localized: "Sin Clean 操作计划"),
            String(localized: "只读审阅文件，不构成执行授权。"),
            String(localized: "计划领域：\(domainTitle(plan.domain))"),
            "",
            String(localized: "== 计划摘要 =="),
            String(localized: "稳定计划 ID：\(plan.id.uuidString)"),
            String(localized: "创建时间：\(timestamp(plan.createdAt))"),
            String(localized: "冻结时间：\(timestamp(plan.frozenAt))"),
            String(localized: "状态：\(stateTitle(plan.state))（\(plan.state.rawValue)）"),
            String(localized: "项目数量：\(plan.itemCount)"),
            String(localized: "预计总容量：\(plan.estimatedBytes) bytes"),
            "",
            String(localized: "== 扫描来源 ==")
        ]

        if plan.sourceScanContexts.isEmpty {
            lines.append(String(localized: "无扫描上下文快照"))
        } else {
            for (index, context) in plan.sourceScanContexts.enumerated() {
                lines.append(contentsOf: [
                    String(localized: "[扫描上下文 \(index + 1)]"),
                    String(localized: "扫描上下文 ID：\(context.id.uuidString)"),
                    String(localized: "扫描时间：\(timestamp(context.startedAt))"),
                    String(localized: "规则版本：\(field(context.ruleVersion))")
                ])
            }
        }

        lines.append(contentsOf: [
            "",
            "== Coverage ==",
            String(localized: "范围数量：\(plan.coverageSummary.records.count)"),
            String(localized: "问题总数：\(plan.coverageSummary.issueCount)"),
            String(localized: "权限问题数：\(plan.coverageSummary.accessIssueCount)"),
            String(localized: "保留样本数：\(plan.coverageSummary.retainedIssueSampleCount)"),
            String(localized: "省略数量：\(plan.coverageSummary.omittedIssueCount)")
        ])

        if plan.coverageSummary.records.isEmpty {
            lines.append(String(localized: "警告：计划没有 Coverage 记录，不能据此断言扫描范围完整或结果为零。"))
        } else {
            for (index, coverage) in plan.coverageSummary.records.enumerated() {
                lines.append(contentsOf: [
                    "[Coverage \(index + 1)]",
                    String(localized: "扫描上下文 ID：\(coverage.contextID.uuidString)"),
                    String(localized: "扫描时间：\(timestamp(coverage.contextStartedAt))"),
                    String(localized: "规则版本：\(field(coverage.ruleVersion))"),
                    "scopeID：\(field(coverage.scopeID))",
                    "scanner：\(scannerTitle(coverage.scanner))（\(coverage.scanner.rawValue)）",
                    "phase：\(phaseTitle(coverage.phase))（\(coverage.phase.rawValue)）",
                    String(localized: "根路径：\(field(coverage.rootPath))"),
                    String(localized: "目标路径：\(coverage.targetPath.map(field) ?? String(localized: "无"))"),
                    String(localized: "状态：\(coverageStatusTitle(coverage.status))（\(coverage.status.rawValue)）"),
                    String(localized: "问题总数：\(coverage.issueCount)"),
                    String(localized: "权限问题数：\(coverage.accessIssueCount)"),
                    String(localized: "保留样本数：\(coverage.retainedIssueSampleCount)"),
                    String(localized: "省略数量：\(coverage.omittedIssueCount)")
                ])
                if coverage.status != .completed {
                    lines.append(String(localized: "警告：此范围 Coverage 不完整或未完成，不得把不可读、跳过、取消或未扫描范围解释为零结果。"))
                }
            }
        }

        lines.append(contentsOf: ["", String(localized: "== 计划项目 ==")])
        for item in plan.items {
            lines.append(contentsOf: itemLines(item))
        }

        lines.append(contentsOf: ["", String(localized: "== 安全警告 ==")])
        for warning in plan.warnings {
            lines.append("- \(warningText(warning))")
        }
        lines.append(contentsOf: [
            String(localized: "- 这份文件只用于人工审阅，不能用于自动重放或重新执行旧计划。"),
            String(localized: "- 导出本身不会清理、卸载、忽略、扫描或移动任何项目。"),
            "",
            String(localized: "== 文档结束 ==")
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    private func itemLines(_ item: OperationPlanItem) -> [String] {
        let evidence = item.evidence
        var lines = [
            String(localized: "[项目 \(item.order + 1)]"),
            String(localized: "执行顺序：\(item.order + 1)"),
            String(localized: "稳定项目 ID：\(field(item.id))"),
            String(localized: "项目状态：\(itemStateTitle(item.state))（\(item.state.rawValue)）"),
            String(localized: "类别：\(categoryTitle(item.category))"),
            String(localized: "安全边界：\(safetyBoundaryText(item.safetyBoundary))"),
            String(localized: "完整路径：\(field(item.identity.originalPath))"),
            String(localized: "扫描根路径：\(field(item.identity.scanRootPath))"),
            String(localized: "项目类型：\(itemTypeTitle(item.identity.itemType))（\(item.identity.itemType.rawValue)）"),
            "deviceID：\(item.identity.deviceID)",
            "inode：\(item.identity.inode)",
            String(localized: "磁盘占用：\(item.identity.allocatedBytes) bytes"),
            String(localized: "逻辑大小：\(item.identity.logicalBytes) bytes"),
            String(localized: "预计处理容量：\(item.estimatedBytes) bytes"),
            String(localized: "扫描时修改时间：\(identityTimestamp(seconds: item.identity.modifiedSeconds, nanoseconds: item.identity.modifiedNanoseconds))")
        ]

        if let bundleIdentifier = item.identity.bundleIdentifier {
            lines.append("Bundle Identifier：\(field(bundleIdentifier))")
        }
        if let parent = item.parentApplication {
            lines.append(contentsOf: [
                String(localized: "父应用 ID：\(field(parent.id))"),
                String(localized: "父应用名称：\(field(parent.name))"),
                String(localized: "父应用路径：\(field(parent.path))"),
                String(localized: "父应用 Bundle Identifier：\(field(parent.bundleIdentifier))")
            ])
        }

        lines.append(contentsOf: [
            "reasonCode：\(evidence.reasonCode.rawValue)",
            "reasonText：\(field(evidence.reasonText))",
            String(localized: "实际匹配值：\(evidence.origin.matchedValue.map(field) ?? String(localized: "无"))"),
            String(localized: "规则版本：\(field(evidence.ruleVersion))"),
            String(localized: "影响级别：\(impactLevelTitle(evidence.impactLevel))（\(evidence.impactLevel.rawValue)）"),
            String(localized: "影响说明：\(field(evidence.impactText))"),
            String(localized: "恢复方式：\(recoverabilityText(evidence.recoverability))（\(evidence.recoverability.rawValue)）")
        ])
        if let restrictionReason = evidence.restrictionReason {
            lines.append(String(localized: "处理限制：\(restrictionText(restrictionReason))（\(restrictionReason.rawValue)）"))
        }
        return lines
    }

    private func makeFilename(_ plan: OperationPlan) -> String {
        let prefix = plan.domain == .cleanup ? "cleanup" : "uninstall"
        let components = utcComponents(plan.frozenAt)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            components.year,
            components.month,
            components.day,
            components.hour,
            components.minute,
            components.second
        )
        return "SinClean-\(prefix)-plan-\(stamp).txt"
    }

    private func timestamp(_ date: Date) -> String {
        let components = utcComponents(date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            components.year,
            components.month,
            components.day,
            components.hour,
            components.minute,
            components.second
        )
    }

    private func identityTimestamp(seconds: Int64, nanoseconds: Int64) -> String {
        let base = timestamp(Date(timeIntervalSince1970: TimeInterval(seconds)))
        return "\(base.dropLast()).\(String(format: "%09lld", nanoseconds))Z"
    }

    private func utcComponents(_ date: Date) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let values = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return (
            values.year ?? 0,
            values.month ?? 0,
            values.day ?? 0,
            values.hour ?? 0,
            values.minute ?? 0,
            values.second ?? 0
        )
    }

    private func field(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func domainTitle(_ domain: OperationPlanDomain) -> String {
        domain == .cleanup ? String(localized: "磁盘清理") : String(localized: "应用卸载")
    }

    private func stateTitle(_ state: OperationPlanState) -> String { String(localized: "已冻结") }
    private func itemStateTitle(_ state: OperationPlanItemState) -> String { String(localized: "待处理") }

    private func categoryTitle(_ category: OperationPlanItemCategory) -> String {
        switch category {
        case .cleanup(let locationID): return String(localized: "磁盘清理候选（locationID：\(field(locationID))）")
        case .applicationBundle: return String(localized: "应用本体")
        case .residue(let kind): return String(localized: "卸载残留（\(field(kind.localizedDisplayName))）")
        }
    }

    private func itemTypeTitle(_ type: IdentitySnapshotItemType) -> String {
        switch type {
        case .cleanupRegularFile: return String(localized: "清理普通文件")
        case .applicationBundle: return String(localized: "应用包目录")
        case .residueFile: return String(localized: "残留普通文件")
        case .residueDirectory: return String(localized: "残留目录")
        }
    }

    private func safetyBoundaryText(_ boundary: OperationPlanSafetyBoundary) -> String {
        switch boundary {
        case .cleanupRegularFileOnly:
            return String(localized: "仅允许处理扫描根路径内、身份复验通过的普通文件")
        case .applicationBundleMustSucceedFirst:
            return String(localized: "应用本体必须最先处理并成功，之后才允许处理残留")
        case .residueOnlyAfterApplicationSucceeds:
            return String(localized: "仅在父应用本体成功移入废纸篓后才允许处理")
        }
    }

    private func scannerTitle(_ scanner: ScannerKind) -> String {
        switch scanner {
        case .disk: return String(localized: "磁盘扫描")
        case .application: return String(localized: "应用扫描")
        case .residue: return String(localized: "残留扫描")
        case .association: return String(localized: "关联扫描")
        }
    }

    private func phaseTitle(_ phase: ScanPhase) -> String {
        switch phase {
        case .discover: return String(localized: "发现")
        case .measure: return String(localized: "测量")
        case .inspect: return String(localized: "检查")
        case .associate: return String(localized: "关联")
        }
    }

    private func coverageStatusTitle(_ status: CoverageStatus) -> String {
        switch status {
        case .notStarted: return String(localized: "未开始")
        case .inProgress: return String(localized: "进行中")
        case .completed: return String(localized: "已完成")
        case .partial: return String(localized: "部分完成")
        case .notSelected: return String(localized: "未选择")
        case .inaccessible: return String(localized: "无法访问")
        case .skipped: return String(localized: "已跳过")
        case .notFound: return String(localized: "未找到")
        case .cancelled: return String(localized: "已取消")
        }
    }

    private func impactLevelTitle(_ level: ImpactLevel) -> String {
        switch level {
        case .review: return String(localized: "需要复核")
        case .caution: return String(localized: "谨慎处理")
        case .readOnly: return String(localized: "只读")
        }
    }

    private func recoverabilityText(_ value: Recoverability) -> String {
        switch value {
        case .trashManual: return String(localized: "移入废纸篓后可由用户手动恢复")
        case .withApplicationBundle: return String(localized: "随应用本体一起移动和恢复")
        case .notApplicable: return String(localized: "不适用；本项不进入执行计划")
        }
    }

    private func restrictionText(_ value: RestrictionReason) -> String {
        switch value {
        case .readOnlyExternal: return String(localized: "外部关联只读，不单独处理")
        case .movesWithApplication: return String(localized: "位于应用包内，只随应用本体移动")
        case .missingBundleIdentifier: return String(localized: "缺少 Bundle Identifier")
        case .invalidBundleIdentifier: return String(localized: "Bundle Identifier 无效")
        case .symbolicLink: return String(localized: "符号链接已拒绝")
        case .unsupportedType: return String(localized: "文件类型不受支持")
        case .packageBoundary: return String(localized: "应用包边界停止下探")
        case .depthLimit: return String(localized: "达到扫描深度上限")
        case .sizeLimit: return String(localized: "达到读取大小上限")
        case .notSelected: return String(localized: "扫描范围未选择")
        }
    }

    private func warningText(_ warning: OperationPlanWarning) -> String {
        switch warning {
        case .trashOnly:
            return String(localized: "所有获准项目只允许移入废纸篓，不允许永久删除。")
        case .executionIdentityRevalidationRequired:
            return String(localized: "执行前仍须复验路径、符号链接、文件类型、deviceID、inode、容量、修改时间及适用的 Bundle Identifier。")
        case .applicationFailureBlocksAllResidues:
            return String(localized: "应用本体失败时，全部残留必须保持不动。")
        case .readOnlyAssociationsExcluded:
            return String(localized: "外部后台关联和安装收据不进入执行计划；APP 包内关联不作为独立项目。")
        }
    }
}
