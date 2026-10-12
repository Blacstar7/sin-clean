import AppKit
import SwiftUI

// SC-PD1 存储去向诊断面板（只读派生层）。
// 承载位置：空间分析页内、结果区之下的同级面板（SC-3.5 同级先例）；只消费同一轮
// SpaceAnalysisResultsViewModel.outcome，不新增扫描、持久化、网络或执行入口。
struct SpaceAnalysisDiagnosisView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var results: SpaceAnalysisResultsViewModel

    @State private var showsDetail = false

    var body: some View {
        let report = SpaceAnalysisDiagnosisEngine.diagnose(outcome: results.outcome)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header(report)
            primarySection(report)
            if showsDetail {
                detailSection(report)
            }
            nextStepControl(report)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceStyle, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    // MARK: - 标题与状态行（默认区只保留结论所需信息）

    private func header(_ report: SpaceAnalysisDiagnosisReport) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("存储去向诊断")
                    .font(.headline)
                Text(report.state.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppTheme.accent.opacity(0.14), in: Capsule())
                Spacer(minLength: AppTheme.Spacing.sm)
            }
            Text(metaLine(report))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("存储去向诊断")
        .accessibilityValue("\(report.state.title)，\(metaLine(report))")
    }

    private func metaLine(_ report: SpaceAnalysisDiagnosisReport) -> String {
        var parts: [String] = []
        if report.scannedScopeCount > 0 {
            parts.append(String(localized: "本轮已扫描 \(report.scannedScopeCount.formatted()) 个范围"))
        }
        if let started = report.startedAt, let finished = report.finishedAt {
            parts.append(String(localized: "统计时间 \(Self.dateFormatter.string(from: started)) 至 \(Self.dateFormatter.string(from: finished))"))
        }
        parts.append(String(localized: "结论只覆盖本次已检查范围"))
        return parts.joined(separator: " · ")
    }

    // MARK: - 主区（按状态机分派，数字只在呈现态出现）

    @ViewBuilder
    private func primarySection(_ report: SpaceAnalysisDiagnosisReport) -> some View {
        switch report.state {
        case .noData:
            guidanceState(
                title: String(localized: "尚无诊断"),
                body: String(localized: "存储去向诊断基于空间分析的同一轮扫描结果。先在上方选择范围并完成一次扫描，诊断只读取结果，不会再次扫描。")
            )
        case .emptyResult:
            guidanceState(
                title: String(localized: "本轮未统计到容量"),
                body: String(localized: "本次扫描没有统计到任何字节总量，因此无法给出占用来源结论。可以检查所选范围后重新扫描。")
            )
        case .inconsistent(let reason):
            guidanceState(
                title: String(localized: "诊断数据不一致"),
                body: inconsistentText(reason)
            )
        case .cancelled, .partial, .complete:
            numberSection(report)
        }
    }

    private func inconsistentText(_ reason: SpaceAnalysisDiagnosisInconsistencyReason) -> String {
        switch reason {
        case .conservation:
            String(localized: "各类别合计与扫描统计总量不一致，为避免误导，本轮不显示分类数字。可以重新扫描后再看诊断。")
        case .overflow:
            String(localized: "分类累加超出可表达范围，为避免误导，本轮不显示分类数字。")
        case .negative:
            String(localized: "扫描结果中出现了负的字节数，为避免误导，本轮不显示分类数字。")
        }
    }

    private func guidanceState(title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "chart.pie")
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

    private func numberSection(_ report: SpaceAnalysisDiagnosisReport) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(report.hasProminentSource
                 ? String(localized: "本次已检查容量的主要去向（前 \(report.topCategories.count.formatted()) 项）")
                 : String(localized: "在本次已检查范围内未发现突出来源（仍列出占比最高的 \(report.topCategories.count.formatted()) 项）"))
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(report.hasProminentSource ? "主要占用来源" : "无突出来源结论")
                .accessibilityValue(report.hasProminentSource
                    ? String(localized: "本次已检查容量的主要去向，前 \(report.topCategories.count.formatted()) 项")
                    : String(localized: "在本次已检查范围内未发现突出来源，仍列出占比最高的 \(report.topCategories.count.formatted()) 项"))

            VStack(spacing: AppTheme.Spacing.xs) {
                ForEach(report.topCategories) { category in
                    topRow(category, denominator: report.denominatorBytes)
                }
            }

            Text("已统计 \(SpaceAnalysisByteText.bytes(report.denominatorBytes)) · \(report.state.isCompleteSemantics ? String(localized: "本轮范围已完整读取") : coverageText(report))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("统计范围与覆盖")
                .accessibilityValue("已统计 \(SpaceAnalysisByteText.bytes(report.denominatorBytes))，\(report.state.isCompleteSemantics ? String(localized: "本轮范围已完整读取") : coverageText(report))")
        }
    }

    /// 覆盖提醒：不完整语义下必须可见（部分／取消）。
    private func coverageText(_ report: SpaceAnalysisDiagnosisReport) -> String {
        var parts: [String] = []
        if report.cancelled {
            parts.append(String(localized: "本次扫描已取消，以下为已扫描部分的诊断"))
        }
        if report.unreadableDirectoryCount > 0 {
            parts.append(String(localized: "\(report.unreadableDirectoryCount.formatted()) 个目录因权限或访问限制未统计"))
        }
        parts.append(String(localized: "结论只覆盖已读取部分"))
        return parts.joined(separator: String(localized: "；"))
    }

    private func topRow(
        _ category: SpaceAnalysisDiagnosisCategory,
        denominator: Int64
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(AppTheme.accent.opacity(0.8))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(category.categoryID.displayName)
                .font(.callout)
            Spacer(minLength: AppTheme.Spacing.sm)
            Text(SpaceAnalysisByteText.bytes(category.bytes))
                .font(.callout.monospacedDigit())
            Text(Self.percentageText(category.fraction(of: denominator)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("占用来源 \(category.categoryID.displayName)")
        .accessibilityValue(
            "\(SpaceAnalysisByteText.bytes(category.bytes))，占已统计容量 \(Self.percentageText(category.fraction(of: denominator)))，\(category.entryCount.formatted()) 项"
        )
    }

    // MARK: - 唯一下一步（默认区只有一个动作）

    private func nextStepControl(_ report: SpaceAnalysisDiagnosisReport) -> some View {
        Button {
            showsDetail.toggle()
        } label: {
            Label(
                showsDetail ? "收起诊断明细与证据" : "展开诊断明细与证据",
                systemImage: showsDetail ? "chevron.up.circle" : "chevron.down.circle"
            )
        }
        .buttonStyle(.bordered)
        .disabled(!report.presentsNumbers)
        .accessibilityLabel(showsDetail ? "收起诊断明细与证据" : "展开诊断明细与证据")
        .accessibilityValue(report.presentsNumbers ? "当前可展开" : "当前没有可展开的诊断数字")
        .accessibilityHint("只改变展示，不重新扫描，不选择任何项目")
    }

    // MARK: - 展开区（规则解释、证据样本、限制与建议）

    private func detailSection(_ report: SpaceAnalysisDiagnosisReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ForEach(SpaceAnalysisDiagnosisEngine.detailOrder(report.categories)) { category in
                    categoryCard(category, denominator: report.denominatorBytes)
                }
                precisionCard(report)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // SC-Rework-UI-Visual R1（P1 审计）：补 minHeight——面板 slot 被 RootView maxHeight 460 封顶，
        // 展开后固定内容＋明细理想高≈900pt，无 minHeight 的本 ScrollView 是唯一可压缩子视图会被压至 0（OBS-003 机制面板内复发）。
        .frame(minHeight: 140, maxHeight: 420)
        .accessibilityElement(children: .contain)
    }

    private func categoryCard(
        _ category: SpaceAnalysisDiagnosisCategory,
        denominator: Int64
    ) -> some View {
        InformationDisclosure(
            title: "\(category.categoryID.displayName) · \(SpaceAnalysisByteText.bytes(category.bytes))",
            summary: String(localized: "占已统计容量 \(Self.percentageText(category.fraction(of: denominator))) · \(category.entryCount.formatted()) 项 · \(category.categoryID.actionLevel.localizedTitle)"),
            symbol: "doc.questionmark",
            tint: AppTheme.accent
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("为什么归入该类别：\(category.explanationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(category.categoryID.displayName)归类原因")
                    .accessibilityValue(category.explanationText)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(category.samplePaths, id: \.self) { path in
                        sampleRow(path)
                    }
                }

                Text("建议动作（\(category.categoryID.actionLevel.localizedTitle)）：\(category.categoryID.actionAdvice)")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(category.categoryID.displayName)建议动作")
                    .accessibilityValue("\(category.categoryID.actionLevel.localizedTitle)：\(category.categoryID.actionAdvice)")

                Text("该容量为本轮已扫描条目的分配大小统计；样本路径仅来自当前内存中的本轮结果，不保存。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 样本路径：仅当前内存中的本轮结果；Finder 定位只在路径存在时提供（不说假话）。
    private func sampleRow(_ path: String) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        return HStack(spacing: AppTheme.Spacing.xs) {
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.xs)
            if exists {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("在访达中显示样本 \(path)")
                .accessibilityHint("只读定位，不移动、不删除、不修改任何文件")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("样本路径")
        .accessibilityValue(path + (exists ? String(localized: "，可在访达中显示") : ""))
    }

    private func precisionCard(_ report: SpaceAnalysisDiagnosisReport) -> some View {
        InformationDisclosure(
            title: String(localized: "统计口径与限制"),
            summary: String(localized: "查看范围、精度、硬链接与云端占位说明"),
            symbol: "ruler",
            tint: AppTheme.accent
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("统计范围：本轮已扫描的所选范围；类别合计等于本轮已统计容量 \(SpaceAnalysisByteText.bytes(report.denominatorBytes))。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("容量精度：\(report.precisionNote)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("诊断容量精度说明")
                    .accessibilityValue(report.precisionNote)
                if let hardLinkNote = report.hardLinkNote {
                    Text(hardLinkNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("硬链接去重说明")
                        .accessibilityValue(hardLinkNote)
                }
                if let datalessNote = report.datalessNote {
                    Text(datalessNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("云端占位说明")
                        .accessibilityValue(datalessNote)
                }
                if report.unreadableDirectoryCount > 0 {
                    Text("覆盖限制：\(report.unreadableDirectoryCount.formatted()) 个目录因权限或访问限制未统计，未统计部分不在任何类别中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("以上为存储去向的归类说明；其中部分来源可能计入 macOS 显示的「系统数据」，此处不与系统设置的数字对账。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 共用样式

    private var surfaceStyle: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(AppTheme.obsidian)
            : AnyShapeStyle(.ultraThinMaterial)
    }

    /// 占比文案：复用既有 <0.1% 规则；分母为 0 时不进入本视图路径。
    static func percentageText(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0%" }
        let value = fraction * 100
        return value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
