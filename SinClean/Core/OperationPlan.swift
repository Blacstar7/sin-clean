import Foundation

enum OperationPlanDomain: String, Hashable, Sendable {
    case cleanup
    case uninstall
}

enum OperationPlanState: String, Hashable, Sendable {
    case frozen
}

enum OperationPlanItemState: String, Hashable, Sendable {
    case planned
}

enum OperationPlanItemCategory: Hashable, Sendable {
    case cleanup(locationID: String)
    case applicationBundle
    case residue(kind: AppResidueKind)
}

enum IdentitySnapshotItemType: String, Hashable, Sendable {
    case cleanupRegularFile
    case applicationBundle
    case residueFile
    case residueDirectory
}

struct IdentitySnapshot: Hashable, Sendable {
    let originalPath: String
    let scanRootPath: String
    let itemType: IdentitySnapshotItemType
    let deviceID: UInt64
    let inode: UInt64
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let bundleIdentifier: String?

    fileprivate init(
        originalPath: String,
        scanRootPath: String,
        itemType: IdentitySnapshotItemType,
        deviceID: UInt64,
        inode: UInt64,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64,
        bundleIdentifier: String?
    ) {
        self.originalPath = originalPath
        self.scanRootPath = scanRootPath
        self.itemType = itemType
        self.deviceID = deviceID
        self.inode = inode
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.bundleIdentifier = bundleIdentifier
    }
}

struct OperationPlanParentApplication: Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let bundleIdentifier: String
}

enum OperationPlanSafetyBoundary: String, Hashable, Sendable {
    case cleanupRegularFileOnly
    case applicationBundleMustSucceedFirst
    case residueOnlyAfterApplicationSucceeds
}

struct OperationPlanItem: Identifiable, Hashable, Sendable {
    let id: String
    let state: OperationPlanItemState
    let category: OperationPlanItemCategory
    let order: Int
    let identity: IdentitySnapshot
    let evidence: CandidateEvidence
    let estimatedBytes: Int64
    let parentApplication: OperationPlanParentApplication?
    let safetyBoundary: OperationPlanSafetyBoundary

    fileprivate init(
        id: String,
        category: OperationPlanItemCategory,
        order: Int,
        identity: IdentitySnapshot,
        evidence: CandidateEvidence,
        estimatedBytes: Int64,
        parentApplication: OperationPlanParentApplication?,
        safetyBoundary: OperationPlanSafetyBoundary
    ) {
        self.id = id
        state = .planned
        self.category = category
        self.order = order
        self.identity = identity
        self.evidence = evidence
        self.estimatedBytes = estimatedBytes
        self.parentApplication = parentApplication
        self.safetyBoundary = safetyBoundary
    }
}

struct OperationPlanScanContextSnapshot: Hashable, Sendable {
    let id: UUID
    let startedAt: Date
    let ruleVersion: String
}

struct OperationPlanCoverageRecord: Hashable, Sendable {
    let contextID: UUID
    let contextStartedAt: Date
    let ruleVersion: String
    let scopeID: String
    let scanner: ScannerKind
    let phase: ScanPhase
    let rootPath: String
    let targetPath: String?
    let status: CoverageStatus
    let issueCount: Int
    let accessIssueCount: Int
    let retainedIssueSampleCount: Int
    let omittedIssueCount: Int
}

struct OperationPlanCoverageSummary: Hashable, Sendable {
    let records: [OperationPlanCoverageRecord]

    var issueCount: Int {
        records.reduce(0) { $0 + $1.issueCount }
    }

    var accessIssueCount: Int {
        records.reduce(0) { $0 + $1.accessIssueCount }
    }

    var retainedIssueSampleCount: Int {
        records.reduce(0) { $0 + $1.retainedIssueSampleCount }
    }

    var omittedIssueCount: Int {
        records.reduce(0) { $0 + $1.omittedIssueCount }
    }
}

enum OperationPlanWarning: String, Hashable, Sendable {
    case trashOnly
    case executionIdentityRevalidationRequired
    case applicationFailureBlocksAllResidues
    case readOnlyAssociationsExcluded
}

