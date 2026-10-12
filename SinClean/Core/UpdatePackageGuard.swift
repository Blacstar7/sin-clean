import Foundation
import Security

// SC-6 冻结语义 R1 附注二（第 3/4/5/6 条）：安装前信任门与 ZIP 条目守卫。
// 本文件全部为只读检查（central directory 解析、解包产物走查、Sec 静态码签名校验、
// 公证票据存在性、卷标识读取），不含任何 moveItem/removeItem/createDirectory/Process 调用。
// 公证票据仅做存在性校验；深度验证属 Gatekeeper 域，如需 CLI 校验须另行提请复核扩展白名单。

enum UpdatePackageGuardError: Error, Equatable, Sendable {
    case zipUnreadable
    case zipNoEndRecord
    case zipCorruptCentralDirectory(String)
    case zipTooManyEntries(Int)
    case zipTotalTooLarge(Int)
    case zipEncryptedEntry(String)
    case zipUnsupportedMethod(Int, String)
    case zipSymlinkEntry(String)
    case zipPathEscape(String)
    case zipLayoutUnexpected(String)
    case walkFailed(String)
    case walkSymlinkFound(String)
    case walkTooManyFiles(Int)
    case walkTotalTooLarge(Int)
    case signatureInvalid(String)
    case teamMismatch(expected: String, actual: String)
    case ticketMissing
    case buildMismatch(expected: Int, actual: String)
}

enum UpdatePackageGuard {
    /// 守卫上限（冻结语义 R1 附注二第 5 条）。
    static let maxEntryCount = 20_000
    static let maxTotalUncompressedBytes = 400 * 1024 * 1024
    /// 公证票据文件（stapler 写入的 CMS blob；实测位于 Contents/CodeResources）。
    static let ticketPath = "Contents/CodeResources"

    struct ZIPEntry: Equatable, Sendable {
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let uncompressedBytes: Int
        let method: Int
        let encrypted: Bool
    }

    struct ZIPSummary: Equatable, Sendable {
        let entries: [ZIPEntry]
        var fileCount: Int { entries.filter { !$0.isDirectory }.count }
        var totalUncompressedBytes: Int { entries.reduce(0) { $0 + $1.uncompressedBytes } }
        var hasSymlinkEntry: Bool { entries.contains { $0.isSymlink } }
    }

    // MARK: - ZIP central directory 解析（只读）

