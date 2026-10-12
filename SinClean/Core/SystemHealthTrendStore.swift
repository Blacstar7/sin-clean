import Foundation

// SC-4 趋势与本地存储（§5）。
//
// 边界（work/SC-4-frozen-semantics.md B3/B4）：
// - 只写入应用自身的 Application Support 目录，字段只有时间戳与数值；
// - 零网络：不引入任何网络请求；
// - 「清空」按**空文档重写**实现：本轮不得新增任何永久删除调用
//   （SC-3.5 历史门禁要求全工程永久删除调用点唯一），因此清除的是**数据**而不是文件本身。
//   可验证口径：清空前采样点数 N > 0，清空后采样点数为 0，且不残留任何临时副本。

struct SystemHealthTrendPoint: Codable, Equatable, Sendable {
    let timestamp: Date
    let value: Double
}

struct SystemHealthTrends: Equatable, Sendable, Codable {
    var formatVersion: Int
    var cpu: [SystemHealthTrendPoint]
    var memoryPressure: [SystemHealthTrendPoint]
    var network: [SystemHealthTrendPoint]
    var disk: [SystemHealthTrendPoint]

    static let currentFormatVersion = 1

    static let empty = SystemHealthTrends(
        formatVersion: currentFormatVersion,
        cpu: [],
        memoryPressure: [],
        network: [],
        disk: []
    )

    var totalPointCount: Int {
        cpu.count + memoryPressure.count + network.count + disk.count
    }

    var isEmpty: Bool { totalPointCount == 0 }

    var lastDiskTimestamp: Date? { disk.last?.timestamp }

    /// 裁剪：短期限长 60 点；磁盘趋势最多 30 天。
    func trimmed(now: Date) -> SystemHealthTrends {
        let limit = SystemHealthSemantics.shortTermSampleLimit
        let cutoff = now.addingTimeInterval(-Double(SystemHealthSemantics.diskTrendRetentionDays) * 86_400)
        return SystemHealthTrends(
            formatVersion: Self.currentFormatVersion,
            cpu: Array(cpu.suffix(limit)),
            memoryPressure: Array(memoryPressure.suffix(limit)),
            network: Array(network.suffix(limit)),
            disk: disk.filter { $0.timestamp >= cutoff }
        )
    }

    /// 数据不足（点数 < 3）时不得绘制趋势、不得预测。
    func hasEnoughPoints(for series: SystemHealthTrendSeries) -> Bool {
        points(for: series).count >= SystemHealthSemantics.trendMinimumPoints
    }

    func points(for series: SystemHealthTrendSeries) -> [SystemHealthTrendPoint] {
        switch series {
        case .cpu: cpu
        case .memoryPressure: memoryPressure
        case .network: network
        case .disk: disk
        }
    }

    /// 记录一次采样：短期序列每点都记，磁盘容量按低频间隔记。
    func recording(_ sample: SystemHealthSample) -> SystemHealthTrends {
        var copy = self
        copy.cpu.append(SystemHealthTrendPoint(timestamp: sample.capturedAt, value: sample.cpuLoad))
        copy.memoryPressure.append(SystemHealthTrendPoint(
            timestamp: sample.capturedAt,
            value: sample.memoryPressure.numericValue
        ))
        copy.network.append(SystemHealthTrendPoint(
            timestamp: sample.capturedAt,
            value: sample.network.downloadBytesPerSecond + sample.network.uploadBytesPerSecond
        ))
        if let last = copy.disk.last {
            if sample.capturedAt.timeIntervalSince(last.timestamp) >= SystemHealthSemantics.diskTrendIntervalSeconds {
                copy.disk.append(SystemHealthTrendPoint(
                    timestamp: sample.capturedAt,
                    value: Double(sample.volumeFreeBytes)
                ))
            }
        } else {
            copy.disk.append(SystemHealthTrendPoint(
                timestamp: sample.capturedAt,
                value: Double(sample.volumeFreeBytes)
            ))
        }
        return copy.trimmed(now: sample.capturedAt)
    }
}

enum SystemHealthTrendSeries: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memoryPressure
    case network
    case disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: String(localized: "CPU 负载趋势")
        case .memoryPressure: String(localized: "内存压力趋势")
        case .network: String(localized: "网络吞吐趋势")
        case .disk: String(localized: "磁盘可用容量趋势")
        }
    }

    var unitNote: String {
        switch self {
        case .cpu: String(localized: "最近 5 分钟，纵轴为负载比例")
        case .memoryPressure: String(localized: "最近 5 分钟，纵轴为压力档位")
        case .network: String(localized: "最近 5 分钟，纵轴为每秒字节数")
        case .disk: String(localized: "最多 30 天，低频采样")
        }
    }
}

