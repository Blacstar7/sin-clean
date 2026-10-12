import Foundation

protocol TrashOpening: Sendable {
    @MainActor func openTrash() -> Bool
}

struct OperationHistoryPaths: Sendable {
    let historyFileURL: URL
    let legacyCleanupFileURL: URL
    let legacyUninstallFileURL: URL

    init(baseDirectory: URL? = nil) {
        let directory = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "SinClean", directoryHint: .isDirectory)
        historyFileURL = directory.appending(path: "operation-history.json")
        legacyCleanupFileURL = directory.appending(path: "cleanup-history.json")
        legacyUninstallFileURL = directory.appending(path: "uninstall-history.json")
    }

    init(historyFileURL: URL, legacyCleanupFileURL: URL, legacyUninstallFileURL: URL) {
        self.historyFileURL = historyFileURL
        self.legacyCleanupFileURL = legacyCleanupFileURL
        self.legacyUninstallFileURL = legacyUninstallFileURL
    }
}

protocol OperationHistoryFileAccessing: Sendable {
    func fileExists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func createDirectory(at url: URL) throws
    func writeAtomically(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
}

struct LocalOperationHistoryFileAccess: OperationHistoryFileAccessing {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

enum OperationHistoryDetailAvailability: String, Codable, Hashable, Sendable {
    case complete
    case receiptUnavailable
    case legacySummaryOnly
}

struct OperationHistoryStatusCounts: Codable, Hashable, Sendable {
    let succeeded: Int?
    let failed: Int?
    let skipped: Int?
    let aborted: Int?
    let notExecuted: Int?

    init(receipt: ExecutionReceipt) {
        succeeded = receipt.count(for: .succeeded)
        failed = receipt.count(for: .failed)
        skipped = receipt.count(for: .skipped)
        aborted = receipt.count(for: .aborted)
        notExecuted = receipt.count(for: .notExecuted)
    }

    init(resultSet: ExecutionResultSet) {
        succeeded = resultSet.items.filter { $0.status == .succeeded }.count
        failed = resultSet.items.filter { $0.status == .failed }.count
        skipped = resultSet.items.filter { $0.status == .skipped }.count
        aborted = resultSet.items.filter { $0.status == .aborted }.count
        notExecuted = resultSet.items.filter { $0.status == .notExecuted }.count
    }

    init(succeeded: Int?, failed: Int?, skipped: Int?, aborted: Int?, notExecuted: Int?) {
        self.succeeded = succeeded
        self.failed = failed
        self.skipped = skipped
        self.aborted = aborted
        self.notExecuted = notExecuted
    }
}

struct OperationHistorySummarySnapshot: Codable, Hashable, Sendable {
    let title: String
    let statusCounts: OperationHistoryStatusCounts
    let actualSucceededBytes: Int64
    let wasUserAborted: Bool
}

struct OperationHistoryIdentitySnapshot: Codable, Hashable, Sendable {
    let originalPath: String
    let scanRootPath: String
    let itemType: String
    let deviceID: UInt64
    let inode: UInt64
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let bundleIdentifier: String?

    init(_ value: IdentitySnapshot) {
        originalPath = value.originalPath
        scanRootPath = value.scanRootPath
        itemType = value.itemType.rawValue
        deviceID = value.deviceID
        inode = value.inode
        allocatedBytes = value.allocatedBytes
        logicalBytes = value.logicalBytes
        modifiedSeconds = value.modifiedSeconds
        modifiedNanoseconds = value.modifiedNanoseconds
        bundleIdentifier = value.bundleIdentifier
    }
}

struct OperationHistoryItemCategorySnapshot: Codable, Hashable, Sendable {
    let kind: String
    let associatedValue: String?

    init(_ value: OperationPlanItemCategory) {
        switch value {
        case .cleanup(let locationID):
            kind = "cleanup"
            associatedValue = locationID
        case .applicationBundle:
            kind = "applicationBundle"
            associatedValue = nil
        case .residue(let residueKind):
            kind = "residue"
            associatedValue = residueKind.rawValue
        }
    }

