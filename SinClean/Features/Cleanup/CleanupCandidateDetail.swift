import AppKit
import Darwin
import Foundation
@preconcurrency import QuickLookUI

struct CleanupCandidateDetail: Sendable {
    let candidate: CleanupFileCandidate
    let evidence: CandidateEvidence
    let coverage: ScanCoverage?

    init(candidate: CleanupFileCandidate, coverageRecords: [ScanCoverage]) {
        self.candidate = candidate
        evidence = candidate.evidence
        coverage = coverageRecords.first {
            $0.context.id == candidate.evidenceOrigin.context.id
                && $0.scope.id == candidate.evidenceOrigin.scopeID
        }
    }

    var categoryName: String {
        switch evidence.category {
        case .cleanup(let locationID):
            switch locationID {
            case "user-caches": return String(localized: "用户与应用缓存")
            case "user-logs": return String(localized: "用户日志")
            case "crash-reports": return String(localized: "崩溃报告")
            case "downloaded-installers": return String(localized: "下载的安装包")
            default: return String(localized: "配置扫描位置")
            }
        case .applicationBundle: return String(localized: "应用包")
        case .residue: return String(localized: "应用残留")
        case .association: return String(localized: "只读关联项目")
        }
    }

    var categoryIdentifier: String {
        switch evidence.category {
        case .cleanup(let locationID): return locationID
        case .applicationBundle: return "application-bundle"
        case .residue(let kind): return "residue.\(kind.rawValue)"
        case .association(let kind): return "association.\(kind.rawValue)"
        }
    }

    var coverageTitle: String {
        coverage?.status.detailTitle ?? String(localized: "覆盖状态未知")
    }

    var coverageExplanation: String {
        guard let coverage else { return String(localized: "覆盖状态未知，建议重新扫描。") }
        if coverage.status == .partial {
            return String(localized: "所属扫描范围存在覆盖缺口；这不表示当前候选本身未被读取。")
        }
        return coverage.status.detailExplanation
    }

    var policySummary: String? {
        guard let policy = coverage?.scope.policy else { return nil }
        var parts = [policy.recursive ? String(localized: "递归扫描") : String(localized: "仅检查当前层级")]
        if !policy.acceptedTypes.isEmpty {
            parts.append(String(localized: "类型：\(policy.acceptedTypes.joined(separator: String(localized: "、")))"))
        }
        if !policy.extensions.isEmpty {
            parts.append(String(localized: "扩展名：\(policy.extensions.joined(separator: String(localized: "、")))"))
        }
        if !policy.excludedPackageExtensions.isEmpty {
            parts.append(String(localized: "包边界：\(policy.excludedPackageExtensions.joined(separator: String(localized: "、")))"))
        }
        return parts.joined(separator: " · ")
    }
}

extension CoverageStatus {
    var detailTitle: String {
        switch self {
        case .completed: return String(localized: "已完成")
        case .partial: return String(localized: "部分完成")
        case .inaccessible: return String(localized: "不可访问")
        case .notFound: return String(localized: "未找到")
        case .skipped: return String(localized: "已跳过")
        case .notSelected: return String(localized: "未选择")
        case .cancelled: return String(localized: "已取消")
        case .notStarted: return String(localized: "尚未开始")
        case .inProgress: return String(localized: "正在扫描")
        }
    }

    var detailExplanation: String {
        switch self {
        case .completed: return String(localized: "声明的扫描策略已执行完成，候选数量可以为零。")
        case .partial: return String(localized: "所属扫描范围存在覆盖缺口；这不表示当前候选本身未被读取。")
        case .inaccessible: return String(localized: "扫描范围入口不可访问，未能完成读取。")
        case .notFound: return String(localized: "扫描时没有找到该范围入口。")
        case .skipped: return String(localized: "该范围因明确的安全限制而跳过。")
        case .notSelected: return String(localized: "该范围未在本轮扫描中启用。")
        case .cancelled: return String(localized: "该范围的扫描已取消。")
        case .notStarted: return String(localized: "该范围尚未开始扫描。")
        case .inProgress: return String(localized: "该范围仍在扫描中。")
        }
    }
}

extension ScanIssueKind {
    var detailTitle: String {
        switch self {
        case .accessFailure: return String(localized: "权限问题")
        case .timeout: return String(localized: "读取超时")
        case .readFailure: return String(localized: "读取失败")
        case .parseFailure: return String(localized: "解析问题")
        case .safetySkip: return String(localized: "安全跳过")
        case .policySkip: return String(localized: "策略跳过")
        case .notFound: return String(localized: "未找到")
        }
    }
}

extension ImpactLevel {
    var detailTitle: String {
        switch self {
        case .review: return String(localized: "需要复核")
        case .caution: return String(localized: "谨慎处理")
        case .readOnly: return String(localized: "只读信息")
        }
    }
}

