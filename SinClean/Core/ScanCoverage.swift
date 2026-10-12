import Darwin
import Foundation

enum CoverageStatus: String, Sendable {
    case notStarted, inProgress, completed, partial, notSelected, inaccessible, skipped, notFound, cancelled
}
enum ScannerKind: String, Sendable { case disk, application, residue, association }
enum ScanPhase: String, Sendable { case discover, measure, inspect, associate }
enum ScanIssueKind: String, Sendable { case accessFailure, timeout, readFailure, parseFailure, safetySkip, policySkip, notFound }

/// Frozen descriptions of existing traversal predicates; these never drive the executor.
struct ScanPolicy: Hashable, Sendable {
    let recursive: Bool
    let maximumDepth: Int?
    let skipsHiddenFiles: Bool
    let acceptedTypes: [String]
    let extensions: [String]
    let excludedPackageExtensions: [String]
    let matching: String
    let maximumReadBytes: Int64?
    let directoryOpenTimeout: TimeInterval?
    let measurementConcurrency: Int?

    init(recursive: Bool, maximumDepth: Int? = nil, skipsHiddenFiles: Bool = false,
         acceptedTypes: [String] = ["regularFile", "directory"], extensions: [String] = [],
         excludedPackageExtensions: [String] = [], matching: String,
         maximumReadBytes: Int64? = nil, directoryOpenTimeout: TimeInterval? = nil,
         measurementConcurrency: Int? = nil) {
        self.recursive = recursive; self.maximumDepth = maximumDepth
        self.skipsHiddenFiles = skipsHiddenFiles; self.acceptedTypes = acceptedTypes
        self.extensions = extensions.sorted(); self.excludedPackageExtensions = excludedPackageExtensions.sorted()
        self.matching = matching; self.maximumReadBytes = maximumReadBytes
        self.directoryOpenTimeout = directoryOpenTimeout; self.measurementConcurrency = measurementConcurrency
    }
}

struct ScanScope: Hashable, Sendable {
    let id: String
    let scanner: ScannerKind
    let phase: ScanPhase
    let rootPath: String
    let targetPath: String?
    let associatedApplicationID: String?
    let associatedBundleIdentifier: String?
    let policy: ScanPolicy

    init(id: String, scanner: ScannerKind, phase: ScanPhase, rootPath: String, targetPath: String? = nil,
         applicationID: String? = nil, bundleIdentifier: String? = nil, policy: ScanPolicy) {
        self.id = id; self.scanner = scanner; self.phase = phase; self.rootPath = rootPath
        self.targetPath = targetPath; associatedApplicationID = applicationID
        associatedBundleIdentifier = bundleIdentifier; self.policy = policy
    }
}

struct ScanIssue: Hashable, Sendable {
    let scopeID: String
    let path: String?
    let phase: ScanPhase
    let kind: ScanIssueKind
    let restrictionReason: RestrictionReason?
    let underlyingErrorDomain: String?
    let underlyingErrorCode: Int?
    let message: String
    let affectsCompleteness: Bool
    /// Whether this instance belongs in the compatibility text consumed by the current UI.
    /// This is decided where the issue is observed; `kind` alone is not UI semantics.
    let projectsToLegacyAccessIssues: Bool
    var displayText: String { path.map { "\($0)：\(message)" } ?? message }
}

struct ScanCoverage: Hashable, Sendable {
    let context: ScanContext
    let scope: ScanScope
    let status: CoverageStatus
    let startedAt: Date?
    let finishedAt: Date?
    let issues: [ScanIssue]
    let issueCount: Int
    let accessIssueCount: Int
    var omittedIssueCount: Int { issueCount - issues.count }
    var ruleVersion: String { context.ruleVersion }
    var accessIssues: [String] { issues.filter(\.projectsToLegacyAccessIssues).map(\.displayText) }
}

/// Scanner-local accumulator. Reports expose immutable snapshots, with bounded samples and exact totals.
struct ScanObservation: Sendable {
    let context: ScanContext
    let scope: ScanScope
    let issueLimit: Int
    private(set) var status: CoverageStatus = .notStarted
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var issues: [ScanIssue] = []
    private(set) var issueCount = 0
    private(set) var accessIssueCount = 0
    private var hasCoverageGap = false

