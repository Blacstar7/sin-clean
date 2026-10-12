import SwiftUI

// SC-PD3 占用全景面板与卸载后复查面板（冻结语义 work/SC-PD3-frozen-semantics.md §1、§2、§4、§8）。
// 只读展示层：不产生执行项、不改写收据；证据细节位于既有各节。

// MARK: - 占用全景面板

private extension AppFootprintTier {
    var rowTitle: String {
        switch self {
        case .applicationBundle: String(localized: "应用本体")
        case .userResidue: String(localized: "可归属用户级残留")
        case .readOnlyAssociation: String(localized: "只读关联项目")
        case .unattributableScope: String(localized: "未能读取或无法安全归属")
        }
    }

    var showsCountOnly: Bool {
        self == .readOnlyAssociation || self == .unattributableScope
    }
}

struct AppFootprintPanel: View {
    let report: AppFootprintReport?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Text("占用全景")
                    .font(.headline)
                    .accessibilityLabel("占用全景")
                Spacer()
                completenessBadge
            }

            if let report {
                completenessConclusion(for: report)
                if showTiers(report) {
                    tierRows(report)
                    totalRow(report)
                }
                if !report.dedupExclusions.isEmpty {
                    dedupNote(report)
                }
                scopeDisclosure(report)
            } else {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在汇总应用占用全景…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("占用全景正在汇总")
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.recessedSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
    }

    // MARK: 完整度胶囊（四态四句独立文案，冻结 §2.3）

    @ViewBuilder
    private var completenessBadge: some View {
        let (text, tint): (String, Color) = {
            guard let report else { return (String(localized: "正在汇总"), Color.secondary) }
            switch report.completeness {
            case .complete: return (String(localized: "完整检查"), AppTheme.healthy)
            case .partial: return (String(localized: "部分检查"), AppTheme.warning)
            case .cannotJudge: return (String(localized: "无法安全判断"), AppTheme.danger)
            case .notChecked: return (String(localized: "未检查"), Color.secondary)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(tint.opacity(0.12))
            .foregroundStyle(tint)
            .clipShape(Capsule())
            .accessibilityLabel("检查完整度")
            .accessibilityValue(text)
    }

    private func completenessConclusion(for report: AppFootprintReport) -> some View {
        Label(Self.conclusionText(report.completeness), systemImage: "circle.grid.2x2")
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }

    private static func conclusionText(_ completeness: AppFootprintCompleteness) -> String {
        switch completeness {
        case .complete:
            return String(localized: "已完整核对本版本声明的扫描范围。")
        case .partial(let gaps):
            return String(localized: "部分检查：\(gaps.count.formatted()) 个范围未能完整核对，容量为其可靠部分。")
        case .cannotJudge(let reason):
            return cannotJudgeText(reason) + String(localized: "请重新扫描应用后再查看占用全景。")
        case .notChecked(let reason):
            switch reason {
            case .associationAnalysisDisabled:
                return String(localized: "关联分析已关闭，关联范围未检查。")
            case .awaitingReports:
                return String(localized: "正在检查，占用全景尚未完成。")
            }
        }
    }

    private static func cannotJudgeText(_ reason: AppFootprintCannotJudgeReason) -> String {
        switch reason {
        case .missingBundleIdentifier:
            return String(localized: "应用没有可安全使用的 Bundle Identifier，无法安全判断。")
        case .invalidBundleIdentifier:
            return String(localized: "应用的 Bundle Identifier 不符合安全规则，无法安全判断。")
        case .applicationIdentityChanged(let detail):
            let detailText: String
            switch detail {
            case .pathMissing: detailText = String(localized: "应用路径已不存在")
            case .notADirectory: detailText = String(localized: "应用路径已不是应用目录")
            case .deviceIDDiffer: detailText = String(localized: "设备号与选择时不一致")
            case .inodeDiffer: detailText = String(localized: "inode 与选择时不一致")
            case .logicalBytesDiffer: detailText = String(localized: "逻辑大小与选择时不一致")
            case .modifiedSecondsDiffer, .modifiedNanosecondsDiffer: detailText = String(localized: "修改时间与选择时不一致")
            case .bundleIdentifierRereadMismatch: detailText = String(localized: "Bundle Identifier 复读不一致")
            }
            return String(localized: "应用身份已变化（\(detailText)），无法安全判断。")
        case .scanResultDamaged(let detail):
            return String(localized: "扫描结果损坏：\(detail)")
        }
    }

    // MARK: 四层行（无法安全判断时不显示任何容量数字，冻结 §2.3）

    private func showTiers(_ report: AppFootprintReport) -> Bool {
        if case .cannotJudge = report.completeness { return false }
        return true
    }

    @ViewBuilder
    private func tierRows(_ report: AppFootprintReport) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            tierRow(
                tier: .applicationBundle,
                value: report.applicationBytes.map { SystemFormatters.bytes.string(fromByteCount: $0) },
                countText: nil,
                symbol: "shippingbox"
            )
            tierRow(
                tier: .userResidue,
                value: report.residueBytes.map { SystemFormatters.bytes.string(fromByteCount: $0) },
                countText: String(localized: "\(report.residueEntries.count.formatted()) 项"),
                symbol: "folder.badge.gearshape"
            )
            tierRow(
                tier: .readOnlyAssociation,
                value: nil,
                countText: readOnlyAssociationSummary(report),
                symbol: "eye"
            )
            tierRow(
                tier: .unattributableScope,
                value: nil,
                countText: unattributableSummary(report),
                symbol: "questionmark.square.dashed"
            )
        }
    }

    private func readOnlyAssociationSummary(_ report: AppFootprintReport) -> String {
        let outside = report.associationEntries.filter { !$0.isInsideApplicationBundle }.count
        let inside = report.associationEntries.filter { $0.isInsideApplicationBundle }.count
        if case .notChecked(reason: .associationAnalysisDisabled) = report.completeness {
            return String(localized: "关联分析已关闭，未检查")
        }
        var parts = [String(localized: "\(outside.formatted()) 项外部项目（只读，不进入卸载清单）")]
        if inside > 0 {
            parts.append(String(localized: "\(inside.formatted()) 项位于应用包内，随本体移动"))
        }
        return parts.joined(separator: String(localized: "；"))
    }

    private func unattributableSummary(_ report: AppFootprintReport) -> String {
        var parts: [String] = []
        if !report.coverageGaps.isEmpty {
            parts.append(String(localized: "\(report.coverageGaps.count.formatted()) 个范围未能完整核对"))
        }
        if report.ignoredResidueCount > 0 {
            parts.append(String(localized: "\(report.ignoredResidueCount.formatted()) 项残留被忽略规则排除"))
        }
        return parts.isEmpty ? String(localized: "本轮未发现") : parts.joined(separator: String(localized: "；"))
    }

    private func tierRow(tier: AppFootprintTier, value: String?, countText: String?, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(Color.indigo)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tier.rowTitle).font(.callout.weight(.semibold))
                if let countText {
                    Text(countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let value {
                Text(value)
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tier.rowTitle)
        .accessibilityValue(Self.tierAccessibilityValue(tier: tier, value: value, countText: countText))
    }

    private static func tierAccessibilityValue(tier: AppFootprintTier, value: String?, countText: String?) -> String {
        if tier.showsCountOnly { return countText ?? String(localized: "未显示容量") }
        return [value, countText].compactMap { $0 }.joined(separator: String(localized: "，"))
    }

    // MARK: 合计行（只相加第 1、2 类；去重与溢出防御，冻结 §1.1／§1.3）

    @ViewBuilder
    private func totalRow(_ report: AppFootprintReport) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("已知占用合计（应用本体＋可归属残留，已去重）")
                .font(.callout.weight(.semibold))
            Spacer()
            if report.sumOverflowDetected, report.knownTotalBytes == nil {
                Text("合计校验失败")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.warning)
            } else if let total = report.knownTotalBytes {
                Text(SystemFormatters.bytes.string(fromByteCount: total))
                    .font(.headline.monospacedDigit())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已知占用合计，应用本体与可归属残留相加并已去重")
        .accessibilityValue(
            report.knownTotalBytes.map { SystemFormatters.bytes.string(fromByteCount: $0) } ?? String(localized: "合计校验失败")
        )
    }

    private func dedupNote(_ report: AppFootprintReport) -> some View {
        Text("合计已确定性去重：排除 \(report.dedupExclusions.count.formatted()) 项（重复路径、同一文件身份或父子路径）；详见「依据与限制」。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }

    // MARK: 展开区：范围声明与限制（冻结 §2.1／§1.3.4／§8.4）

    private func scopeDisclosure(_ report: AppFootprintReport) -> some View {
        DisclosureGroup("依据与限制") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("本版本声明的扫描范围：本轮应用发现范围、九条精确 Bundle Identifier 残留路径、只读关联六类位置（关联分析开启时）。完整检查仅指上述范围的核对完整，不代表整台 Mac 上绝无其他文件。")
                if !report.dedupExclusions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("去重排除明细：")
                            .font(.caption.weight(.semibold))
                        ForEach(Array(report.dedupExclusions.enumerated()), id: \.offset) { _, exclusion in
                            Text("\(exclusion.excludedPath)（\(exclusion.cause.dedupText)，保留 \(exclusion.keptPath)）")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                if !report.coverageGaps.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未能完整核对的范围样本：")
                            .font(.caption.weight(.semibold))
                        ForEach(Array(report.coverageGaps.enumerated()), id: \.offset) { _, gap in
                            Text("\(gap.rootPath)（\(gap.kind.displayText)）")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text("各项目容量沿既有分配大小口径；跨目录逐文件硬链接不在本版去重能力内，未检出时不作额外扣减。只读关联项目只显示数量与证据，不显示容量。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, AppTheme.Spacing.sm)
        }
        .font(.callout.weight(.semibold))
    }
}

extension AppFootprintCoverageGap.Kind {
    var displayText: String {
        switch self {
        case .inaccessibleScope: return String(localized: "不可读")
        case .partialScope: return String(localized: "部分核对")
        case .skippedScope: return String(localized: "被跳过")
        case .cancelledScope: return String(localized: "已取消")
        case .completenessIssue: return String(localized: "存在影响完整性的问题")
        case .policySkip: return String(localized: "策略跳过")
        }
    }
}

extension AppFootprintDedupExclusion.Cause {
    var dedupText: String {
        switch self {
        case .duplicatePath: return String(localized: "重复路径")
        case .duplicateFileIdentity: return String(localized: "同一文件身份")
        case .nestedPath: return String(localized: "父子路径")
        }
    }
}

// MARK: - 卸载后复查面板（与执行收据并列展示；冻结 §4、§7）

struct UninstallRecheckPanel: View {
    let canRunRecheck: Bool
    let isRunning: Bool
    let report: UninstallRecheckReport?
    let receiptMovedBytes: Int64?
    let runAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Text("卸载后复查")
                    .font(.headline)
                    .accessibilityLabel("卸载后复查")
                Spacer()
                Text("只读")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            if isRunning {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("正在以卸载时的应用身份重新核对精确路径与只读关联…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("复查正在进行")
            } else if let report {
                recheckResult(report)
            } else if canRunRecheck {
                Text("应用本体已移入废纸篓。可以按卸载时冻结的应用身份重新核对九条精确路径与只读关联位置；复查只读，不会移动任何文件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                Button("复查已扫描范围", systemImage: "magnifyingglass.circle", action: runAction)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("只读复查；不自动勾选、不进入新的执行计划")
                    .accessibilityLabel("复查已扫描范围")
                    .accessibilityHint("以原卸载身份只读核对；不会自动勾选或执行任何操作")
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.recessedSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
    }

    @ViewBuilder
    private func recheckResult(_ report: UninstallRecheckReport) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("复查对象：\(report.anchor.applicationName)（\(report.anchor.bundleIdentifier)）；复查于 \(report.ranAt.formatted(date: .abbreviated, time: .shortened))。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)

            ForEach(Array(report.categories.enumerated()), id: \.offset) { _, category in
                categoryRow(category, report: report)
            }

            if let foundBytes = report.foundResidueBytes, foundBytes > 0 {
                Text("复查发现项目合计 \(SystemFormatters.bytes.string(fromByteCount: foundBytes))。该数字与本次卸载已移入废纸篓的\(receiptMovedBytes.map { " \(SystemFormatters.bytes.string(fromByteCount: $0)) " } ?? "容量")是两套独立数字，互不对账。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
            }

            Text("复查发现的项目不会自动勾选、不会进入新的执行计划；可在重新扫描后自行审阅勾选，或在 Finder 中查看。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: UninstallRecheckCategory, report: UninstallRecheckReport) -> some View {
        switch category {
        case .notFoundInCheckedScope:
            Label("在本次已检查范围内未发现残留或只读关联项目。", systemImage: "checkmark.circle")
                .foregroundStyle(AppTheme.healthy)
                .font(.callout.weight(.semibold))
                .accessibilityElement(children: .combine)
        case .foundUserResidues(let count):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Label("仍发现用户级残留 \(count.formatted()) 项：", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.warning)
                    .font(.callout.weight(.semibold))
                    .accessibilityLabel("仍发现用户级残留 \(count.formatted()) 项")
                ForEach(report.foundResidueEntries) { entry in
                    Text("\(entry.path)（\(entry.kind.localizedName)，\(SystemFormatters.bytes.string(fromByteCount: entry.allocatedBytes))）")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .foundReadOnlyAssociations(let count):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Label("仍发现只读关联 \(count.formatted()) 项：", systemImage: "eye")
                    .foregroundStyle(AppTheme.accent)
                    .font(.callout.weight(.semibold))
                    .accessibilityLabel("仍发现只读关联 \(count.formatted()) 项")
                ForEach(report.foundAssociationEntries) { entry in
                    Text("\(entry.path)（\(entry.kind.localizedName)，只读）")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("外部后台项目与安装收据不会被自动移除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
            }
        case .incomplete(let reason):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Label(reasonText(reason), systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(AppTheme.warning)
                    .font(.callout.weight(.semibold))
                    .accessibilityElement(children: .combine)
                if !report.foundResidueEntries.isEmpty || !report.foundAssociationEntries.isEmpty {
                    Text("复查已核对的部分有发现（残留 \(report.foundResidueEntries.count.formatted()) 项、只读关联 \(report.foundAssociationEntries.count.formatted()) 项，见下方清单），但主结论仍为复查不完整。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func reasonText(_ reason: UninstallRecheckIncompleteReason) -> String {
        switch reason {
        case .anchoredIdentityUnavailable:
            return String(localized: "复查不完整：原卸载身份的 Bundle Identifier 已不可用，无法安全重跑精确规则。")
        case .coverageGap(let gaps):
            return String(localized: "复查不完整：\(gaps.count.formatted()) 个范围未能核对（不可读、超时、取消或策略跳过）。")
        }
    }
}