    var title: String {
        switch kind {
        case "cleanup": String(localized: "清理候选")
        case "applicationBundle": String(localized: "应用本体")
        case "residue": associatedValue.map { String(localized: "卸载残留 · \($0)") } ?? String(localized: "卸载残留")
        default: String(localized: "未知类别")
        }
    }

    fileprivate var receiptCategory: OperationPlanItemCategory? {
        switch kind {
        case "cleanup": return .cleanup(locationID: associatedValue ?? "")
        case "applicationBundle": return .applicationBundle
        case "residue":
            guard let associatedValue, let kind = AppResidueKind(rawValue: associatedValue) else { return nil }
            return .residue(kind: kind)
        default: return nil
        }
    }
}

struct OperationHistoryEvidenceSnapshot: Codable, Hashable, Sendable {
    let category: String
    let scopeID: String
    let reasonCode: String
    let reasonText: String
    let matchedValue: String?
    let sourcePath: String
    let associatedBundleIdentifier: String?
    let lastModifiedAt: Date?
    let restrictionReason: String?
    let impactLevel: String
    let impactText: String
    let recoverability: String
    let ruleVersion: String

    init(_ value: CandidateEvidence) {
        switch value.category {
        case .cleanup(let locationID): category = "cleanup:\(locationID)"
        case .applicationBundle: category = "applicationBundle"
        case .residue(let kind): category = "residue:\(kind.rawValue)"
        case .association(let kind): category = "association:\(kind.rawValue)"
        }
        scopeID = value.origin.scopeID
        reasonCode = value.reasonCode.rawValue
        reasonText = value.reasonText
        matchedValue = value.origin.matchedValue
        sourcePath = value.sourcePath
        associatedBundleIdentifier = value.associatedBundleIdentifier
        lastModifiedAt = value.lastModifiedAt
        restrictionReason = value.restrictionReason?.rawValue
        impactLevel = value.impactLevel.rawValue
        impactText = value.impactText
        recoverability = value.recoverability.rawValue
        ruleVersion = value.ruleVersion
    }
}

struct OperationHistoryParentApplicationSnapshot: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let bundleIdentifier: String

    init(_ value: OperationPlanParentApplication) {
        id = value.id
        name = value.name
        path = value.path
        bundleIdentifier = value.bundleIdentifier
    }
}

struct OperationHistoryPlanItemSnapshot: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let state: String
    let category: OperationHistoryItemCategorySnapshot
    let order: Int
    let identity: OperationHistoryIdentitySnapshot
    let evidence: OperationHistoryEvidenceSnapshot
    let estimatedBytes: Int64
    let parentApplication: OperationHistoryParentApplicationSnapshot?
    let safetyBoundary: String

    init(_ value: OperationPlanItem) {
        id = value.id
        state = value.state.rawValue
        category = OperationHistoryItemCategorySnapshot(value.category)
        order = value.order
        identity = OperationHistoryIdentitySnapshot(value.identity)
        evidence = OperationHistoryEvidenceSnapshot(value.evidence)
        estimatedBytes = value.estimatedBytes
        parentApplication = value.parentApplication.map(OperationHistoryParentApplicationSnapshot.init)
        safetyBoundary = value.safetyBoundary.rawValue
    }
}

struct OperationHistoryScanContextSnapshot: Codable, Hashable, Sendable {
    let id: UUID
    let startedAt: Date
    let ruleVersion: String

    init(_ value: OperationPlanScanContextSnapshot) {
        id = value.id
        startedAt = value.startedAt
        ruleVersion = value.ruleVersion
    }
}

