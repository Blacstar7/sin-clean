import Foundation

enum IgnoreRuleSchema {
    static let current = 1
}

enum IgnoreRuleGroup: String, CaseIterable, Codable, Sendable {
    case candidate
    case fixedPath
    case application

    var title: String {
        switch self {
        case .candidate: String(localized: "候选")
        case .fixedPath: String(localized: "固定路径")
        case .application: String(localized: "应用")
        }
    }
}

enum IgnoreRuleKind: Hashable, Sendable {
    case cleanupCandidate(locationID: String, path: String)
    case residueCandidate(bundleIdentifier: String, residueKind: AppResidueKind, path: String)
    case fixedPath(path: String)
    case applicationBundleIdentifier(String)
    case applicationPath(path: String)

    var group: IgnoreRuleGroup {
        switch self {
        case .cleanupCandidate, .residueCandidate: .candidate
        case .fixedPath: .fixedPath
        case .applicationBundleIdentifier, .applicationPath: .application
        }
    }

    var typeTitle: String {
        switch self {
        case .cleanupCandidate: String(localized: "清理候选")
        case .residueCandidate: String(localized: "卸载残留候选")
        case .fixedPath: String(localized: "精确固定路径")
        case .applicationBundleIdentifier: String(localized: "精确应用标识符")
        case .applicationPath: String(localized: "精确应用路径")
        }
    }

    var exactMatchDescription: String {
        switch self {
        case .cleanupCandidate(let locationID, let path):
            String(localized: "位置标识：\(locationID)\n路径：\(path)")
        case .residueCandidate(let bundleIdentifier, let residueKind, let path):
            String(localized: "Bundle Identifier：\(bundleIdentifier)\n残留类别：\(residueKind.localizedDisplayName)\n路径：\(path)")
        case .fixedPath(let path), .applicationPath(let path):
            path
        case .applicationBundleIdentifier(let bundleIdentifier):
            bundleIdentifier
        }
    }
}

