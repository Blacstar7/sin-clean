import Combine
import CryptoKit
import Foundation

// SC-PD2 空间变化追踪：快照模型与本地历史存储。
// 冻结语义：work/SC-PD2-frozen-semantics.md（§1 schema、§2 盐、§3 指纹、§5 写入时点、
// §8 保留、§9 关闭/清除/损坏/迁移）。只读消费同一轮 SpaceAnalysisScanOutcome（经 PD1
// 诊断引擎派生七类别聚合）；唯一持久化＝应用自身 Application Support 下两个本地文件；
// 无网络、无后台扫描、无执行副作用；清除＝原子重写空内容，不做任何文件删除调用。

// MARK: - 版本与常量（冻结 §1.2／§8）

enum SpaceChangeSemantics {
    static let formatVersion = 1
    static let ruleVersion = "scpd1-v1"
    static let capacitySemanticsVersion = "sc33-34-v1"
    static let maxSnapshotCount = 30
    static let maxAgeSeconds: Double = 90 * 86_400
    static let saltHexLength = 64
    /// PD1 七类别 ID 固定顺序（SpaceAnalysisDiagnosisCategoryID.allCases 即字典序）。
    static let categoryIDOrder = SpaceAnalysisDiagnosisCategoryID.allCases.map(\.rawValue)
}

// MARK: - 快照模型（冻结 §1.3，字段即 §4 白名单）

struct SpaceChangeCategoryMeasurement: Codable, Hashable, Sendable {
    let id: String
    let bytes: Int64
    let entryCount: Int
}

struct SpaceChangeSnapshot: Codable, Hashable, Sendable {
    /// epoch 秒（亚秒精度）＝本轮扫描完成时间 summary.finishedAt（冻结 §1.3）。
    let createdAtEpochSeconds: Double
    let scopeFingerprint: String
    let ruleVersion: String
    let capacitySemanticsVersion: String
    let totalBytes: Int64
    /// 恒 7 条，按类别 ID 字典序固定排列；未出现类别以 0/0 占位（冻结 §1.3）。
    let categories: [SpaceChangeCategoryMeasurement]
    let coverageComplete: Bool
    let unreadableDirectoryCount: Int
    let capacityIsUpperBound: Bool
    let datalessPlaceholderCount: Int

    var createdAt: Date { Date(timeIntervalSince1970: createdAtEpochSeconds) }

    /// 去重戳（冻结 §5.5）。
    var dedupeStamp: String { "\(createdAtEpochSeconds)|\(scopeFingerprint)|\(totalBytes)" }

    enum CodingKeys: String, CodingKey {
        case createdAtEpochSeconds = "createdAt"
        case scopeFingerprint
        case ruleVersion
        case capacitySemanticsVersion
        case totalBytes
        case categories
        case coverageComplete
        case unreadableDirectoryCount
        case capacityIsUpperBound
        case datalessPlaceholderCount
    }

    init(
        createdAtEpochSeconds: Double,
        scopeFingerprint: String,
        ruleVersion: String,
        capacitySemanticsVersion: String,
        totalBytes: Int64,
        categories: [SpaceChangeCategoryMeasurement],
        coverageComplete: Bool,
        unreadableDirectoryCount: Int,
        capacityIsUpperBound: Bool,
        datalessPlaceholderCount: Int
    ) {
        self.createdAtEpochSeconds = createdAtEpochSeconds
        self.scopeFingerprint = scopeFingerprint
        self.ruleVersion = ruleVersion
        self.capacitySemanticsVersion = capacitySemanticsVersion
        self.totalBytes = totalBytes
        self.categories = categories
        self.coverageComplete = coverageComplete
        self.unreadableDirectoryCount = unreadableDirectoryCount
        self.capacityIsUpperBound = capacityIsUpperBound
        self.datalessPlaceholderCount = datalessPlaceholderCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAtEpochSeconds = try container.decode(Double.self, forKey: .createdAtEpochSeconds)
        scopeFingerprint = try container.decode(String.self, forKey: .scopeFingerprint)
        ruleVersion = try container.decode(String.self, forKey: .ruleVersion)
        capacitySemanticsVersion = try container.decode(String.self, forKey: .capacitySemanticsVersion)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        categories = try container.decode([SpaceChangeCategoryMeasurement].self, forKey: .categories)
        coverageComplete = try container.decode(Bool.self, forKey: .coverageComplete)
        unreadableDirectoryCount = try container.decode(Int.self, forKey: .unreadableDirectoryCount)
        capacityIsUpperBound = try container.decode(Bool.self, forKey: .capacityIsUpperBound)
        datalessPlaceholderCount = try container.decode(Int.self, forKey: .datalessPlaceholderCount)
    }
}

