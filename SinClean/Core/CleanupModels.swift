import Foundation

enum CleanupRisk: String, CaseIterable, Codable, Sendable {
    case safe = "安全清理"
    case review = "建议确认"
    case caution = "谨慎处理"
}

extension CleanupRisk {
    var localizedDisplayName: String {
        switch self {
        case .safe: String(localized: "安全清理")
        case .review: String(localized: "建议确认")
        case .caution: String(localized: "谨慎处理")
        }
    }
}

enum ScanMatchRule: Sendable {
    case allRegularFiles
    case fileExtensions(Set<String>)

    func matches(_ url: URL) -> Bool {
        switch self {
        case .allRegularFiles:
            return true
        case .fileExtensions(let extensions):
            return extensions.contains(url.pathExtension.lowercased())
        }
    }
}

struct ScanLocation: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let url: URL
    let risk: CleanupRisk
    let matchRule: ScanMatchRule
}

struct CleanupFileCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let locationID: String
    let rootPath: String
    let path: String
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let modifiedAt: Date?
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let deviceID: UInt64
    let inode: UInt64
    let risk: CleanupRisk
    let evidenceOrigin: CandidateEvidenceOrigin

    var evidence: CandidateEvidence {
        CandidateEvidence(category: .cleanup(locationID: locationID), origin: evidenceOrigin,
            sourcePath: path, associatedBundleIdentifier: nil,
            lastModifiedAt: CandidateEvidence.displayDate(seconds: modifiedSeconds, nanoseconds: modifiedNanoseconds),
            restrictionReason: nil)
    }
}

struct CleanupScanResult: Identifiable, ScanCoverageReporting {
    let id: String
    let name: String
    let description: String
    let sourcePath: String
    let risk: CleanupRisk
    let totalBytes: Int64
    let fileCount: Int
    let candidates: [CleanupFileCandidate]
    let coverage: [ScanCoverage]
    var accessIssues: [String] { coverage.flatMap(\.accessIssues) }

    var largestFiles: ArraySlice<CleanupFileCandidate> {
        candidates.prefix(5)
    }
}

struct CleanupScanReport: ScanCoverageReporting {
    let results: [CleanupScanResult]
    let startedAt: Date
    let finishedAt: Date

    var coverage: [ScanCoverage] { results.flatMap(\.coverage) }

    var totalBytes: Int64 {
        results.reduce(0) { $0 + $1.totalBytes }
    }

    var totalFileCount: Int {
        results.reduce(0) { $0 + $1.fileCount }
    }

    var accessIssueCount: Int {
        results.reduce(0) { $0 + $1.coverage.reduce(0) { $0 + $1.accessIssueCount } }
    }

    var allCandidates: [CleanupFileCandidate] {
        results.flatMap(\.candidates)
    }
}

struct CleanupScanProgress: Equatable, Sendable {
    static let idle = CleanupScanProgress(
        currentLocation: String(localized: "准备扫描"),
        completedLocations: 0,
        totalLocations: 0,
        inspectedFileCount: 0,
        candidateBytes: 0
    )

    let currentLocation: String
    let completedLocations: Int
    let totalLocations: Int
    let inspectedFileCount: Int
    let candidateBytes: Int64
}

struct CleanupExecutionProgress: Equatable, Sendable {
    static let idle = CleanupExecutionProgress(
        currentPath: String(localized: "准备清理"),
        completedCount: 0,
        totalCount: 0,
        movedBytes: 0,
        failureCount: 0
    )

    let currentPath: String
    let completedCount: Int
    let totalCount: Int
    let movedBytes: Int64
    let failureCount: Int
}

struct CleanupFailure: Identifiable, Hashable, Sendable {
    var id: String { "\(path)|\(reason)" }

    let path: String
    let reason: String
}

struct CleanupExecutionReport: Sendable {
    let requestedCount: Int
    let requestedBytes: Int64
    let movedCount: Int
    let movedBytes: Int64
    let failures: [CleanupFailure]
    let cancelled: Bool
    let startedAt: Date
    let finishedAt: Date
    let itemResults: [ExecutionItemResult]

    init(
        requestedCount: Int,
        requestedBytes: Int64,
        movedCount: Int,
        movedBytes: Int64,
        failures: [CleanupFailure],
        cancelled: Bool,
        finishedAt: Date,
        startedAt: Date? = nil,
        itemResults: [ExecutionItemResult] = []
    ) {
        self.requestedCount = requestedCount
        self.requestedBytes = requestedBytes
        self.movedCount = movedCount
        self.movedBytes = movedBytes
        self.failures = failures
        self.cancelled = cancelled
        self.startedAt = startedAt ?? finishedAt
        self.finishedAt = finishedAt
        self.itemResults = itemResults
    }

    var executionResultSet: ExecutionResultSet {
        ExecutionResultSet(
            domain: .cleanup,
            startedAt: startedAt,
            completedAt: finishedAt,
            wasUserAborted: cancelled,
            items: itemResults
        )
    }
}

struct CleanupHistoryEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let finishedAt: Date
    let requestedCount: Int
    let movedCount: Int
    let failedCount: Int
    let movedBytes: Int64
    let cancelled: Bool
}