extension IgnoreRuleKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, locationID, path, bundleIdentifier, residueKind
    }

    private enum KindTag: String, Codable {
        case cleanupCandidate, residueCandidate, fixedPath, applicationBundleIdentifier, applicationPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(KindTag.self, forKey: .type) {
        case .cleanupCandidate:
            self = .cleanupCandidate(
                locationID: try container.decode(String.self, forKey: .locationID),
                path: try container.decode(String.self, forKey: .path)
            )
        case .residueCandidate:
            self = .residueCandidate(
                bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
                residueKind: try container.decode(AppResidueKind.self, forKey: .residueKind),
                path: try container.decode(String.self, forKey: .path)
            )
        case .fixedPath:
            self = .fixedPath(path: try container.decode(String.self, forKey: .path))
        case .applicationBundleIdentifier:
            self = .applicationBundleIdentifier(try container.decode(String.self, forKey: .bundleIdentifier))
        case .applicationPath:
            self = .applicationPath(path: try container.decode(String.self, forKey: .path))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cleanupCandidate(let locationID, let path):
            try container.encode(KindTag.cleanupCandidate, forKey: .type)
            try container.encode(locationID, forKey: .locationID)
            try container.encode(path, forKey: .path)
        case .residueCandidate(let bundleIdentifier, let residueKind, let path):
            try container.encode(KindTag.residueCandidate, forKey: .type)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
            try container.encode(residueKind, forKey: .residueKind)
            try container.encode(path, forKey: .path)
        case .fixedPath(let path):
            try container.encode(KindTag.fixedPath, forKey: .type)
            try container.encode(path, forKey: .path)
        case .applicationBundleIdentifier(let bundleIdentifier):
            try container.encode(KindTag.applicationBundleIdentifier, forKey: .type)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        case .applicationPath(let path):
            try container.encode(KindTag.applicationPath, forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}

struct IgnoreRule: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let schemaVersion: Int
    let kind: IgnoreRuleKind
    let displayName: String
    let originalPath: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        schemaVersion: Int = IgnoreRuleSchema.current,
        kind: IgnoreRuleKind,
        displayName: String,
        originalPath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.displayName = displayName
        self.originalPath = originalPath
        self.createdAt = createdAt
    }

    static func cleanupCandidate(_ candidate: CleanupFileCandidate) -> IgnoreRule {
        IgnoreRule(
            kind: .cleanupCandidate(
                locationID: candidate.locationID,
                path: IgnorePath.normalized(candidate.path)
            ),
            displayName: URL(fileURLWithPath: candidate.path).lastPathComponent,
            originalPath: candidate.path
        )
    }

    static func residueCandidate(_ candidate: AppResidueCandidate) -> IgnoreRule {
        IgnoreRule(
            kind: .residueCandidate(
                bundleIdentifier: candidate.bundleIdentifier,
                residueKind: candidate.kind,
                path: IgnorePath.normalized(candidate.path)
            ),
            displayName: "\(candidate.kind.localizedDisplayName) · \(URL(fileURLWithPath: candidate.path).lastPathComponent)",
            originalPath: candidate.path
        )
    }

    static func fixedPath(_ path: String, displayName: String? = nil) -> IgnoreRule {
        IgnoreRule(
            kind: .fixedPath(path: IgnorePath.normalized(path)),
            displayName: displayName ?? URL(fileURLWithPath: path).lastPathComponent,
            originalPath: path
        )
    }

    static func application(_ application: InstalledApplication) -> IgnoreRule {
        let kind: IgnoreRuleKind
        if let bundleIdentifier = application.bundleIdentifier,
           ScanRules.bundleIdentifierRestriction(bundleIdentifier) == nil {
            kind = .applicationBundleIdentifier(bundleIdentifier)
        } else {
            kind = .applicationPath(path: IgnorePath.normalized(application.path))
        }
        return IgnoreRule(
            kind: kind,
            displayName: application.name,
            originalPath: application.path
        )
    }

    func matches(_ candidate: CleanupFileCandidate) -> Bool {
        let path = IgnorePath.normalized(candidate.path)
        switch kind {
        case .cleanupCandidate(let locationID, let exactPath):
            return candidate.locationID == locationID && path == exactPath
        case .fixedPath(let exactPath):
            return path == exactPath
        default:
            return false
        }
    }

    func matches(_ candidate: AppResidueCandidate) -> Bool {
        let path = IgnorePath.normalized(candidate.path)
        switch kind {
        case .residueCandidate(let bundleIdentifier, let residueKind, let exactPath):
            return candidate.bundleIdentifier == bundleIdentifier
                && candidate.kind == residueKind
                && path == exactPath
        case .fixedPath(let exactPath):
            return path == exactPath
        default:
            return false
        }
    }

    func matches(_ application: InstalledApplication) -> Bool {
        switch kind {
        case .applicationBundleIdentifier(let exactBundleIdentifier):
            guard ScanRules.bundleIdentifierRestriction(application.bundleIdentifier) == nil else { return false }
            return application.bundleIdentifier == exactBundleIdentifier
        case .applicationPath(let exactPath), .fixedPath(let exactPath):
            return IgnorePath.normalized(application.path) == exactPath
        default:
            return false
        }
    }

    var isStructurallyValid: Bool {
        guard schemaVersion == IgnoreRuleSchema.current,
              !displayName.isEmpty,
              originalPath.hasPrefix("/") else { return false }
        switch kind {
        case .cleanupCandidate(let locationID, let path):
            return !locationID.isEmpty && path.hasPrefix("/") && path == IgnorePath.normalized(path)
        case .residueCandidate(let bundleIdentifier, _, let path):
            return ScanRules.bundleIdentifierRestriction(bundleIdentifier) == nil
                && path.hasPrefix("/") && path == IgnorePath.normalized(path)
        case .fixedPath(let path), .applicationPath(let path):
            return path.hasPrefix("/") && path == IgnorePath.normalized(path)
        case .applicationBundleIdentifier(let bundleIdentifier):
            return ScanRules.bundleIdentifierRestriction(bundleIdentifier) == nil
        }
    }
}

enum IgnorePath {
    /// Syntactic standardization only. This deliberately does not resolve symbolic links.
    static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

struct IgnoreRuleDocument: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let rules: [IgnoreRule]

    init(schemaVersion: Int = IgnoreRuleSchema.current, rules: [IgnoreRule]) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }
}

enum IgnoreRuleRepositoryError: LocalizedError, Sendable {
    case unknownSchema(Int)
    case unknownRuleSchema(UUID, Int)
    case invalidRule(UUID)
    case unavailable
    case mutationInProgress

    var errorDescription: String? {
        switch self {
        case .unknownSchema(let version):
            String(localized: "忽略列表使用未知的数据版本（\(version)）。原文件已保留，请升级应用或手动备份后处理。")
        case .unknownRuleSchema(let id, let version):
            String(localized: "忽略规则 \(id.uuidString) 使用未知版本（\(version)）。原文件已保留。")
        case .invalidRule(let id):
            String(localized: "忽略规则 \(id.uuidString) 的精确匹配键无效。原文件已保留。")
        case .unavailable:
            String(localized: "忽略列表尚未成功加载；为避免遗漏规则，当前不能修改列表或执行清理。")
        case .mutationInProgress:
            String(localized: "另一项忽略列表变更仍在保存，请稍后重试。")
        }
    }
}