struct OperationHistoryCoverageSnapshot: Codable, Hashable, Sendable {
    let contextID: UUID
    let contextStartedAt: Date
    let ruleVersion: String
    let scopeID: String
    let scanner: String
    let phase: String
    let rootPath: String
    let targetPath: String?
    let status: String
    let issueCount: Int
    let accessIssueCount: Int
    let retainedIssueSampleCount: Int
    let omittedIssueCount: Int

    init(_ value: OperationPlanCoverageRecord) {
        contextID = value.contextID
        contextStartedAt = value.contextStartedAt
        ruleVersion = value.ruleVersion
        scopeID = value.scopeID
        scanner = value.scanner.rawValue
        phase = value.phase.rawValue
        rootPath = value.rootPath
        targetPath = value.targetPath
        status = value.status.rawValue
        issueCount = value.issueCount
        accessIssueCount = value.accessIssueCount
        retainedIssueSampleCount = value.retainedIssueSampleCount
        omittedIssueCount = value.omittedIssueCount
    }
}

struct OperationHistoryPlanSnapshot: Codable, Hashable, Sendable {
    let id: UUID
    let state: String
    let domain: String
    let createdAt: Date
    let frozenAt: Date
    let sourceScanContexts: [OperationHistoryScanContextSnapshot]
    let coverageRecords: [OperationHistoryCoverageSnapshot]
    let items: [OperationHistoryPlanItemSnapshot]
    let estimatedBytes: Int64
    let warnings: [String]

    init(_ value: OperationPlan) {
        id = value.id
        state = value.state.rawValue
        domain = value.domain.rawValue
        createdAt = value.createdAt
        frozenAt = value.frozenAt
        sourceScanContexts = value.sourceScanContexts.map(OperationHistoryScanContextSnapshot.init)
        coverageRecords = value.coverageSummary.records.map(OperationHistoryCoverageSnapshot.init)
        items = value.items.map(OperationHistoryPlanItemSnapshot.init)
        estimatedBytes = value.estimatedBytes
        warnings = value.warnings.map(\.rawValue)
    }
}

struct OperationHistoryReceiptItemSnapshot: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let order: Int
    let originalPath: String
    let category: OperationHistoryItemCategorySnapshot
    let estimatedBytes: Int64
    let status: String
    let reasonCode: String
    let reasonText: String
    let actualBytes: Int64

    init(_ value: ExecutionReceiptItem) {
        id = value.id
        order = value.order
        originalPath = value.originalPath
        category = OperationHistoryItemCategorySnapshot(value.category)
        estimatedBytes = value.estimatedBytes
        status = value.status.rawValue
        reasonCode = value.reasonCode.rawValue
        reasonText = value.reasonText
        actualBytes = value.actualBytes
    }
}

struct OperationHistoryReceiptSnapshot: Codable, Hashable, Sendable {
    let id: UUID
    let planID: UUID
    let domain: String
    let startedAt: Date
    let completedAt: Date
    let expectedItemCount: Int
    let expectedBytes: Int64
    let succeededCount: Int
    let succeededBytes: Int64
    let wasUserAborted: Bool
    let items: [OperationHistoryReceiptItemSnapshot]
    let warnings: [String]

    init(_ value: ExecutionReceipt) {
        id = value.id
        planID = value.planID
        domain = value.domain.rawValue
        startedAt = value.startedAt
        completedAt = value.completedAt
        expectedItemCount = value.expectedItemCount
        expectedBytes = value.expectedBytes
        succeededCount = value.succeededCount
        succeededBytes = value.succeededBytes
        wasUserAborted = value.wasUserAborted
        items = value.items.map(OperationHistoryReceiptItemSnapshot.init)
        warnings = value.warnings.map(\.rawValue)
    }