    static func inspectZIP(at url: URL) -> Result<ZIPSummary, UpdatePackageGuardError> {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 0 else {
            return .failure(.zipUnreadable)
        }
        // 1) 定位 EOCD（0x06054b50），从尾部向后扫（含注释区）。
        let scanStart = max(0, data.count - 66_000)
        var eocd = -1
        var i = data.count - 22
        while i >= scanStart {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return .failure(.zipNoEndRecord) }
        let entryCount = Int(data.u16le(eocd + 10))
        let cdSize = Int(data.u32le(eocd + 12))
        let cdOffset = Int(data.u32le(eocd + 16))
        guard entryCount > 0 else { return .failure(.zipLayoutUnexpected("empty archive")) }
        guard entryCount <= maxEntryCount else { return .failure(.zipTooManyEntries(entryCount)) }
        guard cdOffset + cdSize <= data.count, cdOffset >= 0 else {
            return .failure(.zipCorruptCentralDirectory("cd range out of file"))
        }
        guard data.u32le(cdOffset) == 0x02014b50 else {
            return .failure(.zipCorruptCentralDirectory("bad cd signature"))
        }
        // 2) 逐条解析 central directory 记录。
        var entries: [ZIPEntry] = []
        entries.reserveCapacity(entryCount)
        var p = cdOffset
        for _ in 0..<entryCount {
            guard p + 46 <= data.count, data.u32le(p) == 0x02014b50 else {
                return .failure(.zipCorruptCentralDirectory("entry \(entries.count) header"))
            }
            let flags = Int(data.u16le(p + 8))
            let method = Int(data.u16le(p + 10))
            let uncomp = Int(data.u32le(p + 24))
            let nameLen = Int(data.u16le(p + 28))
            let extraLen = Int(data.u16le(p + 30))
            let commentLen = Int(data.u16le(p + 32))
            let externalAttrs = data.u32le(p + 38)
            guard p + 46 + nameLen <= data.count else {
                return .failure(.zipCorruptCentralDirectory("entry \(entries.count) name"))
            }
            guard let name = String(data: data.subdata(in: (p + 46)..<(p + 46 + nameLen)), encoding: .utf8) else {
                return .failure(.zipCorruptCentralDirectory("entry \(entries.count) name encoding"))
            }
            let encrypted = (flags & 0x1) != 0
            let unixMode = externalAttrs >> 16
            let isSymlink = (unixMode & 0xF000) == 0xA000
            let isDirectory = name.hasSuffix("/") || (externalAttrs & 0x10) != 0
            entries.append(ZIPEntry(
                name: name, isDirectory: isDirectory, isSymlink: isSymlink,
                uncompressedBytes: isDirectory ? 0 : uncomp, method: method, encrypted: encrypted
            ))
            p += 46 + nameLen + extraLen + commentLen
        }
        // 3) 条目级守卫。
        for entry in entries {
            if entry.encrypted { return .failure(.zipEncryptedEntry(entry.name)) }
            if entry.method != 0 && entry.method != 8 {
                return .failure(.zipUnsupportedMethod(entry.method, entry.name))
            }
            if entry.isSymlink { return .failure(.zipSymlinkEntry(entry.name)) }
            if entry.name.hasPrefix("/") || entry.name.contains("../") || entry.name.contains("..\\") {
                return .failure(.zipPathEscape(entry.name))
            }
            if entry.name.contains("\0") { return .failure(.zipPathEscape(entry.name)) }
        }
        // 4) 顶层布局：恰一个 SinClean.app/（可选 __MACOSX/ AppleDouble 树）。
        let topLevel = Set(entries.map { entry -> String in
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: true)
            return parts.first.map(String.init) ?? ""
        })
        guard topLevel == ["SinClean.app"] || topLevel == ["SinClean.app", "__MACOSX"] else {
            return .failure(.zipLayoutUnexpected("top-level: \(topLevel.sorted().joined(separator: ", "))"))
        }
        let summary = ZIPSummary(entries: entries)
        guard summary.totalUncompressedBytes <= maxTotalUncompressedBytes else {
            return .failure(.zipTotalTooLarge(summary.totalUncompressedBytes))
        }
        return .success(summary)
    }

    // MARK: - 解包产物走查（复核同限）

    static func verifyExtractedLayout(root: URL) -> Result<URL, UpdatePackageGuardError> {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return .failure(.walkFailed("list \(root.path)"))
        }
        let apps = items.filter { $0.hasSuffix(".app") }
        let others = items.filter { $0 != "__MACOSX" && !$0.hasSuffix(".app") }
        guard apps.count == 1, apps[0] == "SinClean.app", others.isEmpty else {
            return .failure(.zipLayoutUnexpected("extracted top-level: \(items.sorted().joined(separator: ", "))"))
        }
        let appURL = root.appendingPathComponent("SinClean.app", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.zipLayoutUnexpected("SinClean.app is not a directory"))
        }
        guard let enumerator = FileManager.default.enumerator(
            at: appURL, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey]
        ) else {
            return .failure(.walkFailed("enumerate \(appURL.path)"))
        }
        var fileCount = 0
        var totalBytes = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey]) else {
                return .failure(.walkFailed("stat \(url.path)"))
            }
            if values.isSymbolicLink == true {
                return .failure(.walkSymlinkFound(url.path))
            }
            if values.isDirectory != true {
                fileCount += 1
                totalBytes += values.fileSize ?? 0
            }
        }
        guard fileCount <= maxEntryCount else { return .failure(.walkTooManyFiles(fileCount)) }
        guard totalBytes <= maxTotalUncompressedBytes else { return .failure(.walkTotalTooLarge(totalBytes)) }
        return .success(appURL)
    }

    // MARK: - 代码签名信任门（Security.framework，只读）

    static func verifyCodeTrust(
        appURL: URL,
        expectedTeamID: String,
        expectedBundleID: String,
        expectedBuild: Int
    ) -> Result<Void, UpdatePackageGuardError> {
        // 1) 构建号与签名清单逐字一致（附注二勘误：构建号是硬门禁与防回退身份；
        //    清单 version 为分发层标识，不参与硬比对）。
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let infoDict = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            return .failure(.signatureInvalid("Info.plist unreadable"))
        }
        guard let buildString = infoDict["CFBundleVersion"] as? String else {
            return .failure(.buildMismatch(expected: expectedBuild, actual: "(missing)"))
        }
        guard buildString == String(expectedBuild) else {
            return .failure(.buildMismatch(expected: expectedBuild, actual: buildString))
        }
        // 2) 系统信任评估（R1 附注三第 3 条）：以锚定需求交 SecStaticCodeCheckValidity——
        //    Apple Developer ID 信任链经系统信任库真实评估（本地、无网络），
        //    同时覆盖代码完整性、叶证书 OU（Team ID）与代码标识。
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appURL as CFURL, SecCSFlags(rawValue: 0), &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return .failure(.signatureInvalid("SecStaticCodeCreateWithPath: \(createStatus)"))
        }
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\" and identifier \"\(expectedBundleID)\""
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementText as CFString, SecCSFlags(rawValue: 0), &requirement)
        guard requirementStatus == errSecSuccess, let anchored = requirement else {
            return .failure(.signatureInvalid("SecRequirementCreateWithString: \(requirementStatus)"))
        }
        let validityStatus = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), anchored)
        guard validityStatus == errSecSuccess else {
            return .failure(.signatureInvalid("anchored trust evaluation failed: \(validityStatus)"))
        }
        // 3) teamid 权威交叉核对（来自签名信息的结构化字段，非字符串摘要）。
        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF)
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else {
            return .failure(.signatureInvalid("SecCodeCopySigningInformation: \(infoStatus)"))
        }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String ?? "(missing)"
        guard teamID == expectedTeamID else {
            return .failure(.teamMismatch(expected: expectedTeamID, actual: teamID))
        }
        // 4) 公证票据存在性＝发布管线一致性预期（外形检查，不构成公证信任结论——
        //    R1 附注三第 3 条：公证强制执行点为 DMG/隔离首开与发布管线；深度本地验证列待复核边界）。
        let ticketURL = appURL.appendingPathComponent(ticketPath)
        guard let ticket = try? Data(contentsOf: ticketURL, options: .mappedIfSafe),
              ticket.count > 512,
              ticket[0] == 0x30 || ticket.starts(with: [0x73, 0x38, 0x63, 0x68])  // DER CMS 或 stapler 资源叉容器（"s8ch"）
        else {
            return .failure(.ticketMissing)
        }
        return .success(())
    }

    // MARK: - 卷标识

    static func volumeIdentifier(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]) else { return nil }
        return values.volumeUUIDString
    }
}

private extension Data {
    func u16le(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func u32le(_ offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset])
            | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16)
            | (UInt32(self[startIndex + offset + 3]) << 24)
    }
}
