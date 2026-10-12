import Foundation

// SC-6 冻结语义修订记录 R1（2026-09-30）·下载与安装语义＋破坏性文件操作授权；
// R1 附注二（同日）：备份事务标识与 journal、安装前信任门、ZIP 条目守卫、目标卷峰值空间、
// 残留清理三条件（journal 匹配＋真实目录＋当前安装存在）。
// 本文件与 UpdateDownloader.swift 是全工程唯二允许 moveItem／removeItem 的文件，
// 路径边界严格限定：①暂存目录树（~/Library/Caches/SinClean/Updates/<UUID>/）；
// ②当前 .app 与其同目录备份名（前缀 SinClean.app.backup-<事务UUID> 严格校验）；
// ③解包产物 → 安装位置这一条移动。Process 仅允许 /usr/bin/ditto（解包，固定参数形态）。
// trashItem 全局唯一性（CleanupExecutor.swift）不变。
// 措辞纪律（R1 附注二第 9 条）：本流程是多步替换、逐步可回滚，不是原子事务。

enum UpdateInstallError: Error, Equatable, Sendable {
    case stagingRootUnavailable
    case stagingCreateFailed(String)
    case packageMissing
    case guardFailed(UpdatePackageGuardError)
    case extractionFailed(String)
    case currentBundleMissing
    case boundaryViolation(String)
    case journalWriteFailed(String)
    case journalWriteFailedRestored(String)
    case volumeUnidentifiable(side: String)
    case crossVolumeRefused(staging: String, target: String)
    case peakSpaceInsufficient(required: Int, available: Int)
    case backupFailed(String)
    case replaceFailed(String)
    case restoreFailed(String)
}

/// 启动残留检测结果（R1 附注三第 1 条：启动时只读识别——一律不删除）。
enum UpdateResidueOutcome: Equatable, Sendable {
    case none
    /// 检测到前缀匹配项；全部保留待人工处置（含归属可判与不可判——启动路径不做删除）。
    case notice(count: Int, backupNames: [String])
}

/// 备份事务 journal（伴随文件 `<备份名>.journal`；JSON 字段冻结于 R1 附注二第 3 条）。
struct UpdateBackupJournal: Equatable, Sendable {
    let transactionID: String
    let originalPath: String
    let channel: String
    let targetVersion: String
    let targetBuild: Int
    let startedAt: String
    let stagingVolume: String
    let targetVolume: String

    func encoded() -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "id": transactionID,
            "originalPath": originalPath,
            "channel": channel,
            "targetVersion": targetVersion,
            "targetBuild": targetBuild,
            "startedAt": startedAt,
            "stagingVolume": stagingVolume,
            "targetVolume": targetVolume,
        ], options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> UpdateBackupJournal? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let originalPath = object["originalPath"] as? String,
              let channel = object["channel"] as? String,
              let targetVersion = object["targetVersion"] as? String,
              let targetBuild = object["targetBuild"] as? Int,
              let startedAt = object["startedAt"] as? String,
              let stagingVolume = object["stagingVolume"] as? String,
              let targetVolume = object["targetVolume"] as? String
        else { return nil }
        return UpdateBackupJournal(
            transactionID: id, originalPath: originalPath, channel: channel,
            targetVersion: targetVersion, targetBuild: targetBuild, startedAt: startedAt,
            stagingVolume: stagingVolume, targetVolume: targetVolume)
    }
}

enum UpdateInstaller {
    /// 备份名前缀（冻结语义 R1；所有备份名校验以此为界；后接事务 UUID）。
    static let backupPrefix = "SinClean.app.backup-"
    /// 信任门钉死的 Team ID（R1 附注二第 4 条）。
    static let requiredTeamID = "4K69D9HNGQ"
    /// 峰值空间余量（沿用冻结语义 §4.3 的 64 MiB）。
    static let peakSlackBytes = 67_108_864

    // MARK: - 暂存目录

