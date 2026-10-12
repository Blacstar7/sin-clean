import AppKit
import Darwin
import Foundation

/// The single execution-time safety classifier used by both production executors.
/// It returns structured failures so receipts never infer outcomes from localized text.
enum ExecutionSafetyCore {
    static func moveFailure(_ error: NSError) -> ExecutionValidationFailure {
        let permissionFailure =
            (error.domain == NSPOSIXErrorDomain
                && (error.code == Int(EACCES) || error.code == Int(EPERM)))
            || (error.domain == NSCocoaErrorDomain
                && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError]
                    .contains(error.code))
        if permissionFailure {
            return .init(
                code: .movePermissionDenied,
                text: String(localized: "安全复验已通过，但系统因权限原因未能将项目移入废纸篓。")
            )
        }
        return .init(
            code: .moveSystemFailure,
            text: String(localized: "安全复验已通过，但系统移动到废纸篓失败：\(error.localizedDescription)")
        )
    }

    static func validateCleanup(
        _ candidate: CleanupFileCandidate,
        allowedRootPaths: Set<String>
    ) -> ExecutionValidationFailure? {
        let rootURL = URL(fileURLWithPath: candidate.rootPath).standardizedFileURL
        let candidateURL = URL(fileURLWithPath: candidate.path).standardizedFileURL

        guard allowedRootPaths.contains(rootURL.path) else {
            return .init(code: .pathOutsideAllowedRoot, text: String(localized: "扫描根路径不在允许的清理范围内，已安全跳过。"))
        }
        guard isStrictDescendant(candidateURL, of: rootURL) else {
            return .init(code: .pathOutsideAllowedRoot, text: String(localized: "文件路径已超出扫描根目录，已安全跳过。"))
        }
        if let failure = validatePathComponents(
            candidateURL: candidateURL,
            rootURL: rootURL,
            parentTypeText: String(localized: "文件的上级路径类型已变化，不再是目录，已安全跳过。")
        ) {
            return failure
        }

        var info = stat()
        let result = candidateURL.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else {
            return pathLookupFailure(errnoCode: errno, target: String(localized: "文件"))
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return .init(code: .fileTypeChanged, text: String(localized: "文件类型已变化，目标不再是扫描时的普通文件，已安全跳过。"))
        }
        guard UInt64(info.st_dev) == candidate.deviceID,
              UInt64(info.st_ino) == candidate.inode else {
            return .init(code: .identityChanged, text: String(localized: "文件身份已变化：deviceID 或 inode 与扫描快照不一致，已安全跳过。"))
        }
        guard Int64(info.st_size) == candidate.logicalBytes,
              Int64(info.st_mtimespec.tv_sec) == candidate.modifiedSeconds,
              Int64(info.st_mtimespec.tv_nsec) == candidate.modifiedNanoseconds else {
            return .init(code: .metadataChanged, text: String(localized: "文件容量或修改时间已变化，请重新扫描后再决定。"))
        }
        return nil
    }

    static func validateUninstall(
        _ candidate: UninstallItemCandidate,
        applicationRootPaths: Set<String>,
        residueRootPaths: Set<String>
    ) -> ExecutionValidationFailure? {
        let rootURL = URL(fileURLWithPath: candidate.rootPath).standardizedFileURL
        let candidateURL = URL(fileURLWithPath: candidate.path).standardizedFileURL

        guard isSafeBundleIdentifier(candidate.bundleIdentifier) else {
            return .init(code: .bundleIdentifierInvalid, text: String(localized: "Bundle Identifier 不符合安全规则，已安全跳过。"))
        }

        switch candidate.kind {
        case .applicationBundle:
            guard applicationRootPaths.contains(rootURL.path) else {
                return .init(code: .pathOutsideAllowedRoot, text: String(localized: "应用不在允许的 Applications 根目录内，已安全跳过。"))
            }
            guard candidateURL.pathExtension.lowercased() == "app" else {
                return .init(code: .fileTypeChanged, text: String(localized: "应用路径类型已变化，目标不再是 APP 应用包，已安全跳过。"))
            }
        case .residueFile, .residueDirectory:
            guard residueRootPaths.contains(rootURL.path) else {
                return .init(code: .pathOutsideAllowedRoot, text: String(localized: "关联项目不在允许的用户资料根目录内，已安全跳过。"))
            }
            guard expectedResiduePaths(
                homeDirectory: rootURL.deletingLastPathComponent().deletingLastPathComponent(),
                bundleIdentifier: candidate.bundleIdentifier
            ).contains(candidateURL.path) else {
                return .init(code: .residueRuleMismatch, text: String(localized: "关联路径与 Bundle Identifier 的固定规则不一致，已安全跳过。"))
            }
        }

        guard isStrictDescendant(candidateURL, of: rootURL) else {
            return .init(code: .pathOutsideAllowedRoot, text: String(localized: "目标路径已超出允许的根目录，已安全跳过。"))
        }
        if let failure = validatePathComponents(
            candidateURL: candidateURL,
            rootURL: rootURL,
            parentTypeText: String(localized: "目标的上级路径类型已变化，不再是目录，已安全跳过。")
        ) {
            return failure
        }

        var info = stat()
        let result = candidateURL.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else {
            return pathLookupFailure(errnoCode: errno, target: String(localized: "目标"))
        }

        let type = info.st_mode & mode_t(S_IFMT)
        switch candidate.kind {
        case .applicationBundle, .residueDirectory:
            guard type == mode_t(S_IFDIR) else {
                return .init(code: .fileTypeChanged, text: String(localized: "目标类型已变化，不再是扫描时的目录，已安全跳过。"))
            }
        case .residueFile:
            guard type == mode_t(S_IFREG) else {
                return .init(code: .fileTypeChanged, text: String(localized: "目标类型已变化，不再是扫描时的普通文件，已安全跳过。"))
            }
        }
        guard UInt64(info.st_dev) == candidate.deviceID,
              UInt64(info.st_ino) == candidate.inode else {
            return .init(code: .identityChanged, text: String(localized: "目标身份已变化：deviceID 或 inode 与扫描快照不一致，已安全跳过。"))
        }
        guard Int64(info.st_size) == candidate.logicalBytes,
              Int64(info.st_mtimespec.tv_sec) == candidate.modifiedSeconds,
              Int64(info.st_mtimespec.tv_nsec) == candidate.modifiedNanoseconds else {
            return .init(code: .metadataChanged, text: String(localized: "目标容量或修改时间已变化，请重新扫描后再决定。"))
        }
        if candidate.kind == .applicationBundle {
            guard Bundle(url: candidateURL)?.bundleIdentifier == candidate.bundleIdentifier else {
                return .init(code: .bundleIdentifierChanged, text: String(localized: "应用 Bundle Identifier 与扫描快照不一致，已安全跳过。"))
            }
            if !NSRunningApplication.runningApplications(withBundleIdentifier: candidate.bundleIdentifier).isEmpty {
                return .init(code: .applicationStillRunning, text: String(localized: "应用仍在运行，请先退出应用后重试。"))
            }
        }
        return nil
    }

    private static func pathLookupFailure(errnoCode: Int32, target: String) -> ExecutionValidationFailure {
        if errnoCode == EACCES || errnoCode == EPERM {
            return .init(
                code: .validationPermissionDenied,
                text: String(localized: "执行前无法读取\(target)，系统权限不足，已安全跳过。")
            )
        }
        return .init(
            code: .pathChanged,
            text: String(localized: "原\(target)路径已不存在或路径结构已变化，执行前路径复验未通过。")
        )
    }

    private static func validatePathComponents(
        candidateURL: URL,
        rootURL: URL,
        parentTypeText: String
    ) -> ExecutionValidationFailure? {
        let rootComponents = rootURL.pathComponents
        let candidateComponents = candidateURL.pathComponents
        var currentURL = URL(fileURLWithPath: "/", isDirectory: true)

        for (index, component) in candidateComponents.enumerated() where index > 0 {
            currentURL.appendPathComponent(component)
            guard index >= rootComponents.count - 1 else { continue }

            var info = stat()
            let result = currentURL.path.withCString { Darwin.lstat($0, &info) }
            guard result == 0 else {
                return pathLookupFailure(errnoCode: errno, target: String(localized: "路径组件"))
            }

            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFLNK) {
                return .init(
                    code: .symbolicLinkDetected,
                    text: String(localized: "路径中出现符号链接，执行前安全复验已拒绝处理。")
                )
            }
            if index < candidateComponents.count - 1, type != mode_t(S_IFDIR) {
                return .init(code: .fileTypeChanged, text: parentTypeText)
            }
        }
        return nil
    }

    private static func isStrictDescendant(_ candidateURL: URL, of rootURL: URL) -> Bool {
        let rootComponents = rootURL.pathComponents
        let candidateComponents = candidateURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func isSafeBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains("..") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func expectedResiduePaths(
        homeDirectory: URL,
        bundleIdentifier: String
    ) -> Set<String> {
        let library = homeDirectory.appending(path: "Library", directoryHint: .isDirectory)
        return Set([
            library.appending(path: "Caches/\(bundleIdentifier)"),
            library.appending(path: "Logs/\(bundleIdentifier)"),
            library.appending(path: "Preferences/\(bundleIdentifier).plist"),
            library.appending(path: "Saved Application State/\(bundleIdentifier).savedState"),
            library.appending(path: "Application Support/\(bundleIdentifier)"),
            library.appending(path: "Containers/\(bundleIdentifier)"),
            library.appending(path: "HTTPStorages/\(bundleIdentifier)"),
            library.appending(path: "WebKit/\(bundleIdentifier)"),
            library.appending(path: "Application Scripts/\(bundleIdentifier)")
        ].map { $0.standardizedFileURL.path })
    }
}
