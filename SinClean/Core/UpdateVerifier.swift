import CryptoKit
import Foundation

// SC-6 更新机制离线核心（冻结语义 §2.5、§3、§4）：清单签名校验、频道判定、
// 更新包校验与磁盘预检。本文件不联网、不删除任何文件、不触碰当前安装；
// 全部校验失败都发生在触碰当前安装之前（冻结语义 §4.1）。

enum UpdateRejection: Error, Equatable, Sendable {
    case malformedManifest(UpdateManifestError)
    case channelMismatch(manifest: String, build: String)
    case notNewer(manifestBuild: Int, currentBuild: Int)
    case systemTooOld(required: String, actual: String)
    case invalidSignerKey
    case signatureMismatch
    case packageMissing
    case packageUnreadable
    case packageSizeMismatch(expected: Int, actual: Int)
    case packageHashMismatch
    case insufficientDiskSpace(required: Int, available: Int)
}

enum UpdateVerifier {
    /// 冻结语义 §4.3：暂存前预检，可用空间须 ≥ 包字节数 + 64 MiB 余量。
    static let diskSlackBytes = 67_108_864

    /// 逐字节 SHA-256（流式读取，避免大文件占内存）。
    static func sha256(of fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 1 << 20)
            if let chunk, !chunk.isEmpty {
                hasher.update(data: chunk)
                return true
            }
            return false
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func availableBytes(volume: URL) -> Int? {
        // 小容量卷宗上 ImportantUsage 口径实测会返回 0，退回普通可用容量口径（冻结语义 §4.3 不变）。
        if let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return Int(clamping: capacity)
        }
        if let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity {
            return Int(clamping: capacity)
        }
        return nil
    }

    static func isSystemVersion(_ system: String, atLeast minimum: String) -> Bool {
        system.compare(minimum, options: .numeric) != .orderedAscending
    }

    /// 完整校验管线（冻结语义 §2.5，任一失败即拒绝，拒绝是终态）。
    /// 只做校验与决策，不产生任何写入、删除或网络动作。
    static func verify(
        manifestData: Data,
        packageAt packageURL: URL,
        currentBuild: Int,
        channel: UpdateChannel,
        signerPublicKeyRaw: Data,
        systemVersion: String,
        stagingVolume: URL
    ) -> Result<UpdateManifest, UpdateRejection> {
        let manifest: UpdateManifest
        switch verifyManifest(
            manifestData: manifestData,
            currentBuild: currentBuild,
            channel: channel,
            signerPublicKeyRaw: signerPublicKeyRaw,
            systemVersion: systemVersion
        ) {
        case .failure(let error): return .failure(error)
        case .success(let verified): manifest = verified
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return .failure(.packageMissing) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: packageURL.path),
              let actualBytes = attributes[.size] as? Int
        else { return .failure(.packageUnreadable) }
        guard actualBytes == manifest.packageBytes else {
            return .failure(.packageSizeMismatch(expected: manifest.packageBytes, actual: actualBytes))
        }
        guard let digest = sha256(of: packageURL) else { return .failure(.packageUnreadable) }
        guard digest == manifest.packageSHA256 else { return .failure(.packageHashMismatch) }

        let required = manifest.packageBytes + diskSlackBytes
        guard let available = availableBytes(volume: stagingVolume) else {
            return .failure(.insufficientDiskSpace(required: required, available: 0))
        }
        guard available >= required else {
            return .failure(.insufficientDiskSpace(required: required, available: available))
        }
        return .success(manifest)
    }

    /// 清单级校验（SC-6 R1 相位 2 新增入口）：解析、频道一致、构建号更新、
    /// 最低系统版本与 Ed25519 签名——检查更新阶段（更新包尚未下载）使用；
    /// 包级校验（字节数／SHA-256／磁盘余量）在下载完成后由 `verify` 全管线承担。
    static func verifyManifest(
        manifestData: Data,
        currentBuild: Int,
        channel: UpdateChannel,
        signerPublicKeyRaw: Data,
        systemVersion: String
    ) -> Result<UpdateManifest, UpdateRejection> {
        let manifest: UpdateManifest
        switch UpdateManifest.parse(manifestData) {
        case .failure(let error): return .failure(.malformedManifest(error))
        case .success(let parsed): manifest = parsed
        }
        guard manifest.channel == channel else {
            return .failure(.channelMismatch(manifest: manifest.channel.rawValue, build: channel.rawValue))
        }
        guard manifest.build > currentBuild else {
            return .failure(.notNewer(manifestBuild: manifest.build, currentBuild: currentBuild))
        }
        guard isSystemVersion(systemVersion, atLeast: manifest.minSystemVersion) else {
            return .failure(.systemTooOld(required: manifest.minSystemVersion, actual: systemVersion))
        }
        guard let signature = Data(base64Encoded: manifest.signatureBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signerPublicKeyRaw)
        else { return .failure(.invalidSignerKey) }
        guard let payload = try? manifest.canonicalPayload(),
              publicKey.isValidSignature(signature, for: payload)
        else { return .failure(.signatureMismatch) }
        return .success(manifest)
    }
}
