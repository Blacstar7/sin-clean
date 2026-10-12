import Foundation

// SC-PD3 卸载后复查（冻结语义 work/SC-PD3-frozen-semantics.md §4）。
// 身份锚定＝原计划冻结的应用身份与 Bundle Identifier；重跑既有精确规则；只读，不产生执行项。

// MARK: - 复查身份锚定（冻结 §4.2）

struct UninstallRecheckAnchor: Equatable, Sendable {
    let applicationName: String
    let bundleIdentifier: String
    let applicationPath: String
    let deviceID: UInt64
    let inode: UInt64
    let logicalBytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    /// 从原冻结计划与执行报告提取锚定上下文；绝不取当前 UI 选择。
    static func extract(plan: OperationPlan?, report: UninstallExecutionReport?) -> UninstallRecheckAnchor? {
        guard let report, let plan else { return nil }
        guard let applicationItem = plan.items.first(where: {
            $0.category == .applicationBundle && $0.identity.itemType == .applicationBundle
        }) else { return nil }
        guard let bundleIdentifier = applicationItem.identity.bundleIdentifier,
              bundleIdentifier == report.bundleIdentifier else { return nil }
        return UninstallRecheckAnchor(
            applicationName: report.applicationName,
            bundleIdentifier: bundleIdentifier,
            applicationPath: applicationItem.identity.originalPath,
            deviceID: applicationItem.identity.deviceID,
            inode: applicationItem.identity.inode,
            logicalBytes: applicationItem.identity.logicalBytes,
            modifiedSeconds: applicationItem.identity.modifiedSeconds,
            modifiedNanoseconds: applicationItem.identity.modifiedNanoseconds
        )
    }

    func makeSyntheticApplication() -> InstalledApplication {
        InstalledApplication(
            id: "recheck|\(bundleIdentifier)",
            name: applicationName,
            path: applicationPath,
            rootPath: URL(fileURLWithPath: applicationPath).deletingLastPathComponent().standardizedFileURL.path,
            bundleIdentifier: bundleIdentifier,
            version: nil,
            buildNumber: nil,
            allocatedBytes: 0,
            logicalBytes: logicalBytes,
            modifiedSeconds: modifiedSeconds,
            modifiedNanoseconds: modifiedNanoseconds,
            deviceID: deviceID,
            inode: inode,
            signatureState: .unavailable,
            signer: nil,
            teamIdentifier: nil,
            evidenceOrigin: CandidateEvidenceOrigin(
                context: ScanContext(),
                scopeID: "uninstall-recheck",
                reasonCode: .applicationDirectory
            )
        )
    }
}

// MARK: - 四类复查结果（冻结 §4.4：判定序 R1→R4；R2/R3 可并存）

enum UninstallRecheckCategory: Equatable, Sendable {
    case notFoundInCheckedScope
    case foundUserResidues(count: Int)
    case foundReadOnlyAssociations(count: Int)
    case incomplete(reason: UninstallRecheckIncompleteReason)
}

enum UninstallRecheckIncompleteReason: Equatable, Sendable {
    case anchoredIdentityUnavailable
    case coverageGap(gaps: [AppFootprintCoverageGap])
}

struct UninstallRecheckReport: Equatable, Sendable {
    let anchor: UninstallRecheckAnchor
    let ranAt: Date
    let categories: [UninstallRecheckCategory]
    let foundResidueEntries: [AppFootprintResidueEntry]
    let foundAssociationEntries: [AppFootprintAssociationEntry]
    let foundResidueBytes: Int64?
    let gaps: [AppFootprintCoverageGap]

    var primaryCategory: UninstallRecheckCategory {
        categories.first ?? .incomplete(reason: .anchoredIdentityUnavailable)
    }
}

// MARK: - 复查引擎

struct UninstallRecheckEngine: Sendable {
    private let residueScanner: any AppResidueScanning
    private let associationScanner: any AppAssociationScanning
    private let clock: @Sendable () -> Date

    init(
        residueScanner: any AppResidueScanning,
        associationScanner: any AppAssociationScanning,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.residueScanner = residueScanner
        self.associationScanner = associationScanner
        self.clock = clock
    }

    func run(anchor: UninstallRecheckAnchor) async -> UninstallRecheckReport {
        // R1a：锚定身份不可用（Bundle Identifier 缺失或非法）
        guard ScanRules.bundleIdentifierRestriction(anchor.bundleIdentifier) == nil else {
            return UninstallRecheckReport(
                anchor: anchor,
                ranAt: clock(),
                categories: [.incomplete(reason: .anchoredIdentityUnavailable)],
                foundResidueEntries: [],
                foundAssociationEntries: [],
                foundResidueBytes: nil,
                gaps: []
            )
        }

        // 重跑既有精确规则（九条精确路径＋六类只读位置；不模糊、不全盘）
        let synthetic = anchor.makeSyntheticApplication()
        let residueReport = await residueScanner.scan(for: synthetic)
        let associationReport = await associationScanner.scan(for: synthetic, enabled: true)

        // R1b：复查覆盖缺口（与占用全景同一缺口判定）
        let gaps = AppFootprintEngine.coverageGaps(
            in: residueReport.coverage + associationReport.coverage
        )

        let residueEntries = residueReport.candidates.map { candidate in
            AppFootprintResidueEntry(
                id: candidate.id,
                kind: candidate.kind,
                path: candidate.path,
                allocatedBytes: candidate.allocatedBytes
            )
        }
        let associationEntries = associationReport.items.map { item in
            AppFootprintAssociationEntry(
                id: item.id,
                kind: item.kind,
                path: item.path,
                isInsideApplicationBundle: item.isInsideApplicationBundle
            )
        }

        // 复查发现容量（仅复查完整时呈现；沿同一确定性去重）
        var foundBytes: Int64?
        if gaps.isEmpty {
            let dedup = AppFootprintEngine.deduplicatedSum(items: residueReport.candidates.map { candidate in
                AppFootprintSumItem(
                    tier: .userResidue,
                    path: URL(fileURLWithPath: candidate.path).standardizedFileURL.path,
                    allocatedBytes: candidate.allocatedBytes,
                    deviceID: candidate.deviceID,
                    inode: candidate.inode
                )
            })
            foundBytes = dedup.total
        }

        var categories: [UninstallRecheckCategory] = []
        if !gaps.isEmpty {
            categories.append(.incomplete(reason: .coverageGap(gaps: gaps)))
        } else {
            if !residueEntries.isEmpty {
                categories.append(.foundUserResidues(count: residueEntries.count))
            }
            if !associationEntries.isEmpty {
                categories.append(.foundReadOnlyAssociations(count: associationEntries.count))
            }
            if categories.isEmpty {
                categories.append(.notFoundInCheckedScope)
            }
        }

        return UninstallRecheckReport(
            anchor: anchor,
            ranAt: clock(),
            categories: categories,
            foundResidueEntries: residueEntries,
            foundAssociationEntries: associationEntries,
            foundResidueBytes: foundBytes,
            gaps: gaps
        )
    }
}