struct SpaceChangeHistoryDocument: Codable, Sendable {
    var formatVersion: Int
    var snapshots: [SpaceChangeSnapshot]
}

// MARK: - 注入面（文件访问／随机源／时钟；测试不得触碰真实用户记录）

protocol SpaceChangeFileAccessing: Sendable {
    func fileExists(at url: URL) -> Bool
    func readData(from url: URL) throws -> Data
    func createDirectoryIfNeeded(at url: URL) throws
    func writeAtomically(_ data: Data, to url: URL) throws
}

/// 本地文件访问：目录按需创建；写入用原子写（既有惯例 LocalOperationHistoryFileAccess 同源）。
/// 不提供任何文件删除接口——清除＝以空内容原子重写（冻结 §9.3）。
struct LocalSpaceChangeFileAccess: SpaceChangeFileAccessing {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func createDirectoryIfNeeded(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

protocol SpaceChangeRandomSource: Sendable {
    /// 32 字节随机源的十六进制小写编码（64 字符）；无法取得熵时返回 nil。
    func randomSaltHex(byteCount: Int) -> String?
}

/// 生产随机源：SystemRandomNumberGenerator（Apple 平台为密码学安全熵）。
struct SystemSpaceChangeRandomSource: SpaceChangeRandomSource {
    func randomSaltHex(byteCount: Int) -> String? {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        while bytes.count < byteCount {
            let value = generator.next()
            for shift in stride(from: 56, through: 0, by: -8) where bytes.count < byteCount {
                bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 存储位置（冻结 §1.1）

struct SpaceChangeStoragePaths: Sendable {
    let historyFileURL: URL
    let saltFileURL: URL

    init(baseDirectory: URL? = nil) {
        let directory = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "SinClean", directoryHint: .isDirectory)
        historyFileURL = directory.appending(path: "space-change-history.json")
        saltFileURL = directory.appending(path: "space-change-salt.txt")
    }
}

// MARK: - 存储态（冻结 §9.4／§9.6）

enum SpaceChangeStoreCondition: Equatable, Sendable {
    case ready
    case corrupt
    case migrationFailed
    case saltMissing
}

// MARK: - 历史存储（@MainActor；写成功后才更新内存状态）

@MainActor
final class SpaceChangeHistoryStore: ObservableObject {
    @Published private(set) var snapshots: [SpaceChangeSnapshot] = []
    @Published private(set) var condition: SpaceChangeStoreCondition = .ready
    /// 瞬态写入失败（冻结 §9.5）：值为失败那轮扫描的去重戳；随下一次成功记录清除。
    @Published private(set) var lastFailedStamp: String?

    /// 内存盐（含未落盘的候选盐）；只在 ready 态下参与指纹计算。
    private(set) var saltHex: String?
    private var saltPersisted = false
    /// 写失败轮的候选盐（修订 R1）：仅存内存、不落盘；供失败态判定（去重戳计算）与
    /// 下一轮记录复用同盐，避免盐漂移；重启后丢失（届时无已落盘历史，回到首次态）。
    private(set) var pendingSaltHex: String?
    /// 求值用盐：已加载盐优先，其次失败轮候选盐（冻结 §6.2.6 失败戳匹配所需）。
    var evaluationSaltHex: String? { saltHex ?? pendingSaltHex }

    private let fileAccess: any SpaceChangeFileAccessing
    private let randomSource: any SpaceChangeRandomSource
    private let clock: @Sendable () -> Date
    private let paths: SpaceChangeStoragePaths
    private var lastAttemptedStamp: String?

    init(
        fileAccess: any SpaceChangeFileAccessing = LocalSpaceChangeFileAccess(),
        randomSource: any SpaceChangeRandomSource = SystemSpaceChangeRandomSource(),
        paths: SpaceChangeStoragePaths = SpaceChangeStoragePaths(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileAccess = fileAccess
        self.randomSource = randomSource
        self.paths = paths
        self.clock = clock
        loadFromDisk()
    }

    var snapshotCount: Int { snapshots.count }

    // MARK: - 加载（冻结 §1.4／§2.4／§9.4）

    private func loadFromDisk() {
        var loadedSalt: String?
        if fileAccess.fileExists(at: paths.saltFileURL) {
            if let data = try? fileAccess.readData(from: paths.saltFileURL),
               let text = String(data: data, encoding: .utf8) {
                let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isValidHex(candidate, length: SpaceChangeSemantics.saltHexLength) {
                    loadedSalt = candidate
                }
            }
        }

        guard fileAccess.fileExists(at: paths.historyFileURL) else {
            // 无历史文件：首次使用态；盐（若存在）留作后续记录使用。
            saltHex = loadedSalt
            saltPersisted = loadedSalt != nil
            return
        }

        guard let data = try? fileAccess.readData(from: paths.historyFileURL) else {
            condition = .corrupt
            return
        }
        guard let document = try? JSONDecoder().decode(SpaceChangeHistoryDocument.self, from: data) else {
            condition = .corrupt
            return
        }
        guard document.formatVersion == SpaceChangeSemantics.formatVersion else {
            condition = .migrationFailed
            return
        }
        guard Self.areLoadedSnapshotsValid(document.snapshots) else {
            condition = .corrupt
            return
        }
        guard document.snapshots.isEmpty || loadedSalt != nil else {
            condition = .saltMissing
            return
        }
        snapshots = document.snapshots
        saltHex = loadedSalt
        saltPersisted = loadedSalt != nil
        condition = .ready
    }

    // MARK: - 记录（冻结 §5）

    /// 扫描完成事件的唯一入口：判定可记录条件并异步原子写入；写成功后才更新内存状态。
    /// 传入已派生的诊断报告时直接复用（视图事件路径已计算），nil 时自行派生（自包含）。
    func handleScanCompleted(
        outcome: SpaceAnalysisScanOutcome,
        report precomputedReport: SpaceAnalysisDiagnosisReport? = nil,
        recordingEnabled: Bool
    ) {
        guard condition == .ready else { return }
        guard recordingEnabled else { return }
        guard !outcome.summary.cancelled else { return }

        let report = precomputedReport ?? SpaceAnalysisDiagnosisEngine.diagnose(outcome: outcome)
        guard Self.isRecordableReportState(report.state) else { return }

        let roots = Self.scopeRoots(of: outcome)
        guard !roots.isEmpty else { return }

        // 盐：已加载、失败轮候选或现生成；生成失败则本轮记录失败（不落任何文件）。
        let effectiveSalt: String
        if let salt = saltHex ?? pendingSaltHex {
            effectiveSalt = salt
        } else if let generated = randomSource.randomSaltHex(byteCount: SpaceChangeSemantics.saltHexLength / 2) {
            effectiveSalt = generated
        } else {
            return
        }

        guard let fingerprint = SpaceChangeFingerprint.compute(normalizedScopes: roots, saltHex: effectiveSalt) else {
            return
        }
        guard let snapshot = SpaceChangeComparisonEngine.buildSnapshot(
            outcome: outcome,
            report: report,
            scopeFingerprint: fingerprint
        ) else { return }

        // 去重戳（冻结 §5.5）：同一扫描的重复发布不产生第二条快照。
        guard snapshot.dedupeStamp != lastAttemptedStamp,
              snapshot.dedupeStamp != snapshots.last?.dedupeStamp
        else { return }
        lastAttemptedStamp = snapshot.dedupeStamp

        let saltToPersist = saltPersisted ? nil : effectiveSalt
        let candidateSnapshots = Self.applyRetention(snapshots + [snapshot], now: clock())
        let saltURL = paths.saltFileURL
        let historyURL = paths.historyFileURL
        let directoryURL = historyURL.deletingLastPathComponent()
        let access = fileAccess

        Task.detached(priority: .utility) {
            do {
                try access.createDirectoryIfNeeded(at: directoryURL)
                // 顺序冻结 §2.3：先原子写盐，成功后才写历史——不会出现「有历史无盐」的中间态。
                if let saltToPersist {
                    try access.writeAtomically(Data((saltToPersist + "\n").utf8), to: saltURL)
                }
                let encoded = try Self.encodedDocument(candidateSnapshots)
                try access.writeAtomically(encoded, to: historyURL)
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastFailedStamp = snapshot.dedupeStamp
                    self?.pendingSaltHex = effectiveSalt
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.snapshots = candidateSnapshots
                self.saltHex = effectiveSalt
                self.saltPersisted = true
                self.pendingSaltHex = nil
                self.lastFailedStamp = nil
                self.condition = .ready
            }
        }
    }

    // MARK: - 清除（冻结 §9.3；二段确认由设置页 UI 承担）

    enum ClearResult: Equatable {
        case cleared
        case failed
    }

    /// 清除在任何存储态下可用（损坏/迁移失败的用户恢复路径）。
    func clear() -> ClearResult {
        let empty = SpaceChangeHistoryDocument(formatVersion: SpaceChangeSemantics.formatVersion, snapshots: [])
        guard let encoded = try? Self.encodedDocument(empty.snapshots) else { return .failed }
        do {
            try fileAccess.createDirectoryIfNeeded(at: paths.historyFileURL.deletingLastPathComponent())
            try fileAccess.writeAtomically(encoded, to: paths.historyFileURL)
        } catch {
            return .failed
        }
        snapshots = []
        condition = .ready
        lastFailedStamp = nil
        lastAttemptedStamp = nil
        pendingSaltHex = nil
        return .cleared
    }

    // MARK: - 纯函数（测试直接复用）

    nonisolated static func isRecordableReportState(_ state: SpaceAnalysisDiagnosisState) -> Bool {
        switch state {
        case .complete, .partial, .emptyResult: true
        case .noData, .inconsistent, .cancelled: false
        }
    }

    /// 深度为 0 的节点路径＝扫描器实际遍历根；词法规范化（幂等）后返回。
    nonisolated static func scopeRoots(of outcome: SpaceAnalysisScanOutcome) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for node in outcome.nodes where node.depth == 0 {
            let normalized = SpaceAnalysisScopeValidator.lexicallyNormalizedAbsolutePath(node.path)
            if seen.insert(normalized).inserted {
                roots.append(normalized)
            }
        }
        return roots
    }

    /// 保留规则（冻结 §8）：先删超过 90 天者（恰 90 天保留），再删超量最旧直至 30 条。
    nonisolated static func applyRetention(_ snapshots: [SpaceChangeSnapshot], now: Date) -> [SpaceChangeSnapshot] {
        let cutoff = now.timeIntervalSince1970
        var kept = snapshots.filter { cutoff - $0.createdAtEpochSeconds <= SpaceChangeSemantics.maxAgeSeconds }
        if kept.count > SpaceChangeSemantics.maxSnapshotCount {
            kept = Array(kept.suffix(SpaceChangeSemantics.maxSnapshotCount))
        }
        return kept
    }

    nonisolated static func encodedDocument(_ snapshots: [SpaceChangeSnapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let document = SpaceChangeHistoryDocument(
            formatVersion: SpaceChangeSemantics.formatVersion,
            snapshots: snapshots
        )
        return try encoder.encode(document)
    }

    nonisolated static func isValidHex(_ text: String, length: Int) -> Bool {
        text.count == length && text.allSatisfy { character in
            (character >= "0" && character <= "9") || (character >= "a" && character <= "f")
        }
    }

    /// 加载校验（冻结 §1.4）：结构、数值、记录内守恒与数组非降序。
    nonisolated static func areLoadedSnapshotsValid(_ snapshots: [SpaceChangeSnapshot]) -> Bool {
        var previousCreatedAt: Double?
        for snapshot in snapshots {
            guard snapshot.createdAtEpochSeconds.isFinite, snapshot.createdAtEpochSeconds >= 0 else { return false }
            guard isValidHex(snapshot.scopeFingerprint, length: SpaceChangeSemantics.saltHexLength) else { return false }
            guard !snapshot.ruleVersion.isEmpty, !snapshot.capacitySemanticsVersion.isEmpty else { return false }
            guard snapshot.totalBytes >= 0, snapshot.unreadableDirectoryCount >= 0 else { return false }
            guard snapshot.categories.count == SpaceChangeSemantics.categoryIDOrder.count else { return false }
            guard snapshot.categories.map(\.id) == SpaceChangeSemantics.categoryIDOrder else { return false }
            var total: Int64 = 0
            for category in snapshot.categories {
                guard category.bytes >= 0, category.entryCount >= 0 else { return false }
                let (sum, overflow) = total.addingReportingOverflow(category.bytes)
                guard !overflow else { return false }
                total = sum
            }
            guard total == snapshot.totalBytes else { return false }
            if let previousCreatedAt, snapshot.createdAtEpochSeconds < previousCreatedAt { return false }
            previousCreatedAt = snapshot.createdAtEpochSeconds
        }
        return true
    }
}