    init(context: ScanContext, scope: ScanScope, issueLimit: Int = 20) {
        self.context = context; self.scope = scope; self.issueLimit = max(0, issueLimit)
    }
    mutating func begin() { status = .inProgress; startedAt = Date() }
    mutating func finish(_ terminal: CoverageStatus? = nil) {
        if let terminal { status = terminal }
        else if status == .inProgress { status = hasCoverageGap ? .partial : .completed }
        finishedAt = Date()
    }
    mutating func record(path: String?, kind: ScanIssueKind, message: String,
                         restriction: RestrictionReason? = nil, domain: String? = nil, code: Int? = nil,
                         affectsCompleteness: Bool = true, phase: ScanPhase? = nil,
                         projectsToLegacyAccessIssues: Bool) {
        let issue = ScanIssue(scopeID: scope.id, path: path, phase: phase ?? scope.phase, kind: kind,
            restrictionReason: restriction, underlyingErrorDomain: domain, underlyingErrorCode: code,
            message: message, affectsCompleteness: affectsCompleteness,
            projectsToLegacyAccessIssues: projectsToLegacyAccessIssues)
        issueCount += 1
        if issue.projectsToLegacyAccessIssues { accessIssueCount += 1 }
        hasCoverageGap = hasCoverageGap || affectsCompleteness
        if issues.count < issueLimit {
            issues.append(issue)
        } else if issue.projectsToLegacyAccessIssues,
                  issues.filter(\.projectsToLegacyAccessIssues).count < issueLimit,
                  let replacement = issues.lastIndex(where: { !$0.projectsToLegacyAccessIssues }) {
            // Keep the structured sample bounded while ensuring normal safety diagnostics cannot
            // consume every compatibility slot ahead of a real filesystem access failure.
            issues[replacement] = issue
        }
    }
    mutating func recordPOSIX(path: String, code: Int32, atRoot: Bool = false,
                              phase: ScanPhase? = nil, projectsToLegacyAccessIssues: Bool) {
        let kind: ScanIssueKind = code == ETIMEDOUT ? .timeout
            : (code == EACCES || code == EPERM ? .accessFailure : (atRoot && code == ENOENT ? .notFound : .readFailure))
        record(path: path, kind: kind, message: String(cString: strerror(code)),
               domain: NSPOSIXErrorDomain, code: Int(code), phase: phase,
               projectsToLegacyAccessIssues: projectsToLegacyAccessIssues && kind != .notFound)
        if atRoot { finish(code == ENOENT ? .notFound : .inaccessible) }
    }
    mutating func record(error: Error, path: String, kind: ScanIssueKind = .readFailure,
                         atRoot: Bool = false, projectsToLegacyAccessIssues: Bool) {
        let nsError = error as NSError
        let actualKind: ScanIssueKind
        if atRoot && ((nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
            || (nsError.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code))) {
            actualKind = .notFound
        } else if kind == .readFailure && ((nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError)
            || (nsError.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(nsError.code))) {
            actualKind = .accessFailure
        } else if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ETIMEDOUT) {
            actualKind = .timeout
        } else { actualKind = kind }
        record(path: path, kind: actualKind, message: nsError.localizedDescription,
               domain: nsError.domain, code: nsError.code,
               projectsToLegacyAccessIssues: projectsToLegacyAccessIssues && actualKind != .notFound)
        if atRoot { finish(actualKind == .notFound ? .notFound : .inaccessible) }
    }
    mutating func skip(path: String?, reason: RestrictionReason, message: String,
                       policy: Bool = false, atRoot: Bool = false,
                       projectsToLegacyAccessIssues: Bool) {
        record(path: path, kind: policy ? .policySkip : .safetySkip, message: message,
               restriction: reason, affectsCompleteness: !policy,
               projectsToLegacyAccessIssues: projectsToLegacyAccessIssues)
        if atRoot { finish(.skipped) }
    }
    var snapshot: ScanCoverage {
        ScanCoverage(context: context, scope: scope, status: status, startedAt: startedAt, finishedAt: finishedAt,
                     issues: issues, issueCount: issueCount, accessIssueCount: accessIssueCount)
    }
}

extension Array where Element == ScanCoverage {
    /// A report-wide budget in addition to the per-scope working budget. Counts survive truncation.
    func boundedIssueSamples(_ limit: Int) -> [ScanCoverage] {
        let limit = Swift.max(0, limit)
        let indexedIssues = enumerated().flatMap { coverageIndex, record in
            record.issues.enumerated().map { issueIndex, issue in
                (coverageIndex, issueIndex, issue)
            }
        }
        var selected = Set<String>()
        for candidate in indexedIssues.filter({ $0.2.projectsToLegacyAccessIssues })
            + indexedIssues.filter({ !$0.2.projectsToLegacyAccessIssues }) {
            guard selected.count < limit else { break }
            selected.insert("\(candidate.0)|\(candidate.1)")
        }
        return enumerated().map { coverageIndex, record in
            let samples = record.issues.enumerated().compactMap { issueIndex, issue in
                selected.contains("\(coverageIndex)|\(issueIndex)") ? issue : nil
            }
            return ScanCoverage(context: record.context, scope: record.scope, status: record.status,
                startedAt: record.startedAt, finishedAt: record.finishedAt, issues: samples,
                issueCount: record.issueCount, accessIssueCount: record.accessIssueCount)
        }
    }
}

protocol ScanCoverageReporting: Sendable {
    var coverage: [ScanCoverage] { get }
}
extension ScanCoverageReporting {
    var issues: [ScanIssue] { coverage.flatMap(\.issues) }
    var issueCount: Int { coverage.reduce(0) { $0 + $1.issueCount } }
    var omittedIssueCount: Int { coverage.reduce(0) { $0 + $1.omittedIssueCount } }
    var accessIssueCount: Int { coverage.reduce(0) { $0 + $1.accessIssueCount } }
    var scanStartedAt: Date? { coverage.first?.context.startedAt }
    var scanFinishedAt: Date? { coverage.compactMap(\.finishedAt).max() }
}