struct OperationPlan: Identifiable, Hashable, Sendable {
    let id: UUID
    let state: OperationPlanState
    let domain: OperationPlanDomain
    let createdAt: Date
    let frozenAt: Date
    let sourceScanContexts: [OperationPlanScanContextSnapshot]
    let coverageSummary: OperationPlanCoverageSummary
    let items: [OperationPlanItem]
    let estimatedBytes: Int64
    let warnings: [OperationPlanWarning]

    var itemCount: Int {
        items.count
    }

    fileprivate init(
        id: UUID,
        domain: OperationPlanDomain,
        createdAt: Date,
        frozenAt: Date,
        sourceScanContexts: [OperationPlanScanContextSnapshot],
        coverageSummary: OperationPlanCoverageSummary,
        items: [OperationPlanItem],
        estimatedBytes: Int64,
        warnings: [OperationPlanWarning]
    ) {
        self.id = id
        state = .frozen
        self.domain = domain
        self.createdAt = createdAt
        self.frozenAt = frozenAt
        self.sourceScanContexts = sourceScanContexts
        self.coverageSummary = coverageSummary
        self.items = items
        self.estimatedBytes = estimatedBytes
        self.warnings = warnings
    }
}

enum OperationPlanIdentityField: String, Hashable, Sendable {
    case itemID
    case originalPath
    case scanRootPath
    case deviceID
    case inode
    case modifiedNanoseconds
}

enum OperationPlanBuildError: Error, Equatable, Sendable {
    case emptyPlan(domain: OperationPlanDomain)
    case missingApplication
    case duplicateItemID(String)
    case duplicatePath(String)
    case incompleteIdentity(itemID: String, field: OperationPlanIdentityField)
    case invalidCapacity(itemID: String, allocatedBytes: Int64, logicalBytes: Int64)
    case capacityOverflow
    case invalidBundleIdentifier(itemID: String)
    case bundleIdentifierMismatch(itemID: String)
    case evidenceMismatch(itemID: String)
}

extension OperationPlanBuildError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyPlan(let domain):
            return String(localized: "无法冻结空的\(domain == .cleanup ? String(localized: "清理") : String(localized: "卸载"))计划。")
        case .missingApplication:
            return String(localized: "卸载计划缺少应用本体。")
        case .duplicateItemID(let itemID):
            return String(localized: "计划项目 ID 重复：\(itemID)")
        case .duplicatePath(let path):
            return String(localized: "计划路径重复：\(path)")
        case .incompleteIdentity(let itemID, let field):
            return String(localized: "计划项目 \(itemID) 的身份字段不完整：\(field.rawValue)")
        case .invalidCapacity(let itemID, let allocatedBytes, let logicalBytes):
            return String(localized: "计划项目 \(itemID) 的容量非法（allocated=\(allocatedBytes)，logical=\(logicalBytes)）。")
        case .capacityOverflow:
            return String(localized: "计划预计容量合计溢出。")
        case .invalidBundleIdentifier(let itemID):
            return String(localized: "卸载计划项目 \(itemID) 的 Bundle Identifier 无效。")
        case .bundleIdentifierMismatch(let itemID):
            return String(localized: "卸载计划项目 \(itemID) 与父应用 Bundle Identifier 不一致。")
        case .evidenceMismatch(let itemID):
            return String(localized: "计划项目 \(itemID) 的证据与身份快照不一致。")
        }
    }
}

struct FrozenCleanupOperation: Hashable, Sendable {
    let plan: OperationPlan
    let executionCandidates: [CleanupFileCandidate]
}

struct FrozenUninstallOperation: Hashable, Sendable {
    let plan: OperationPlan
    let executionCandidates: [UninstallItemCandidate]
}