    func receiptForReadOnlyDisplay() -> ExecutionReceipt? {
        guard let domain = OperationPlanDomain(rawValue: domain) else { return nil }
        let receiptItems = items.compactMap { item -> ExecutionReceiptItem? in
            guard let category = item.category.receiptCategory,
                  let status = ExecutionReceiptItemStatus(rawValue: item.status),
                  let reasonCode = ExecutionResultReasonCode(rawValue: item.reasonCode) else { return nil }
            return ExecutionReceiptItem(
                id: item.id,
                order: item.order,
                originalPath: item.originalPath,
                category: category,
                estimatedBytes: item.estimatedBytes,
                status: status,
                reasonCode: reasonCode,
                reasonText: item.reasonText,
                actualBytes: item.actualBytes
            )
        }
        guard receiptItems.count == items.count else { return nil }
        let decodedWarnings = warnings.compactMap(ExecutionReceiptWarning.init(rawValue:))
        guard decodedWarnings.count == warnings.count else { return nil }
        return ExecutionReceipt(
            id: id,
            planID: planID,
            domain: domain,
            startedAt: startedAt,
            completedAt: completedAt,
            expectedItemCount: expectedItemCount,
            expectedBytes: expectedBytes,
            succeededCount: succeededCount,
            succeededBytes: succeededBytes,
            wasUserAborted: wasUserAborted,
            items: receiptItems,
            warnings: decodedWarnings
        )
    }
}

struct OperationHistoryRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let planID: UUID?
    let receiptID: UUID?
    let domain: String
    let completedAt: Date
    let summary: OperationHistorySummarySnapshot
    let detailAvailability: OperationHistoryDetailAvailability
    let detailMessage: String?
    let plan: OperationHistoryPlanSnapshot?
    let receipt: OperationHistoryReceiptSnapshot?

    var operationDomain: OperationPlanDomain? { OperationPlanDomain(rawValue: domain) }

    static func completed(plan: OperationPlan, receipt: ExecutionReceipt, title: String) throws -> Self {
        guard plan.id == receipt.planID, plan.domain == receipt.domain else {
            throw OperationHistoryStoreError.snapshotMismatch
        }
        return Self(
            id: UUID(),
            planID: plan.id,
            receiptID: receipt.id,
            domain: plan.domain.rawValue,
            completedAt: receipt.completedAt,
            summary: OperationHistorySummarySnapshot(
                title: title,
                statusCounts: OperationHistoryStatusCounts(receipt: receipt),
                actualSucceededBytes: receipt.succeededBytes,
                wasUserAborted: receipt.wasUserAborted
            ),
            detailAvailability: .complete,
            detailMessage: nil,
            plan: OperationHistoryPlanSnapshot(plan),
            receipt: OperationHistoryReceiptSnapshot(receipt)
        )
    }

    static func receiptUnavailable(
        plan: OperationPlan,
        resultSet: ExecutionResultSet,
        title: String,
        error: String,
        succeededBytes: Int64
    ) -> Self {
        Self(
            id: UUID(),
            planID: plan.id,
            receiptID: nil,
            domain: plan.domain.rawValue,
            completedAt: resultSet.completedAt,
            summary: OperationHistorySummarySnapshot(
                title: title,
                statusCounts: OperationHistoryStatusCounts(resultSet: resultSet),
                actualSucceededBytes: succeededBytes,
                wasUserAborted: resultSet.wasUserAborted
            ),
            detailAvailability: .receiptUnavailable,
            detailMessage: String(localized: "可信详情不可用：\(error)"),
            plan: nil,
            receipt: nil
        )
    }
}

struct OperationHistoryLoadOutcome: Sendable {
    let entries: [OperationHistoryRecord]
    let notices: [String]
}

protocol OperationHistoryReading: Sendable {
    func load() async throws -> OperationHistoryLoadOutcome
    func clear() async throws
}

struct OperationHistoryEnvelope: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    static let currentMigrationVersion = 1

    let schemaVersion: Int
    let legacyMigrationVersion: Int
    let migrationNotes: [String]
    let entries: [OperationHistoryRecord]
}

enum OperationHistoryStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unifiedFileCorrupt(String)
    case persistenceFailed(String)
    case snapshotMismatch
}