extension Recoverability {
    var detailTitle: String {
        switch self {
        case .trashManual: return String(localized: "移入废纸篓后，可在 Finder 中手动放回")
        case .withApplicationBundle: return String(localized: "可能随应用包一同移动和恢复")
        case .notApplicable: return String(localized: "本流程不会处理此项目")
        }
    }
}

enum CandidateReviewHighlight {
    static func reconciled(_ currentID: String?, visibleCandidateIDs: [String]) -> String? {
        guard let currentID, visibleCandidateIDs.contains(currentID) else { return nil }
        return currentID
    }
}

enum CandidateObservedNodeType: Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

struct CandidateObservedFileIdentity: Equatable, Sendable {
    let nodeType: CandidateObservedNodeType
    let deviceID: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

enum CandidateFileIdentityReadResult: Equatable, Sendable {
    case found(CandidateObservedFileIdentity)
    case unavailable(errorCode: Int32)
}

protocol CandidateFileIdentityReading: Sendable {
    func identity(atPath path: String) -> CandidateFileIdentityReadResult
}

struct POSIXCandidateFileIdentityReader: CandidateFileIdentityReading {
    func identity(atPath path: String) -> CandidateFileIdentityReadResult {
        var info = stat()
        guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else {
            return .unavailable(errorCode: errno)
        }
        let rawType = info.st_mode & mode_t(S_IFMT)
        let nodeType: CandidateObservedNodeType
        switch rawType {
        case mode_t(S_IFREG): nodeType = .regularFile
        case mode_t(S_IFDIR): nodeType = .directory
        case mode_t(S_IFLNK): nodeType = .symbolicLink
        default: nodeType = .other
        }
        return .found(CandidateObservedFileIdentity(
            nodeType: nodeType,
            deviceID: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        ))
    }
}

enum CandidateFileIdentityFailure: Equatable, Sendable {
    case unavailable(errorCode: Int32)
    case symbolicLink
    case notRegularFile
    case deviceChanged
    case inodeChanged
    case modificationTimeChanged
}

enum CandidateFileIdentityValidation: Equatable, Sendable {
    case valid(URL)
    case rejected(CandidateFileIdentityFailure)
}

protocol CandidateFileIdentityValidating: Sendable {
    func validate(_ candidate: CleanupFileCandidate) -> CandidateFileIdentityValidation
}

struct CandidateFileIdentityValidator: CandidateFileIdentityValidating {
    private let reader: any CandidateFileIdentityReading

    init(reader: any CandidateFileIdentityReading = POSIXCandidateFileIdentityReader()) {
        self.reader = reader
    }

    func validate(_ candidate: CleanupFileCandidate) -> CandidateFileIdentityValidation {
        switch reader.identity(atPath: candidate.path) {
        case .unavailable(let errorCode):
            return .rejected(.unavailable(errorCode: errorCode))
        case .found(let identity):
            switch identity.nodeType {
            case .symbolicLink: return .rejected(.symbolicLink)
            case .regularFile: break
            case .directory, .other: return .rejected(.notRegularFile)
            }
            guard identity.deviceID == candidate.deviceID else { return .rejected(.deviceChanged) }
            guard identity.inode == candidate.inode else { return .rejected(.inodeChanged) }
            guard identity.modifiedSeconds == candidate.modifiedSeconds,
                  identity.modifiedNanoseconds == candidate.modifiedNanoseconds else {
                return .rejected(.modificationTimeChanged)
            }
            return .valid(URL(fileURLWithPath: candidate.path))
        }
    }
}

struct CandidateFileActionAlert: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case staleResult
        case quickLookUnavailable
    }

    let kind: Kind
    var id: Kind { kind }
    var title: String { kind == .staleResult ? String(localized: "无法打开此候选") : String(localized: "无法快速查看") }
    var message: String {
        switch kind {
        case .staleResult: return String(localized: "扫描结果已过期，请重新扫描。")
        case .quickLookUnavailable: return String(localized: "快速查看暂不可用，请稍后重试或重新扫描。")
        }
    }
}

@MainActor
protocol CandidateExternalActionPerforming: AnyObject {
    func revealInFinder(_ url: URL)
    func preview(
        candidate: CleanupFileCandidate,
        validator: any CandidateFileIdentityValidating,
        invalidationHandler: @escaping @MainActor () -> Void
    ) -> Bool
    func endCandidateReview()
}

@MainActor
final class CandidateFileActionCoordinator: ObservableObject {
    @Published var alert: CandidateFileActionAlert?

    private let validator: any CandidateFileIdentityValidating
    private let externalActions: any CandidateExternalActionPerforming

    init(
        validator: any CandidateFileIdentityValidating = CandidateFileIdentityValidator(),
        externalActions: (any CandidateExternalActionPerforming)? = nil
    ) {
        self.validator = validator
        self.externalActions = externalActions ?? MacCandidateExternalActionPerformer()
    }

