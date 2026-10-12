import Foundation

protocol UninstallHistoryStoring: Sendable {
    func load() async -> [UninstallHistoryEntry]
    func append(_ entry: UninstallHistoryEntry) async throws
    func append(
        _ entry: UninstallHistoryEntry,
        plan: OperationPlan,
        receipt: ExecutionReceipt?,
        receiptError: String?,
        resultSet: ExecutionResultSet
    ) async throws
}

extension UninstallHistoryStoring {
    func append(
        _ entry: UninstallHistoryEntry,
        plan: OperationPlan,
        receipt: ExecutionReceipt?,
        receiptError: String?,
        resultSet: ExecutionResultSet
    ) async throws {
        try await append(entry)
    }
}

actor UninstallHistoryStore: UninstallHistoryStoring {
    private let fileURL: URL
    private let maximumEntryCount: Int

    init(baseDirectory: URL? = nil, maximumEntryCount: Int = 50) {
        let directory = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "SinClean", directoryHint: .isDirectory)
        fileURL = directory.appending(path: "uninstall-history.json")
        self.maximumEntryCount = maximumEntryCount
    }

    func load() async -> [UninstallHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UninstallHistoryEntry].self, from: data)) ?? []
    }

    func append(_ entry: UninstallHistoryEntry) async throws {
        var entries = await load()
        entries.insert(entry, at: 0)
        if entries.count > maximumEntryCount {
            entries.removeLast(entries.count - maximumEntryCount)
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}