extension MemoryPressureLevel {
    var numericValue: Double {
        switch self {
        case .normal: 1
        case .warning: 2
        case .critical: 4
        case .unavailable: 0
        }
    }
}

// MARK: - 文档访问抽象（可注入，便于夹具验证「写了什么、清空成什么」）

protocol SystemHealthDocumentAccessing: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    var locationDescription: String { get }
}

struct FileSystemHealthDocumentAccess: SystemHealthDocumentAccessing {
    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            self.directoryURL = base
                .appending(path: "SinClean", directoryHint: .isDirectory)
                .appending(path: "system-health", directoryHint: .isDirectory)
        }
    }

    var locationDescription: String { directoryURL.path }

    private var documentURL: URL {
        directoryURL.appending(path: "trends.json")
    }

    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return nil }
        return try Data(contentsOf: documentURL)
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: documentURL, options: .atomic)
    }
}

/// 夹具与预览用：全部留在内存，可断言写入次数与最后一次写入的内容。
final class InMemorySystemHealthDocumentAccess: SystemHealthDocumentAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var document: Data?
    private var writeCount = 0

    init(document: Data? = nil) {
        self.document = document
    }

    var locationDescription: String { "memory://system-health/trends.json" }

    func read() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return document
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        document = data
        writeCount += 1
    }

    func writes() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return writeCount
    }

    func storedBytes() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return document?.count ?? 0
    }
}

// MARK: - 趋势存储

/// 趋势持久化失败的结构化错误（SC-4 R2：persist-then-commit）。
/// 只携带操作类别与失败原因，不包含文件路径、主机名等敏感内容。
struct SystemHealthTrendPersistenceError: Error, Equatable, Sendable {
    enum Operation: String, Sendable {
        case clear
        case record
    }

    enum Reason: String, Sendable {
        case encodeFailed
        case writeFailed
    }

    let operation: Operation
    let reason: Reason
}

actor SystemHealthTrendStore {
    private let access: any SystemHealthDocumentAccessing
    private var cached: SystemHealthTrends
    private var lastPersistFailure: SystemHealthTrendPersistenceError?

    init(access: any SystemHealthDocumentAccessing = FileSystemHealthDocumentAccess()) {
        self.access = access
        self.cached = Self.decode(access: access) ?? .empty
    }

    var storageLocation: String { access.locationDescription }

    func current() -> SystemHealthTrends { cached }

    /// 最近一次持久化失败的可观察状态；任一次持久化成功（record 或 clear）后清除。
    func currentPersistFailure() -> SystemHealthTrendPersistenceError? { lastPersistFailure }

    func record(_ sample: SystemHealthSample) {
        cached = cached.recording(sample)
        lastPersistFailure = persistDocument(cached, operation: .record)
    }

    /// 清空趋势数据：把文档重写为**零采样点**的空文档，并清空内存缓冲。
    /// SC-4 R2：persist-then-commit——只有空文档成功持久化后才提交内存空状态；
    /// 失败时抛出结构化错误，内存缓存保留清空前的真实数据。
    @discardableResult
    func clear() throws -> SystemHealthTrends {
        let empty = SystemHealthTrends.empty
        if let error = persistDocument(empty, operation: .clear) {
            throw error
        }
        cached = empty
        lastPersistFailure = nil
        return cached
    }

    /// 编码并写入文档；成功返回 nil，失败返回结构化错误（不吞掉）。
    private func persistDocument(
        _ document: SystemHealthTrends,
        operation: SystemHealthTrendPersistenceError.Operation
    ) -> SystemHealthTrendPersistenceError? {
        guard let data = try? JSONEncoder().encode(document) else {
            return SystemHealthTrendPersistenceError(operation: operation, reason: .encodeFailed)
        }
        do {
            try access.write(data)
            return nil
        } catch {
            return SystemHealthTrendPersistenceError(operation: operation, reason: .writeFailed)
        }
    }

    private static func decode(access: any SystemHealthDocumentAccessing) -> SystemHealthTrends? {
        guard let data = try? access.read() else { return nil }
        return try? JSONDecoder().decode(SystemHealthTrends.self, from: data)
    }
}