    func revealInFinder(_ candidate: CleanupFileCandidate) {
        guard case .valid(let url) = validator.validate(candidate) else {
            alert = CandidateFileActionAlert(kind: .staleResult)
            return
        }
        externalActions.revealInFinder(url)
    }

    func preview(_ candidate: CleanupFileCandidate) {
        guard case .valid = validator.validate(candidate) else {
            alert = CandidateFileActionAlert(kind: .staleResult)
            return
        }
        let isAvailable = externalActions.preview(
            candidate: candidate,
            validator: validator
        ) { [weak self] in
            self?.alert = CandidateFileActionAlert(kind: .staleResult)
        }
        if !isAvailable {
            alert = CandidateFileActionAlert(kind: .quickLookUnavailable)
        }
    }

    func endCandidateReview() {
        externalActions.endCandidateReview()
        alert = nil
    }
}

@MainActor
protocol CandidateQuickLookPanelManaging: AnyObject {
    func present(
        dataSource: any QLPreviewPanelDataSource,
        delegate: any QLPreviewPanelDelegate
    ) -> Bool
    func tearDown(ifOwnedBy dataSource: any QLPreviewPanelDataSource)
}

@MainActor
private final class SharedCandidateQuickLookPanelManager: CandidateQuickLookPanelManaging {
    func present(
        dataSource: any QLPreviewPanelDataSource,
        delegate: any QLPreviewPanelDelegate
    ) -> Bool {
        guard let panel = QLPreviewPanel.shared() else { return false }
        panel.dataSource = dataSource
        panel.delegate = delegate
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func tearDown(ifOwnedBy dataSource: any QLPreviewPanelDataSource) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.dataSource === dataSource else { return }
        panel.dataSource = nil
        panel.delegate = nil
        panel.reloadData()
        panel.orderOut(nil)
    }
}

@MainActor
private final class MacCandidateExternalActionPerformer: CandidateExternalActionPerforming {
    private let quickLookController = CandidateQuickLookController()

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func preview(
        candidate: CleanupFileCandidate,
        validator: any CandidateFileIdentityValidating,
        invalidationHandler: @escaping @MainActor () -> Void
    ) -> Bool {
        quickLookController.present(
            candidate: candidate,
            validator: validator,
            invalidationHandler: invalidationHandler
        )
    }

    func endCandidateReview() {
        quickLookController.tearDown()
    }
}

@MainActor
private final class CandidateQuickLookItem: NSObject, @preconcurrency QLPreviewItem {
    private let candidate: CleanupFileCandidate
    private let validator: any CandidateFileIdentityValidating
    private let invalidationHandler: @MainActor () -> Void

    init(
        candidate: CleanupFileCandidate,
        validator: any CandidateFileIdentityValidating,
        invalidationHandler: @escaping @MainActor () -> Void
    ) {
        self.candidate = candidate
        self.validator = validator
        self.invalidationHandler = invalidationHandler
    }

    var previewItemURL: URL? {
        guard case .valid(let url) = validator.validate(candidate) else {
            invalidationHandler()
            return nil
        }
        return url
    }

    var previewItemTitle: String? {
        URL(fileURLWithPath: candidate.path).lastPathComponent
    }
}

@MainActor
private final class UnavailableQuickLookItem: NSObject, @preconcurrency QLPreviewItem {
    var previewItemURL: URL? { nil }
}

@MainActor
final class CandidateQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSWindowDelegate {
    private var item: CandidateQuickLookItem?
    private let unavailableItem = UnavailableQuickLookItem()
    private let panelManager: any CandidateQuickLookPanelManaging
    private var activeSessionID: UUID?

    init(panelManager: (any CandidateQuickLookPanelManaging)? = nil) {
        self.panelManager = panelManager ?? SharedCandidateQuickLookPanelManager()
    }

    func present(
        candidate: CleanupFileCandidate,
        validator: any CandidateFileIdentityValidating,
        invalidationHandler: @escaping @MainActor () -> Void
    ) -> Bool {
        tearDown()
        let sessionID = UUID()
        activeSessionID = sessionID
        item = CandidateQuickLookItem(
            candidate: candidate,
            validator: validator,
            invalidationHandler: { [weak self] in
                self?.handleInvalidation(sessionID: sessionID, invalidationHandler: invalidationHandler)
            }
        )
        guard panelManager.present(dataSource: self, delegate: self) else {
            activeSessionID = nil
            item = nil
            return false
        }
        return true
    }

    func tearDown() {
        activeSessionID = nil
        item = nil
        panelManager.tearDown(ifOwnedBy: self)
    }

    private func handleInvalidation(
        sessionID: UUID,
        invalidationHandler: @MainActor () -> Void
    ) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        item = nil
        panelManager.tearDown(ifOwnedBy: self)
        invalidationHandler()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        item == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        item ?? unavailableItem
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel,
              panel.dataSource === self else { return }
        tearDown()
    }
}