struct OperationPlanBuilder: Sendable {
    func freezeCleanup(
        candidates: [CleanupFileCandidate],
        coverageRecords: [ScanCoverage],
        planID: UUID = UUID(),
        frozenAt: Date = Date()
    ) throws -> FrozenCleanupOperation {
        guard !candidates.isEmpty else {
            throw OperationPlanBuildError.emptyPlan(domain: .cleanup)
        }

        let orderedCandidates = candidates.sorted(by: cleanupOrder)
        let items = orderedCandidates.enumerated().map { index, candidate in
            OperationPlanItem(
                id: candidate.id,
                category: .cleanup(locationID: candidate.locationID),
                order: index,
                identity: IdentitySnapshot(
                    originalPath: candidate.path,
                    scanRootPath: candidate.rootPath,
                    itemType: .cleanupRegularFile,
                    deviceID: candidate.deviceID,
                    inode: candidate.inode,
                    allocatedBytes: candidate.allocatedBytes,
                    logicalBytes: candidate.logicalBytes,
                    modifiedSeconds: candidate.modifiedSeconds,
                    modifiedNanoseconds: candidate.modifiedNanoseconds,
                    bundleIdentifier: nil
                ),
                evidence: candidate.evidence,
                estimatedBytes: candidate.allocatedBytes,
                parentApplication: nil,
                safetyBoundary: .cleanupRegularFileOnly
            )
        }
        let estimatedBytes = try validateAndTotal(items: items, domain: .cleanup)
        let plan = makePlan(
            id: planID,
            domain: .cleanup,
            frozenAt: frozenAt,
            items: items,
            estimatedBytes: estimatedBytes,
            coverageRecords: coverageRecords,
            warnings: [.trashOnly, .executionIdentityRevalidationRequired]
        )
        return FrozenCleanupOperation(plan: plan, executionCandidates: orderedCandidates)
    }

    func freezeUninstall(
        application: InstalledApplication?,
        residues: [AppResidueCandidate],
        coverageRecords: [ScanCoverage],
        planID: UUID = UUID(),
        frozenAt: Date = Date()
    ) throws -> FrozenUninstallOperation {
        guard let application else {
            throw OperationPlanBuildError.missingApplication
        }
        guard let applicationBundleIdentifier = application.bundleIdentifier,
              ScanRules.bundleIdentifierRestriction(applicationBundleIdentifier) == nil else {
            throw OperationPlanBuildError.invalidBundleIdentifier(itemID: application.id)
        }

        let orderedResidues = residues.sorted(by: residueOrder)
        let parentApplication = OperationPlanParentApplication(
            id: application.id,
            name: application.name,
            path: application.path,
            bundleIdentifier: applicationBundleIdentifier
        )
        let applicationItem = OperationPlanItem(
            id: application.id,
            category: .applicationBundle,
            order: 0,
            identity: IdentitySnapshot(
                originalPath: application.path,
                scanRootPath: application.rootPath,
                itemType: .applicationBundle,
                deviceID: application.deviceID,
                inode: application.inode,
                allocatedBytes: application.allocatedBytes,
                logicalBytes: application.logicalBytes,
                modifiedSeconds: application.modifiedSeconds,
                modifiedNanoseconds: application.modifiedNanoseconds,
                bundleIdentifier: applicationBundleIdentifier
            ),
            evidence: application.evidence,
            estimatedBytes: application.allocatedBytes,
            parentApplication: nil,
            safetyBoundary: .applicationBundleMustSucceedFirst
        )
        let residueItems = orderedResidues.enumerated().map { index, residue in
            OperationPlanItem(
                id: residue.id,
                category: .residue(kind: residue.kind),
                order: index + 1,
                identity: IdentitySnapshot(
                    originalPath: residue.path,
                    scanRootPath: residue.rootPath,
                    itemType: residue.isDirectory ? .residueDirectory : .residueFile,
                    deviceID: residue.deviceID,
                    inode: residue.inode,
                    allocatedBytes: residue.allocatedBytes,
                    logicalBytes: residue.logicalBytes,
                    modifiedSeconds: residue.modifiedSeconds,
                    modifiedNanoseconds: residue.modifiedNanoseconds,
                    bundleIdentifier: residue.bundleIdentifier
                ),
                evidence: residue.evidence,
                estimatedBytes: residue.allocatedBytes,
                parentApplication: parentApplication,
                safetyBoundary: .residueOnlyAfterApplicationSucceeds
            )
        }
        let items = [applicationItem] + residueItems
        let estimatedBytes = try validateAndTotal(
            items: items,
            domain: .uninstall,
            parentBundleIdentifier: applicationBundleIdentifier
        )
        let plan = makePlan(
            id: planID,
            domain: .uninstall,
            frozenAt: frozenAt,
            items: items,
            estimatedBytes: estimatedBytes,
            coverageRecords: coverageRecords,
            warnings: [
                .trashOnly,
                .executionIdentityRevalidationRequired,
                .applicationFailureBlocksAllResidues,
                .readOnlyAssociationsExcluded
            ]
        )
        let executionCandidates = [makeApplicationCandidate(
            application,
            bundleIdentifier: applicationBundleIdentifier
        )] + orderedResidues.map {
            makeResidueCandidate(
                $0,
                application: application,
                bundleIdentifier: applicationBundleIdentifier
            )
        }
        return FrozenUninstallOperation(plan: plan, executionCandidates: executionCandidates)
    }