protocol IgnoreRuleRepository: Sendable {
    func load() async throws -> IgnoreRuleDocument
    func save(_ document: IgnoreRuleDocument) async throws
}

actor FileIgnoreRuleRepository: IgnoreRuleRepository {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = support
                .appending(path: "Sin Clean", directoryHint: .isDirectory)
                .appending(path: "ignore-rules.json", directoryHint: .notDirectory)
        }
    }

    func load() throws -> IgnoreRuleDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return IgnoreRuleDocument(rules: [])
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let probe = try decoder.decode(SchemaProbe.self, from: data)
        guard probe.schemaVersion == IgnoreRuleSchema.current else {
            throw IgnoreRuleRepositoryError.unknownSchema(probe.schemaVersion)
        }
        let document = try decoder.decode(IgnoreRuleDocument.self, from: data)
        try Self.validate(document)
        return document
    }

    func save(_ document: IgnoreRuleDocument) throws {
        try Self.validate(document)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func validate(_ document: IgnoreRuleDocument) throws {
        guard document.schemaVersion == IgnoreRuleSchema.current else {
            throw IgnoreRuleRepositoryError.unknownSchema(document.schemaVersion)
        }
        for rule in document.rules {
            guard rule.schemaVersion == IgnoreRuleSchema.current else {
                throw IgnoreRuleRepositoryError.unknownRuleSchema(rule.id, rule.schemaVersion)
            }
            guard rule.isStructurallyValid else {
                throw IgnoreRuleRepositoryError.invalidRule(rule.id)
            }
        }
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }
}

actor InMemoryIgnoreRuleRepository: IgnoreRuleRepository {
    private var document: IgnoreRuleDocument

    init(rules: [IgnoreRule] = []) {
        document = IgnoreRuleDocument(rules: rules)
    }

    func load() -> IgnoreRuleDocument { document }
    func save(_ document: IgnoreRuleDocument) { self.document = document }
}

enum IgnoreListLoadState: Equatable, Sendable {
    case loading
    case ready
    case failed(String)
}

@MainActor
final class IgnoreListStore: ObservableObject {
    @Published private(set) var rules: [IgnoreRule]
    @Published private(set) var loadState: IgnoreListLoadState
    @Published private(set) var persistenceError: String?
    @Published private(set) var isMutating = false

    private let repository: any IgnoreRuleRepository

    var isOperational: Bool { loadState == .ready && !isMutating }

    init(
        repository: any IgnoreRuleRepository = FileIgnoreRuleRepository(),
        initialRules: [IgnoreRule] = [],
        autoload: Bool = true
    ) {
        self.repository = repository
        rules = initialRules.sorted { $0.createdAt > $1.createdAt }
        loadState = autoload ? .loading : .ready
        if autoload {
            Task { [weak self] in await self?.reload() }
        }
    }

    func reload() async {
        loadState = .loading
        do {
            let document = try await repository.load()
            guard !Task.isCancelled else { return }
            rules = document.rules.sorted { $0.createdAt > $1.createdAt }
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func add(_ rule: IgnoreRule) async throws -> IgnoreRule {
        try requireMutationReady()
        if let existing = rules.first(where: { $0.kind == rule.kind }) {
            return existing
        }
        let updated = (rules + [rule]).sorted { $0.createdAt > $1.createdAt }
        try await persist(updated)
        return rule
    }

    func remove(id: UUID) async throws {
        try requireMutationReady()
        let updated = rules.filter { $0.id != id }
        guard updated.count != rules.count else { return }
        try await persist(updated)
    }

    func clearAll() async throws {
        try requireMutationReady()
        guard !rules.isEmpty else { return }
        try await persist([])
    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    func isIgnored(_ candidate: CleanupFileCandidate) -> Bool {
        rules.contains { $0.matches(candidate) }
    }

    func isIgnored(_ candidate: AppResidueCandidate) -> Bool {
        rules.contains { $0.matches(candidate) }
    }

    func isIgnored(_ application: InstalledApplication) -> Bool {
        rules.contains { $0.matches(application) }
    }

    private func persist(_ updated: [IgnoreRule]) async throws {
        isMutating = true
        defer { isMutating = false }
        do {
            try await repository.save(IgnoreRuleDocument(rules: updated))
            rules = updated
            persistenceError = nil
        } catch {
            persistenceError = String(localized: "忽略列表未能保存：\(error.localizedDescription) 当前规则未改变。")
            throw error
        }
    }

    private func requireMutationReady() throws {
        let error: IgnoreRuleRepositoryError
        if loadState != .ready {
            error = .unavailable
        } else if isMutating {
            error = .mutationInProgress
        } else {
            return
        }
        persistenceError = error.localizedDescription
        throw error
    }
}
