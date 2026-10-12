import Darwin
import Foundation

enum SpaceAnalysisScopeSource: String, Hashable, Sendable {
    case common = "常用范围"
    case chosenDirectory = "自选目录"

    var localizedTitle: String {
        switch self {
        case .common: String(localized: "常用范围")
        case .chosenDirectory: String(localized: "自选目录")
        }
    }
}

struct SpaceAnalysisScope: Identifiable, Hashable, Sendable {
    var id: String { path }

    let displayName: String
    let path: String
    let source: SpaceAnalysisScopeSource
}

struct SpaceAnalysisScopeCandidate: Hashable, Sendable {
    let displayName: String
    let path: String
    let source: SpaceAnalysisScopeSource
}

enum SpaceAnalysisCommonScope: String, CaseIterable, Identifiable, Sendable {
    case home
    case downloads
    case documents
    case desktop

    var id: Self { self }

    var displayName: String {
        switch self {
        case .home: String(localized: "个人文件夹")
        case .downloads: String(localized: "下载")
        case .documents: String(localized: "文稿")
        case .desktop: String(localized: "桌面")
        }
    }

    func candidate(homeDirectory: URL) -> SpaceAnalysisScopeCandidate {
        let url: URL
        switch self {
        case .home:
            url = homeDirectory
        case .downloads:
            url = homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        case .documents:
            url = homeDirectory.appending(path: "Documents", directoryHint: .isDirectory)
        case .desktop:
            url = homeDirectory.appending(path: "Desktop", directoryHint: .isDirectory)
        }
        return SpaceAnalysisScopeCandidate(
            displayName: displayName,
            path: url.path,
            source: .common
        )
    }
}

enum SpaceAnalysisScopeRejection: Hashable, Sendable {
    case pathIsNotAbsolute(path: String)
    case doesNotExist(path: String)
    case inaccessible(path: String, errorCode: Int32)
    case notDirectory(path: String)
    case symbolicLink(path: String)
    case duplicate(path: String)
    case coveredBySelectedParent(path: String, parentPath: String)
    case conflictsWithSelectedChild(path: String, childPath: String)
    case systemRoot(path: String)
    case volumeRoot(path: String)

    var message: String {
        switch self {
        case .pathIsNotAbsolute(let path):
            String(localized: "无法加入“\(path)”：空间分析范围必须是绝对路径。")
        case .doesNotExist(let path):
            String(localized: "无法加入“\(path)”：目录入口不存在。")
        case .inaccessible(let path, _):
            String(localized: "无法加入“\(path)”：当前无法读取并进入此目录入口。")
        case .notDirectory(let path):
            String(localized: "无法加入“\(path)”：所选项目不是目录。")
        case .symbolicLink(let path):
            String(localized: "无法加入“\(path)”：目录入口本身是符号链接；Sin Clean 不会解析到其目标位置。")
        case .duplicate(let path):
            String(localized: "“\(path)”已经在已选范围中，不会重复加入。")
        case .coveredBySelectedParent(let path, let parentPath):
            String(localized: "无法加入“\(path)”：已选父范围“\(parentPath)”将覆盖此目录。")
        case .conflictsWithSelectedChild(let path, let childPath):
            String(localized: "无法加入“\(path)”：已选子范围“\(childPath)”与其冲突。请先移除子范围，再添加父范围。")
        case .systemRoot:
            String(localized: "当前版本不支持分析系统根目录。请选择个人文件夹或更小的目录。")
        case .volumeRoot(let path):
            String(localized: "当前版本不支持整卷分析，不能加入卷根“\(path)”。请在卷内选择更小的目录。")
        }
    }
}

enum SpaceAnalysisScopeValidationResult: Hashable, Sendable {
    case accepted(SpaceAnalysisScope)
    case rejected(SpaceAnalysisScopeRejection)
}

protocol SpaceAnalysisScopeValidating: Sendable {
    func validate(
        _ candidate: SpaceAnalysisScopeCandidate,
        existingScopes: [SpaceAnalysisScope]
    ) -> SpaceAnalysisScopeValidationResult
}

struct SpaceAnalysisScopeValidator: SpaceAnalysisScopeValidating {
    private let volumeRootOverride: Set<String>?

    init(volumeRootOverride: Set<String>? = nil) {
        self.volumeRootOverride = volumeRootOverride
    }

    func validate(
        _ candidate: SpaceAnalysisScopeCandidate,
        existingScopes: [SpaceAnalysisScope]
    ) -> SpaceAnalysisScopeValidationResult {
        guard candidate.path.hasPrefix("/") else {
            return .rejected(.pathIsNotAbsolute(path: candidate.path))
        }

        let normalizedPath = Self.lexicallyNormalizedAbsolutePath(candidate.path)
        var fileInfo = stat()
        guard normalizedPath.withCString({ Darwin.lstat($0, &fileInfo) }) == 0 else {
            let code = errno
            return code == ENOENT
                ? .rejected(.doesNotExist(path: normalizedPath))
                : .rejected(.inaccessible(path: normalizedPath, errorCode: code))
        }

        let fileType = fileInfo.st_mode & mode_t(S_IFMT)
        guard fileType != mode_t(S_IFLNK) else {
            return .rejected(.symbolicLink(path: normalizedPath))
        }
        guard fileType == mode_t(S_IFDIR) else {
            return .rejected(.notDirectory(path: normalizedPath))
        }
        guard normalizedPath != "/" else {
            return .rejected(.systemRoot(path: normalizedPath))
        }
        if isVolumeRoot(normalizedPath) {
            return .rejected(.volumeRoot(path: normalizedPath))
        }
        guard Darwin.access(normalizedPath, R_OK | X_OK) == 0 else {
            return .rejected(.inaccessible(path: normalizedPath, errorCode: errno))
        }

        if existingScopes.contains(where: { $0.path == normalizedPath }) {
            return .rejected(.duplicate(path: normalizedPath))
        }
        if let parent = existingScopes.first(where: {
            Self.isStrictAncestor($0.path, of: normalizedPath)
        }) {
            return .rejected(.coveredBySelectedParent(
                path: normalizedPath,
                parentPath: parent.path
            ))
        }
        if let child = existingScopes.first(where: {
            Self.isStrictAncestor(normalizedPath, of: $0.path)
        }) {
            return .rejected(.conflictsWithSelectedChild(
                path: normalizedPath,
                childPath: child.path
            ))
        }

        return .accepted(SpaceAnalysisScope(
            displayName: candidate.displayName,
            path: normalizedPath,
            source: candidate.source
        ))
    }

    static func lexicallyNormalizedAbsolutePath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    static func isStrictAncestor(_ parentPath: String, of childPath: String) -> Bool {
        let parent = pathComponents(parentPath)
        let child = pathComponents(childPath)
        guard parent.count < child.count else { return false }
        return child.prefix(parent.count).elementsEqual(parent)
    }

    private static func pathComponents(_ path: String) -> [Substring] {
        lexicallyNormalizedAbsolutePath(path)
            .split(separator: "/", omittingEmptySubsequences: true)
    }

    private func isVolumeRoot(_ path: String) -> Bool {
        if let volumeRootOverride {
            return volumeRootOverride.contains(path)
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let volumeURL = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else {
            return false
        }
        return Self.lexicallyNormalizedAbsolutePath(volumeURL.path) == path
    }
}