    private func cleanupOrder(_ lhs: CleanupFileCandidate, _ rhs: CleanupFileCandidate) -> Bool {
        if lhs.locationID != rhs.locationID {
            return lhs.locationID < rhs.locationID
        }
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.id < rhs.id
    }

    private func residueOrder(_ lhs: AppResidueCandidate, _ rhs: AppResidueCandidate) -> Bool {
        let lhsRank = AppResidueKind.allCases.firstIndex(of: lhs.kind) ?? Int.max
        let rhsRank = AppResidueKind.allCases.firstIndex(of: rhs.kind) ?? Int.max
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.id < rhs.id
    }

    private func validateAndTotal(
        items: [OperationPlanItem],
        domain: OperationPlanDomain,
        parentBundleIdentifier: String? = nil
    ) throws -> Int64 {
        guard !items.isEmpty else {
            throw OperationPlanBuildError.emptyPlan(domain: domain)
        }
        var itemIDs = Set<String>()
        var paths = Set<String>()
        var total: Int64 = 0

        for (expectedOrder, item) in items.enumerated() {
            guard item.order == expectedOrder else {
                throw OperationPlanBuildError.evidenceMismatch(itemID: item.id)
            }
            guard itemIDs.insert(item.id).inserted else {
                throw OperationPlanBuildError.duplicateItemID(item.id)
            }
            guard paths.insert(item.identity.originalPath).inserted else {
                throw OperationPlanBuildError.duplicatePath(item.identity.originalPath)
            }
            if domain == .uninstall {
                guard let bundleIdentifier = item.identity.bundleIdentifier,
                      ScanRules.bundleIdentifierRestriction(bundleIdentifier) == nil else {
                    throw OperationPlanBuildError.invalidBundleIdentifier(itemID: item.id)
                }
                guard bundleIdentifier == parentBundleIdentifier else {
                    throw OperationPlanBuildError.bundleIdentifierMismatch(itemID: item.id)
                }
            } else if item.identity.bundleIdentifier != nil {
                throw OperationPlanBuildError.evidenceMismatch(itemID: item.id)
            }
            try validateIdentity(item)
            let (newTotal, overflow) = total.addingReportingOverflow(item.estimatedBytes)
            guard !overflow else {
                throw OperationPlanBuildError.capacityOverflow
            }
            total = newTotal
        }
        return total
    }

