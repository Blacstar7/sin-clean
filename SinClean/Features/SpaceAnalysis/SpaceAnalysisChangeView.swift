import SwiftUI

// SC-PD2 空间变化追踪面板（同级第二面板，冻结 §10.1）。
// 位于存储去向诊断面板之下、手动处理面之上；只读消费同一轮
// SpaceAnalysisResultsViewModel.outcome（经 PD1 引擎派生）＋本地历史存储＋设置开关；
// 唯一事件入口＝扫描完成（onReceive）；开关状态变更不触发扫描、不触发 I/O。
struct SpaceAnalysisChangeView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var results: SpaceAnalysisResultsViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: SpaceChangeHistoryStore

    @State private var showsDetail = false
    /// 事件驱动缓存的当前诊断报告：在 onReceive（扫描完成事件）计算一次，
    /// 渲染与存储复用，避免 body 每次求值重复支付 O(entries) 派生成本。
    @State private var currentReport: SpaceAnalysisDiagnosisReport?

    var body: some View {
        let evaluation = SpaceChangeComparisonEngine.evaluate(
            outcome: results.outcome,
            report: currentReport,
            recordingEnabled: settings.spaceChangeRecordingEnabled,
            storeCondition: history.condition,
            lastFailedStamp: history.lastFailedStamp,
            snapshots: history.snapshots,
            saltHex: history.evaluationSaltHex
        )
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header(evaluation)
            primarySection(evaluation)
            if showsDetail {
                detailSection(evaluation)
            }
            nextStepControl(evaluation)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .onReceive(results.$outcome) { outcome in
            guard let outcome else {
                currentReport = nil
                return
            }
            currentReport = SpaceAnalysisDiagnosisEngine.diagnose(outcome: outcome)
            history.handleScanCompleted(
                outcome: outcome,
                report: currentReport,
                recordingEnabled: settings.spaceChangeRecordingEnabled
            )
        }
    }

    // MARK: - 标题与状态（默认区只保留结论所需信息）

    private func header(_ evaluation: SpaceChangeEvaluation) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("空间变化")
                    .font(.headline)
                Text(evaluation.state.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppTheme.accent.opacity(0.14), in: Capsule())
                Spacer(minLength: AppTheme.Spacing.sm)
            }
            Text(metaLine(evaluation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("空间变化")
        .accessibilityValue(String(localized: "\(evaluation.state.title)，\(metaLine(evaluation))"))
    }

    private func metaLine(_ evaluation: SpaceChangeEvaluation) -> String {
        var parts: [String] = []
        if evaluation.presentsNumbers {
            parts.append(String(localized: "与上次可比扫描相比"))
        }
        parts.append(String(localized: "已保留 \(evaluation.snapshotCount.formatted()) 条记录"))
        if let baseline = evaluation.baselineCreatedAt {
            parts.append(String(localized: "对比基准 \(Self.dateFormatter.string(from: baseline))"))
        }
        parts.append(String(localized: "只保存类别统计与匿名范围标识"))
        return parts.joined(separator: String(localized: " · "))
    }

    // MARK: - 主区（按七态分派，数字只在可比三态出现）

    @ViewBuilder
    private func primarySection(_ evaluation: SpaceChangeEvaluation) -> some View {
        switch evaluation.state {
        case .first:
            guidanceState(
                title: String(localized: "尚无与本次可比的历史记录"),
                body: String(localized: "本次范围组合的第一次成功扫描将作为起点记录；完成下一次同范围扫描后，这里会显示各类别的增减。")
            )
        case .notComparable(let reason):
            guidanceState(
                title: String(localized: "暂不可比较"),
                body: reason.explanation
            )
        case .recordingDisabled(let retainedCount):
            guidanceState(
                title: String(localized: "记录已关闭"),
                body: String(localized: "空间变化记录已关闭：本次及后续扫描不再写入，已保留的 \(retainedCount.formatted()) 条记录不会被删除。重新开启后，从下一次成功扫描开始恢复记录与比较。")
            )
        case .damaged(let kind):
            guidanceState(
                title: String(localized: "记录异常"),
                body: kind.explanation
            )
        case .growth, .shrink, .noChange:
            numberSection(evaluation)
        }
    }

    private func guidanceState(title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(body)
    }

    private func numberSection(_ evaluation: SpaceChangeEvaluation) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            totalRow(evaluation)

            if !evaluation.growthTop.isEmpty {
                deltaRows(title: String(localized: "增长最多的类别"), entries: evaluation.growthTop)
            }
            if !evaluation.shrinkTop.isEmpty {
                deltaRows(title: String(localized: "缩小最多的类别"), entries: evaluation.shrinkTop)
            }
            if evaluation.growthTop.isEmpty && evaluation.shrinkTop.isEmpty {
                Text("各类别统计与上次可比扫描持平，未发现增长或缩小的类别。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("类别持平说明")
                    .accessibilityValue("各类别统计与上次可比扫描持平，未发现增长或缩小的类别")
            }

            comparisonTimeRow(evaluation)
        }
    }

    private func totalRow(_ evaluation: SpaceChangeEvaluation) -> some View {
        let totalText: String
        if let totalDelta = evaluation.totalDelta {
            totalText = totalDelta > 0
                ? String(localized: "总量增加 \(SpaceAnalysisByteText.bytes(totalDelta))")
                : (totalDelta < 0 ? String(localized: "总量减少 \(SpaceAnalysisByteText.bytes(-totalDelta))") : String(localized: "总量持平"))
        } else {
            totalText = String(localized: "总量持平")
        }
        return Text(totalText)
            .font(.callout.weight(.semibold))
            .accessibilityLabel("总量变化")
            .accessibilityValue(totalText)
    }

    private func deltaRows(title: String, entries: [SpaceChangeCategoryDelta]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(entries) { entry in
                deltaRow(entry)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func deltaRow(_ entry: SpaceChangeCategoryDelta) -> some View {
        let deltaText = entry.delta > 0
            ? "+\(SpaceAnalysisByteText.bytes(entry.delta))"
            : "−\(SpaceAnalysisByteText.bytes(-entry.delta))"
        return HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(AppTheme.accent.opacity(0.8))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(entry.categoryID.displayName)
                .font(.callout)
            Spacer(minLength: AppTheme.Spacing.sm)
            Text(deltaText)
                .font(.callout.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "类别变化 \(entry.categoryID.displayName)"))
        .accessibilityValue(
            String(localized: "\(deltaText)，从 \(SpaceAnalysisByteText.bytes(entry.baselineBytes)) 到 \(SpaceAnalysisByteText.bytes(entry.currentBytes))")
        )
    }

    private func comparisonTimeRow(_ evaluation: SpaceChangeEvaluation) -> some View {
        var parts: [String] = []
        if let current = evaluation.currentFinishedAt {
            parts.append(String(localized: "本次 \(Self.dateFormatter.string(from: current))"))
        }
        if let baseline = evaluation.baselineCreatedAt {
            parts.append(String(localized: "对比基准 \(Self.dateFormatter.string(from: baseline))"))
        }
        parts.append(String(localized: "口径：已扫描类别的分配大小统计"))
        return Text(parts.joined(separator: String(localized: " · ")))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("对比时间与口径")
            .accessibilityValue(parts.joined(separator: String(localized: "，")))
    }

    // MARK: - 唯一下一步（默认区只有一个动作）

    private func nextStepControl(_ evaluation: SpaceChangeEvaluation) -> some View {
        Button {
            showsDetail.toggle()
        } label: {
            Label(
                showsDetail ? "收起对比依据与限制" : "展开对比依据与限制",
                systemImage: showsDetail ? "chevron.up.circle" : "chevron.down.circle"
            )
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(showsDetail ? "收起对比依据与限制" : "展开对比依据与限制")
        .accessibilityValue(evaluation.snapshotCount.formatted() + String(localized: " 条本地记录"))
        .accessibilityHint("只查看说明，不重新扫描，不选择任何项目")
    }

    // MARK: - 展开区（可比条件、保留规则、存储与隐私、精度与归因边界）

    private func detailSection(_ evaluation: SpaceChangeEvaluation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                conditionsCard(evaluation)
                retentionCard(evaluation)
                privacyCard()
                precisionCard(evaluation)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // SC-Rework-UI-Visual R1（P1 审计）：补 minHeight——与诊断面板同型（OBS-003 机制面板内复发，展开区不可被压至 0）。
        .frame(minHeight: 140, maxHeight: 420)
        .accessibilityElement(children: .contain)
    }

    private func conditionsCard(_ evaluation: SpaceChangeEvaluation) -> some View {
        InformationDisclosure(
            title: String(localized: "可比条件"),
            summary: String(localized: "两次扫描如何判定为可以公平比较"),
            symbol: "checkmark.seal",
            tint: AppTheme.accent
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("只有同时满足以下条件才显示变化：两次扫描均正常完成且未取消；匿名范围标识一致（范围集合相同，顺序无关）；分类规则版本一致；容量统计口径一致；覆盖状态一致（双方都完整读取）；无整数溢出、负值或损坏记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("任一条件不满足时显示「暂不可比较」及具体原因，不输出增减数字；本版本不计算部分范围的共同可比子集。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func retentionCard(_ evaluation: SpaceChangeEvaluation) -> some View {
        InformationDisclosure(
            title: String(localized: "记录保留规则"),
            summary: String(localized: "当前已保留 \(evaluation.snapshotCount.formatted()) 条"),
            symbol: "archivebox",
            tint: AppTheme.accent
        ) {
            Text("本地最多保留最近 30 条成功扫描记录，且不超过 90 天；超出时在下次成功记录时按最旧优先确定性淘汰。关闭记录只停止新增、不删除既有记录；可在设置的「空间变化记录」中一次性清除。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("记录保留规则")
                .accessibilityValue("最多保留最近 30 条且不超过 90 天，当前 \(evaluation.snapshotCount.formatted()) 条")
        }
    }

    private func privacyCard() -> some View {
        InformationDisclosure(
            title: String(localized: "存储与隐私"),
            summary: String(localized: "记录保存在本机应用目录"),
            symbol: "lock.shield",
            tint: AppTheme.accent
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("变化记录只保存在本机应用自身的 Application Support 目录，包含：加盐后的匿名范围标识、七个类别各自的容量与条目数、扫描完成时间、覆盖与精度标志、记录格式与规则版本号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("不保存任何路径、文件名、目录名、应用名或文件清单；不联网、不上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("隐私边界")
                    .accessibilityValue("不保存任何路径、文件名、目录名、应用名或文件清单；不联网、不上传")
            }
        }
    }

    private func precisionCard(_ evaluation: SpaceChangeEvaluation) -> some View {
        InformationDisclosure(
            title: String(localized: "精度与归因边界"),
            summary: String(localized: "分配大小口径；变化不推断原因"),
            symbol: "ruler",
            tint: AppTheme.accent
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("变化数字为已扫描条目的分配大小统计差（硬链接去重后）；\(evaluation.capacityIsUpperBound ? "若存在 APFS 克隆，实际占用可能更小（macOS 未提供克隆查询接口），类别数字为上界口径" : "本轮未检出需要上界措辞的条目")。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if evaluation.datalessPlaceholderCount > 0 {
                    Text("本次有 \(evaluation.datalessPlaceholderCount.formatted()) 个云端占位条目按当前占用计入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("变化只说明已扫描类别统计的增加或减少，不能据此推断是某个应用产生、您做了什么操作，也不能归功于 Sin Clean 的清理；清理收据的成功容量、磁盘可用空间变化与这里的类别统计是三套独立数字，互不对账。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("归因边界")
                    .accessibilityValue("变化不推断具体应用、用户行为或 Sin Clean 功劳，与清理收据和磁盘可用空间互不对账")
            }
        }
    }

    // MARK: - 共用样式

    private var surfaceStyle: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(AppTheme.obsidian)
            : AnyShapeStyle(.ultraThinMaterial)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