    /// 暂存根目录：~/Library/Caches/SinClean/Updates/（冻结语义 R1 安装语义 2）。
    static func stagingRoot() -> Result<URL, UpdateInstallError> {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return .failure(.stagingRootUnavailable)
        }
        return .success(caches.appendingPathComponent("SinClean/Updates", isDirectory: true))
    }

    /// 创建一次性暂存目录（UUID 子目录；父目录按需创建）。
    static func makeStagingDirectory() -> Result<URL, UpdateInstallError> {
        let root: URL
        switch stagingRoot() {
        case .failure(let error): return .failure(error)
        case .success(let url): root = url
        }
        let staging = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            return .success(staging)
        } catch {
            return .failure(.stagingCreateFailed(error.localizedDescription))
        }
    }

    /// 路径边界校验：目标必须位于给定暂存目录之内（规范化后前缀匹配）。
    static func isInside(_ path: URL, staging: URL) -> Bool {
        let standardizedStaging = staging.standardizedFileURL.path
        let standardizedPath = path.standardizedFileURL.path
        return standardizedPath.hasPrefix(standardizedStaging + "/")
    }

    /// 清空暂存目录（成功或失败收尾时调用；受权操作①）。
    static func clearStaging(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    // MARK: - 解包

    /// /usr/bin/ditto -x -k <zip> <目标目录>（冻结语义 R1 安装语义 3a，固定参数形态）。
    static func extractZIP(at zipFile: URL, into destination: URL) -> Result<URL, UpdateInstallError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipFile.path, destination.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(.extractionFailed(error.localizedDescription))
        }
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(.extractionFailed("ditto exit \(process.terminationStatus): \(output.prefix(200))"))
        }
        return .success(destination)
    }

    // MARK: - 空间与卷

    /// 目录树实测大小（字节）。
    static func directorySize(_ url: URL) -> Int? {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return nil }
        var total = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
               values.isDirectory != true {
                total += values.fileSize ?? 0
            }
        }
        return total
    }

    // MARK: - 分步替换（供 install 编排与 harness 分步失败注入）

    /// 步骤一：当前 .app 改名为备份（同目录、事务 UUID 后缀；名字不可预测、互斥）。
    static func stageBackup(current: URL, transactionID: String, date: Date = Date()) throws -> URL {
        let backupURL = current.deletingLastPathComponent()
            .appendingPathComponent(backupPrefix + transactionID, isDirectory: true)
        guard backupURL.lastPathComponent.hasPrefix(backupPrefix),
              backupURL.deletingLastPathComponent().path == current.deletingLastPathComponent().path
        else { throw UpdateInstallError.boundaryViolation("backup path out of bounds: \(backupURL.path)") }
        try FileManager.default.moveItem(at: current, to: backupURL)
        return backupURL
    }

    /// 步骤二：写伴随 journal（备份成功后、替换前；归属证明）。
    static func stageJournal(at backupURL: URL, journal: UpdateBackupJournal) throws {
        guard backupURL.lastPathComponent.hasPrefix(backupPrefix) else {
            throw UpdateInstallError.boundaryViolation("journal target not a backup name")
        }
        guard let data = journal.encoded() else {
            throw UpdateInstallError.journalWriteFailed("encode failed")
        }
        do {
            try data.write(to: backupURL.appendingPathExtension("journal"))
        } catch {
            throw UpdateInstallError.journalWriteFailed(error.localizedDescription)
        }
    }

    /// 步骤三：新 .app 移入原位置；失败时立即把备份移回（恢复）。
    /// 返回 nil＝替换成功；返回错误时 restored 指示当前安装是否已恢复。
    static func stageReplace(newApp: URL, current: URL, backupURL: URL) throws -> (error: Error?, restored: Bool) {
        do {
            try FileManager.default.moveItem(at: newApp, to: current)
            return (nil, true)
        } catch {
            let replaceError = error
            // 恢复成败按 moveItem 实际结果判定（目标被部分内容占用时恢复失败，不得误报已恢复）。
            do {
                try FileManager.default.moveItem(at: backupURL, to: current)
                return (replaceError, true)
            } catch {
                return (replaceError, false)
            }
        }
    }

    /// 步骤四：删除备份与 journal（受权操作②③；失败不视为安装失败，交由残留检测）。
    static func stageCleanup(backupURL: URL) {
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: backupURL.appendingPathExtension("journal"))
    }

    /// 从备份恢复当前安装（失败注入／手动恢复路径的编程入口；同边界校验）。
    static func stageRestoreBackup(backupURL: URL, to current: URL) -> Bool {
        guard backupURL.lastPathComponent.hasPrefix(backupPrefix) else { return false }
        // 恢复成败按 moveItem 实际结果判定（目标被占位内容占用时不得误报已恢复）。
        do {
            try FileManager.default.moveItem(at: backupURL, to: current)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 安装（编排）

    /// 全流程安装（冻结语义 R1 安装语义 3＋附注二；多步替换、逐步可回滚）。
    /// 前置：zip 已位于暂存目录内且已通过 UpdateVerifier 全管线校验。
    /// 信任门：ZIP 守卫→解包→走查→签名/Team/标识/版本/构建/票据校验→峰值空间→备份替换。
    static func install(
        zipFile: URL,
        staging: URL,
        currentBundle: URL = Bundle.main.bundleURL,
        expectedBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        rollbackLog: UpdateRollbackLog,
        channel: UpdateChannel,
        targetVersion: String,
        targetBuild: Int,
        date: Date = Date(),
        volumeIdentifier: (URL) -> String? = UpdatePackageGuard.volumeIdentifier(of:),
        journalWriter: (URL, UpdateBackupJournal) throws -> Void = { try stageJournal(at: $0, journal: $1) }
    ) -> Result<URL, UpdateInstallError> {
        // 边界：zip 必须在暂存目录内。
        guard isInside(zipFile, staging: staging), FileManager.default.fileExists(atPath: zipFile.path) else {
            return .failure(.packageMissing)
        }
        // ZIP 条目守卫（解包前；R1 附注二第 5 条）。
        switch UpdatePackageGuard.inspectZIP(at: zipFile) {
        case .failure(let error): return .failure(.guardFailed(error))
        case .success: break
        }
        // 解包到暂存内的 extracted/。
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        } catch {
            return .failure(.stagingCreateFailed(error.localizedDescription))
        }
        switch extractZIP(at: zipFile, into: extracted) {
        case .failure(let error): return .failure(error)
        case .success: break
        }
        // 解包产物走查（同限复核）。
        let newAppURL: URL
        switch UpdatePackageGuard.verifyExtractedLayout(root: extracted) {
        case .failure(let error): return .failure(.guardFailed(error))
        case .success(let url): newAppURL = url
        }
        // 信任门：签名完整性＋Team ID＋代码标识＋版本/构建与清单一致＋票据存在（附注二第 4 条）。
        switch UpdatePackageGuard.verifyCodeTrust(
            appURL: newAppURL,
            expectedTeamID: requiredTeamID,
            expectedBundleID: expectedBundleIdentifier,
            expectedBuild: targetBuild
        ) {
        case .failure(let error):
            rollbackLog.record(
                channel: channel, targetVersion: targetVersion, targetBuild: targetBuild,
                category: "trust-gate-rejected", reason: String(describing: error), date: date
            )
            return .failure(.guardFailed(error))
        case .success: break
        }
        // 目标存在性与峰值空间（附注二第 6 条：新 app＋当前安装＋64 MiB，目标卷）。
        guard FileManager.default.fileExists(atPath: currentBundle.path) else {
            return .failure(.currentBundleMissing)
        }
        guard let newAppBytes = directorySize(newAppURL),
              let currentBytes = directorySize(currentBundle)
        else { return .failure(.currentBundleMissing) }
        let required = newAppBytes + currentBytes + peakSlackBytes
        guard let available = UpdateVerifier.availableBytes(volume: currentBundle) else {
            return .failure(.peakSpaceInsufficient(required: required, available: 0))
        }
        guard available >= required else {
            return .failure(.peakSpaceInsufficient(required: required, available: available))
        }
        // 卷标识（R1 附注四第 2 条：两侧均取得真实标识且相同才放行；任一侧取不到即拒绝）。
        guard let stagingVolume = volumeIdentifier(staging),
              let targetVolume = volumeIdentifier(currentBundle)
        else {
            let side = volumeIdentifier(staging) == nil ? "staging" : "target"
            rollbackLog.record(
                channel: channel, targetVersion: targetVersion, targetBuild: targetBuild,
                category: "volume-unidentifiable",
                reason: "side=\(side)（卷标识不可得，触碰旧 app 前拒绝）", date: date
            )
            return .failure(.volumeUnidentifiable(side: side))
        }
        guard stagingVolume == targetVolume else {
            rollbackLog.record(
                channel: channel, targetVersion: targetVersion, targetBuild: targetBuild,
                category: "cross-volume-refused",
                reason: "staging=\(stagingVolume) target=\(targetVolume)（触碰旧 app 前拒绝）", date: date
            )
            return .failure(.crossVolumeRefused(staging: stagingVolume, target: targetVolume))
        }
        // 多步替换。
        let formatter = ISO8601DateFormatter()
        let journal = UpdateBackupJournal(
            transactionID: UUID().uuidString,
            originalPath: currentBundle.path,
            channel: channel.rawValue,
            targetVersion: targetVersion,
            targetBuild: targetBuild,
            startedAt: formatter.string(from: date),
            stagingVolume: stagingVolume,
            targetVolume: targetVolume
        )
        let backupURL: URL
        do {
            backupURL = try stageBackup(current: currentBundle, transactionID: journal.transactionID, date: date)
        } catch {
            rollbackLog.record(
                channel: channel, targetVersion: targetVersion, targetBuild: targetBuild,
                category: "backup-failed", reason: error.localizedDescription, date: date
            )
            return .failure(.backupFailed(error.localizedDescription))
        }
        do {
            try journalWriter(backupURL, journal)
        } catch {
            // R1 附注四第 1 条：journal 写入失败必须立即尝试恢复（备份移回原位），
            // 恢复成功与失败分别报告；恢复成功时当前安装逐字节不变。
            let journalError = error.localizedDescription
            let restored = stageRestoreBackup(backupURL: backupURL, to: currentBundle)
            rollbackLog.record(
                channel: channel, targetVersion: targetVersion, targetBuild: targetBuild,
                category: restored ? "journal-write-failed-restored" : "journal-write-failed-restore-failed",
                reason: restored ? journalError : "\(journalError)；恢复失败：\(backupURL.lastPathComponent) 保留待手动恢复",
                date: date
            )
            return restored
                ? .failure(.journalWriteFailedRestored(journalError))
                : .failure(.restoreFailed("\(journalError)；备份保留于 \(backupURL.path)"))
        }
        let replaceOutcome = (try? stageReplace(newApp: newAppURL, current: currentBundle, backupURL: backupURL))
            ?? (error: UpdateInstallError.replaceFailed("stage unavailable"), restored: false)
        if let replaceError = replaceOutcome.error {
            let reason = replaceOutcome.restored
                ? String(describing: replaceError)
                : "\(replaceError)；恢复失败：\(backupURL.lastPathComponent) 保留待手动恢复"
            rollbackLog.record(
                channel: channel, targetVersion: targetVersion, targetBuild: targetBuild,
                category: replaceOutcome.restored ? "replace-failed-restored" : "replace-failed-restore-failed",
                reason: reason, date: date
            )
            return replaceOutcome.restored
                ? .failure(.replaceFailed(String(describing: replaceError)))
                : .failure(.restoreFailed(reason))
        }
        stageCleanup(backupURL: backupURL)
        return .success(currentBundle)
    }

    // MARK: - 启动残留检测（冻结语义 R1 安装语义 3e＋附注二第 3 条三条件）

    static func handleResidueAtLaunch(
        currentBundle: URL = Bundle.main.bundleURL,
        rollbackLog: UpdateRollbackLog,
        channel: UpdateChannel?,
        date: Date = Date()
    ) -> UpdateResidueOutcome {
        // R1 附注三第 1 条：启动路径一律只读——识别、记录、提示人工恢复；不删除任何文件。
        let parent = currentBundle.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
            return .none
        }
        let candidates = items.filter { $0.hasPrefix(backupPrefix) && !$0.hasSuffix(".journal") }
        guard !candidates.isEmpty else { return .none }
        let currentExists = FileManager.default.fileExists(atPath: currentBundle.path)
        for name in candidates {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            var kind = "unknown"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let type = attrs[.type] as? FileAttributeType {
                kind = type == .typeDirectory ? "directory"
                    : (type == .typeSymbolicLink ? "symlink" : "file")
            }
            rollbackLog.record(
                channel: channel ?? .internal, targetVersion: "-", targetBuild: 0,
                category: currentExists ? "residue-notice" : "residue-notice-current-missing",
                reason: "\(name) kind=\(kind)（保留待人工处置，见 incident runbook 恢复步骤）", date: date
            )
        }
        return .notice(count: candidates.count, backupNames: candidates)
    }
}