    private func validateIdentity(_ item: OperationPlanItem) throws {
        guard !item.id.isEmpty else {
            throw OperationPlanBuildError.incompleteIdentity(itemID: item.id, field: .itemID)
        }
        guard !item.identity.originalPath.isEmpty, item.identity.originalPath.hasPrefix("/") else {
            throw OperationPlanBuildError.incompleteIdentity(itemID: item.id, field: .originalPath)
        }
        guard !item.identity.scanRootPath.isEmpty, item.identity.scanRootPath.hasPrefix("/") else {
            throw OperationPlanBuildError.incompleteIdentity(itemID: item.id, field: .scanRootPath)
        }
        guard item.identity.deviceID > 0 else {
            throw OperationPlanBuildError.incompleteIdentity(itemID: item.id, field: .deviceID)
        }
        guard item.identity.inode > 0 else {
            throw OperationPlanBuildError.incompleteIdentity(itemID: item.id, field: .inode)
        }
        guard (0..<1_000_000_000).contains(item.identity.modifiedNanoseconds) else {
            throw OperationPlanBuildError.incompleteIdentity(itemID: item.id, field: .modifiedNanoseconds)
        }
        guard item.identity.allocatedBytes >= 0,
              item.identity.logicalBytes >= 0,
              item.estimatedBytes >= 0,
              item.estimatedBytes == item.identity.allocatedBytes else {
            throw OperationPlanBuildError.invalidCapacity(
                itemID: item.id,
                allocatedBytes: item.identity.allocatedBytes,
                logicalBytes: item.identity.logicalBytes
            )
        }
        guard item.evidence.sourcePath == item.identity.originalPath else {
            throw OperationPlanBuildError.evidenceMismatch(itemID: item.id)
        }
        switch (item.category, item.evidence.category) {
        case (.cleanup(let itemLocationID), .cleanup(let evidenceLocationID))
            where itemLocationID == evidenceLocationID:
            guard item.identity.itemType == .cleanupRegularFile,
                  item.parentApplication == nil,
                  item.safetyBoundary == .cleanupRegularFileOnly else {
                throw OperationPlanBuildError.evidenceMismatch(itemID: item.id)
            }
        case (.applicationBundle, .applicationBundle):
            guard item.identity.itemType == .applicationBundle,
                  item.parentApplication == nil,
                  item.safetyBoundary == .applicationBundleMustSucceedFirst,
                  item.evidence.associatedBundleIdentifier == item.identity.bundleIdentifier else {
                throw OperationPlanBuildError.evidenceMismatch(itemID: item.id)
            }
        case (.residue(let itemKind), .residue(let evidenceKind)) where itemKind == evidenceKind:
            guard item.identity.itemType == .residueFile || item.identity.itemType == .residueDirectory,
                  item.parentApplication?.bundleIdentifier == item.identity.bundleIdentifier,
                  item.safetyBoundary == .residueOnlyAfterApplicationSucceeds,
                  item.evidence.associatedBundleIdentifier == item.identity.bundleIdentifier else {
                throw OperationPlanBuildError.evidenceMismatch(itemID: item.id)
            }
        default:
            throw OperationPlanBuildError.evidenceMismatch(itemID: item.id)
        }
    }

    private func makePlan(
        id: UUID,
        domain: OperationPlanDomain,
        frozenAt: Date,
        items: [OperationPlanItem],
        estimatedBytes: Int64,
        coverageRecords: [ScanCoverage],
        warnings: [OperationPlanWarning]
    ) -> OperationPlan {
        let contexts = makeSourceContexts(items: items, coverageRecords: coverageRecords)
        let coverage = OperationPlanCoverageSummary(
            records: coverageRecords.map(makeCoverageRecord).sorted(by: coverageOrder)
        )
        return OperationPlan(
            id: id,
            domain: domain,
            createdAt: frozenAt,
            frozenAt: frozenAt,
            sourceScanContexts: contexts,
            coverageSummary: coverage,
            items: items,
            estimatedBytes: estimatedBytes,
            warnings: warnings
        )
    }