extension OperationHistoryStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return String(localized: "操作记录版本 \(version) 暂不受支持，未将其当作空记录处理。")
        case .unifiedFileCorrupt(let reason):
            return String(localized: "操作记录文件损坏或无法解码：\(reason)")
        case .persistenceFailed(let reason):
            return String(localized: "操作记录无法保存：\(reason)")
        case .snapshotMismatch:
            return String(localized: "冻结计划与执行收据不属于同一次操作，记录已拒绝保存。")
        }
    }
}

actor OperationHistoryStore: OperationHistoryReading {
    private let paths: OperationHistoryPaths
    private let maximumEntryCount: Int
    private let files: any OperationHistoryFileAccessing
    private var cachedEnvelope: OperationHistoryEnvelope?

    init(
        paths: OperationHistoryPaths = OperationHistoryPaths(),
        maximumEntryCount: Int = 50,
        files: any OperationHistoryFileAccessing = LocalOperationHistoryFileAccess()
    ) {
        self.paths = paths
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.files = files
    }

    func load() async throws -> OperationHistoryLoadOutcome {
        let envelope = try loadEnvelope()
        return OperationHistoryLoadOutcome(entries: envelope.entries, notices: envelope.migrationNotes)
    }

    func append(_ record: OperationHistoryRecord) async throws {
        let current = try loadEnvelope()
        let entries = Self.sortedAndLimited(current.entries + [record], limit: maximumEntryCount)
        let updated = OperationHistoryEnvelope(
            schemaVersion: OperationHistoryEnvelope.currentSchemaVersion,
            legacyMigrationVersion: current.legacyMigrationVersion,
            migrationNotes: current.migrationNotes,
            entries: entries
        )
        try persist(updated)
        cachedEnvelope = updated
    }

    func clear() async throws {
        let migrationVersion: Int
        if let cachedEnvelope {
            migrationVersion = cachedEnvelope.legacyMigrationVersion
        } else if let decoded = try? decodeUnifiedFile() {
            migrationVersion = decoded.legacyMigrationVersion
        } else {
            migrationVersion = OperationHistoryEnvelope.currentMigrationVersion
        }
        let empty = OperationHistoryEnvelope(
            schemaVersion: OperationHistoryEnvelope.currentSchemaVersion,
            legacyMigrationVersion: migrationVersion,
            migrationNotes: [String(localized: "操作记录已清空；旧版迁移标记已保留，旧版文件不会再次导入。")],
            entries: []
        )

        // Keep the previous unified envelope authoritative until every legacy summary has
        // been removed. If removal or the following atomic write fails, visible history
        // remains available from that envelope and the caller receives an explicit error.
        do {
            for legacyURL in [paths.legacyCleanupFileURL, paths.legacyUninstallFileURL]
            where files.fileExists(at: legacyURL) {
                try files.removeItem(at: legacyURL)
            }
        } catch {
            throw OperationHistoryStoreError.persistenceFailed(
                String(localized: "旧版操作记录未能删除；统一历史未改动：\(error.localizedDescription)")
            )
        }
        try persist(empty)
        cachedEnvelope = empty
    }

    private func loadEnvelope() throws -> OperationHistoryEnvelope {
        if let cachedEnvelope { return cachedEnvelope }
        if files.fileExists(at: paths.historyFileURL) {
            let decoded = try decodeUnifiedFile()
            cachedEnvelope = decoded
            return decoded
        }
        let migrated = try migrateLegacyFiles()
        try persist(migrated)
        cachedEnvelope = migrated
        return migrated
    }

    private func decodeUnifiedFile() throws -> OperationHistoryEnvelope {
        do {
            let decoded = try Self.makeDecoder().decode(
                OperationHistoryEnvelope.self,
                from: files.read(from: paths.historyFileURL)
            )
            guard decoded.schemaVersion == OperationHistoryEnvelope.currentSchemaVersion else {
                throw OperationHistoryStoreError.unsupportedSchemaVersion(decoded.schemaVersion)
            }
            return OperationHistoryEnvelope(
                schemaVersion: decoded.schemaVersion,
                legacyMigrationVersion: decoded.legacyMigrationVersion,
                migrationNotes: decoded.migrationNotes,
                entries: Self.sortedAndLimited(decoded.entries, limit: maximumEntryCount)
            )
        } catch let error as OperationHistoryStoreError {
            throw error
        } catch {
            throw OperationHistoryStoreError.unifiedFileCorrupt(error.localizedDescription)
        }
    }

    private func migrateLegacyFiles() throws -> OperationHistoryEnvelope {
        var records: [OperationHistoryRecord] = []
        var notes: [String] = []

        if files.fileExists(at: paths.legacyCleanupFileURL) {
            do {
                let entries = try Self.makeLegacyDecoder().decode(
                    [CleanupHistoryEntry].self,
                    from: files.read(from: paths.legacyCleanupFileURL)
                )
                records.append(contentsOf: entries.map(Self.legacyCleanupRecord))
                notes.append(String(localized: "已迁移 \(entries.count.formatted()) 条旧版清理摘要；逐项详情不可用。"))
            } catch {
                notes.append(String(localized: "旧版清理记录损坏或无法解码：\(error.localizedDescription)"))
            }
        }

        if files.fileExists(at: paths.legacyUninstallFileURL) {
            do {
                let entries = try Self.makeLegacyDecoder().decode(
                    [UninstallHistoryEntry].self,
                    from: files.read(from: paths.legacyUninstallFileURL)
                )
                records.append(contentsOf: entries.map(Self.legacyUninstallRecord))
                notes.append(String(localized: "已迁移 \(entries.count.formatted()) 条旧版卸载摘要；逐项详情不可用。"))
            } catch {
                notes.append(String(localized: "旧版卸载记录损坏或无法解码：\(error.localizedDescription)"))
            }
        }

        return OperationHistoryEnvelope(
            schemaVersion: OperationHistoryEnvelope.currentSchemaVersion,
            legacyMigrationVersion: OperationHistoryEnvelope.currentMigrationVersion,
            migrationNotes: notes,
            entries: Self.sortedAndLimited(records, limit: maximumEntryCount)
        )
    }

    private func persist(_ envelope: OperationHistoryEnvelope) throws {
        do {
            try files.createDirectory(at: paths.historyFileURL.deletingLastPathComponent())
            try files.writeAtomically(Self.makeEncoder().encode(envelope), to: paths.historyFileURL)
        } catch {
            throw OperationHistoryStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    private static func sortedAndLimited(
        _ records: [OperationHistoryRecord],
        limit: Int
    ) -> [OperationHistoryRecord] {
        Array(records.sorted(by: deterministicOrder).prefix(limit))
    }

    private static func deterministicOrder(_ lhs: OperationHistoryRecord, _ rhs: OperationHistoryRecord) -> Bool {
        if lhs.completedAt != rhs.completedAt { return lhs.completedAt > rhs.completedAt }
        if lhs.domain != rhs.domain { return lhs.domain < rhs.domain }
        let lhsPlan = lhs.planID?.uuidString ?? ""
        let rhsPlan = rhs.planID?.uuidString ?? ""
        if lhsPlan != rhsPlan { return lhsPlan < rhsPlan }
        let lhsReceipt = lhs.receiptID?.uuidString ?? ""
        let rhsReceipt = rhs.receiptID?.uuidString ?? ""
        if lhsReceipt != rhsReceipt { return lhsReceipt < rhsReceipt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func legacyCleanupRecord(_ entry: CleanupHistoryEntry) -> OperationHistoryRecord {
        OperationHistoryRecord(
            id: entry.id,
            planID: nil,
            receiptID: nil,
            domain: OperationPlanDomain.cleanup.rawValue,
            completedAt: entry.finishedAt,
            summary: OperationHistorySummarySnapshot(
                title: String(localized: "旧版磁盘清理"),
                statusCounts: OperationHistoryStatusCounts(
                    succeeded: entry.movedCount,
                    failed: entry.failedCount,
                    skipped: nil,
                    aborted: entry.cancelled ? 1 : 0,
                    notExecuted: nil
                ),
                actualSucceededBytes: entry.movedBytes,
                wasUserAborted: entry.cancelled
            ),
            detailAvailability: .legacySummaryOnly,
            detailMessage: String(localized: "旧版摘要，详情不可用。旧存储没有逐项计划或执行结果，因此没有补造路径、状态或收据。"),
            plan: nil,
            receipt: nil
        )
    }

    private static func legacyUninstallRecord(_ entry: UninstallHistoryEntry) -> OperationHistoryRecord {
        OperationHistoryRecord(
            id: entry.id,
            planID: nil,
            receiptID: nil,
            domain: OperationPlanDomain.uninstall.rawValue,
            completedAt: entry.finishedAt,
            summary: OperationHistorySummarySnapshot(
                title: entry.applicationName,
                statusCounts: OperationHistoryStatusCounts(
                    succeeded: (entry.applicationMoved ? 1 : 0) + entry.movedResidueCount,
                    failed: entry.failedCount,
                    skipped: nil,
                    aborted: entry.cancelled ? 1 : 0,
                    notExecuted: nil
                ),
                actualSucceededBytes: entry.movedBytes,
                wasUserAborted: entry.cancelled
            ),
            detailAvailability: .legacySummaryOnly,
            detailMessage: String(localized: "旧版摘要，详情不可用。旧存储没有逐项计划或执行结果，因此没有补造路径、状态或收据。"),
            plan: nil,
            receipt: nil
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let bits = try container.decode(UInt64.self)
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        }
        return decoder
    }

    private static func makeLegacyDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct CleanupOperationHistoryAdapter: CleanupHistoryStoring {
    let store: OperationHistoryStore

    func load() async -> [CleanupHistoryEntry] { [] }

    func append(_ entry: CleanupHistoryEntry) async throws {
        throw OperationHistoryStoreError.snapshotMismatch
    }

    func append(
        _ entry: CleanupHistoryEntry,
        plan: OperationPlan,
        receipt: ExecutionReceipt?,
        receiptError: String?,
        resultSet: ExecutionResultSet
    ) async throws {
        let record: OperationHistoryRecord
        if let receipt {
            record = try .completed(plan: plan, receipt: receipt, title: String(localized: "磁盘清理"))
        } else {
            record = .receiptUnavailable(
                plan: plan,
                resultSet: resultSet,
                title: String(localized: "磁盘清理"),
                error: receiptError ?? String(localized: "收据构建失败"),
                succeededBytes: entry.movedBytes
            )
        }
        try await store.append(record)
    }
}

struct UninstallOperationHistoryAdapter: UninstallHistoryStoring {
    let store: OperationHistoryStore

    func load() async -> [UninstallHistoryEntry] { [] }

    func append(_ entry: UninstallHistoryEntry) async throws {
        throw OperationHistoryStoreError.snapshotMismatch
    }

    func append(
        _ entry: UninstallHistoryEntry,
        plan: OperationPlan,
        receipt: ExecutionReceipt?,
        receiptError: String?,
        resultSet: ExecutionResultSet
    ) async throws {
        let record: OperationHistoryRecord
        if let receipt {
            record = try .completed(plan: plan, receipt: receipt, title: entry.applicationName)
        } else {
            record = .receiptUnavailable(
                plan: plan,
                resultSet: resultSet,
                title: entry.applicationName,
                error: receiptError ?? String(localized: "收据构建失败"),
                succeededBytes: entry.movedBytes
            )
        }
        try await store.append(record)
    }
}