    private func makeSourceContexts(
        items: [OperationPlanItem],
        coverageRecords: [ScanCoverage]
    ) -> [OperationPlanScanContextSnapshot] {
        let contexts = items.map(\.evidence.origin.context) + coverageRecords.map(\.context)
        var unique: [UUID: ScanContext] = [:]
        for context in contexts {
            unique[context.id] = context
        }
        return unique.values
            .map { OperationPlanScanContextSnapshot(id: $0.id, startedAt: $0.startedAt, ruleVersion: $0.ruleVersion) }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private func makeCoverageRecord(_ coverage: ScanCoverage) -> OperationPlanCoverageRecord {
        OperationPlanCoverageRecord(
            contextID: coverage.context.id,
            contextStartedAt: coverage.context.startedAt,
            ruleVersion: coverage.context.ruleVersion,
            scopeID: coverage.scope.id,
            scanner: coverage.scope.scanner,
            phase: coverage.scope.phase,
            rootPath: coverage.scope.rootPath,
            targetPath: coverage.scope.targetPath,
            status: coverage.status,
            issueCount: coverage.issueCount,
            accessIssueCount: coverage.accessIssueCount,
            retainedIssueSampleCount: coverage.issues.count,
            omittedIssueCount: coverage.omittedIssueCount
        )
    }

    private func coverageOrder(_ lhs: OperationPlanCoverageRecord, _ rhs: OperationPlanCoverageRecord) -> Bool {
        if lhs.contextStartedAt != rhs.contextStartedAt {
            return lhs.contextStartedAt < rhs.contextStartedAt
        }
        if lhs.contextID != rhs.contextID {
            return lhs.contextID.uuidString < rhs.contextID.uuidString
        }
        if lhs.scopeID != rhs.scopeID {
            return lhs.scopeID < rhs.scopeID
        }
        if lhs.scanner != rhs.scanner {
            return lhs.scanner.rawValue < rhs.scanner.rawValue
        }
        if lhs.phase != rhs.phase {
            return lhs.phase.rawValue < rhs.phase.rawValue
        }
        if lhs.rootPath != rhs.rootPath {
            return lhs.rootPath < rhs.rootPath
        }
        if lhs.targetPath != rhs.targetPath {
            return (lhs.targetPath ?? "") < (rhs.targetPath ?? "")
        }
        if lhs.status != rhs.status {
            return lhs.status.rawValue < rhs.status.rawValue
        }
        if lhs.issueCount != rhs.issueCount {
            return lhs.issueCount < rhs.issueCount
        }
        if lhs.accessIssueCount != rhs.accessIssueCount {
            return lhs.accessIssueCount < rhs.accessIssueCount
        }
        if lhs.retainedIssueSampleCount != rhs.retainedIssueSampleCount {
            return lhs.retainedIssueSampleCount < rhs.retainedIssueSampleCount
        }
        return lhs.omittedIssueCount < rhs.omittedIssueCount
    }

    private func makeApplicationCandidate(
        _ application: InstalledApplication,
        bundleIdentifier: String
    ) -> UninstallItemCandidate {
        UninstallItemCandidate(
            id: application.id,
            applicationName: application.name,
            bundleIdentifier: bundleIdentifier,
            kind: .applicationBundle,
            residueKind: nil,
            path: application.path,
            rootPath: application.rootPath,
            allocatedBytes: application.allocatedBytes,
            logicalBytes: application.logicalBytes,
            modifiedSeconds: application.modifiedSeconds,
            modifiedNanoseconds: application.modifiedNanoseconds,
            deviceID: application.deviceID,
            inode: application.inode
        )
    }

    private func makeResidueCandidate(
        _ residue: AppResidueCandidate,
        application: InstalledApplication,
        bundleIdentifier: String
    ) -> UninstallItemCandidate {
        UninstallItemCandidate(
            id: residue.id,
            applicationName: application.name,
            bundleIdentifier: bundleIdentifier,
            kind: residue.isDirectory ? .residueDirectory : .residueFile,
            residueKind: residue.kind,
            path: residue.path,
            rootPath: residue.rootPath,
            allocatedBytes: residue.allocatedBytes,
            logicalBytes: residue.logicalBytes,
            modifiedSeconds: residue.modifiedSeconds,
            modifiedNanoseconds: residue.modifiedNanoseconds,
            deviceID: residue.deviceID,
            inode: residue.inode
        )
    }
}
