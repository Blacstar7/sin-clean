import Foundation

// SC-6 更新机制离线核心（冻结语义 §2）：更新清单模型、canonical 签名输入与严格解析。
// 本文件不联网、不删除任何文件、不触碰当前安装；校验流程见 UpdateVerifier.swift。

/// 三条更新频道（冻结语义 §3.1）。除此之外的任何字符串均为非法。
enum UpdateChannel: String, CaseIterable, Sendable {
    case `internal`
    case rc
    case release
}

enum UpdateManifestError: Error, Equatable, Sendable {
    case notJSON
    case manifestTooLarge(Int)
    case duplicateTopLevelKey(String)
    case fieldSetMismatch
    case fieldTypeMismatch(String)
    case unsupportedSchema(Int)
    case unknownChannel(String)
    case emptyVersion
    case malformedSHA256
    case negativePackageBytes
    case malformedSignature
}

struct UpdateManifest: Equatable, Sendable {
    /// 冻结语义 §2.1：schemaVersion 恒 1。
    static let schemaVersion = 1

    /// 冻结字段集（§2.1）：多一个少一个都不行。
    static let fieldNames: Set<String> = [
        "schemaVersion", "channel", "version", "build", "minSystemVersion",
        "packageURL", "packageSHA256", "packageBytes", "publishedAt", "notes", "signature",
    ]

    let channel: UpdateChannel
    let version: String
    let build: Int
    let minSystemVersion: String
    let packageURL: String
    let packageSHA256: String
    let packageBytes: Int
    let publishedAt: String
    let notes: String
    let signatureBase64: String

    /// canonical 签名输入（冻结语义 §2.3；R1 附注二第 1 条）：除 signature 外全部字段，
    /// 键名字典序、无多余空白的最小化 JSON 的 UTF-8 字节。实现口径＝与签发器同构的
    /// JSONSerialization（.sortedKeys＋.withoutEscapingSlashes），对解析后的类型化字段
    /// 序列化——两翼同构消除边缘字符（U+2028 等）字节分歧；重复键经解析 last-wins 归一。
    func canonicalPayload() throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": Self.schemaVersion,
            "channel": channel.rawValue,
            "version": version,
            "build": build,
            "minSystemVersion": minSystemVersion,
            "packageURL": packageURL,
            "packageSHA256": packageSHA256,
            "packageBytes": packageBytes,
            "publishedAt": publishedAt,
            "notes": notes,
        ]
        return try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private struct RawManifest: Decodable {
        let schemaVersion: Int
        let channel: String
        let version: String
        let build: Int
        let minSystemVersion: String
        let packageURL: String
        let packageSHA256: String
        let packageBytes: Int
        let publishedAt: String
        let notes: String
        let signature: String
    }

    /// 原始 JSON 顶层重复键检测（R1 附注三第 4 条）。
    /// 最小扫描器：只走顶层对象；键字符串按 JSON 转义规则解码（含 \uXXXX 与代理对）后比对；
    /// 值按嵌套深度跳过；扫描器自身不判定合法性（畸形输入交给后续 parse 的 notJSON）。
    static func firstDuplicateTopLevelKey(in data: Data) -> String? {
        var index = data.startIndex
        func skipWhitespace() {
            while index < data.endIndex {
                let byte = data[index]
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index = data.index(after: index) }
                else { break }
            }
        }
        func readHex4() -> UInt16? {
            var value: UInt16 = 0
            for _ in 0..<4 {
                guard index < data.endIndex else { return nil }
                let byte = data[index]
                index = data.index(after: index)
                let digit: UInt16
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(byte - UInt8(ascii: "A")) + 10
                default: return nil
                }
                value = (value << 4) | digit
            }
            return value
        }
        // 读取一个 JSON 字符串并返回解码后的内容；失败返回 nil。
        func readString() -> String? {
            guard index < data.endIndex, data[index] == UInt8(ascii: "\"") else { return nil }
            index = data.index(after: index)
            var result = Data()
            var utf16Units: [UInt16] = []
            func flushUnits() -> Bool {
                guard !utf16Units.isEmpty else { return true }
                let decoded = String(decoding: utf16Units, as: UTF16.self)
                result.append(contentsOf: decoded.utf8)
                utf16Units.removeAll()
                return true
            }
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                if byte == UInt8(ascii: "\"") {
                    return flushUnits() ? String(decoding: result, as: UTF8.self) : nil
                }
                if byte == UInt8(ascii: "\\") {
                    guard index < data.endIndex else { return nil }
                    let esc = data[index]
                    index = data.index(after: index)
                    switch esc {
                    case UInt8(ascii: "\""): result.append(UInt8(ascii: "\""))
                    case UInt8(ascii: "\\"): result.append(UInt8(ascii: "\\"))
                    case UInt8(ascii: "/"): result.append(UInt8(ascii: "/"))
                    case UInt8(ascii: "b"): result.append(0x08)
                    case UInt8(ascii: "f"): result.append(0x0C)
                    case UInt8(ascii: "n"): result.append(0x0A)
                    case UInt8(ascii: "r"): result.append(0x0D)
                    case UInt8(ascii: "t"): result.append(0x09)
                    case UInt8(ascii: "u"):
                        guard let unit = readHex4() else { return nil }
                        utf16Units.append(unit)
                    default: return nil
                    }
                } else {
                    if !utf16Units.isEmpty {
                        guard flushUnits() else { return nil }
                    }
                    result.append(byte)
                }
            }
            return nil
        }
        // 跳过一个完整值（感知字符串与嵌套）。
        func skipValue() -> Bool {
            skipWhitespace()
            guard index < data.endIndex else { return false }
            let byte = data[index]
            if byte == UInt8(ascii: "\"") { return readString() != nil }
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                index = data.index(after: index)
                var inner = 1
                var inString = false
                while index < data.endIndex && inner > 0 {
                    let current = data[index]
                    index = data.index(after: index)
                    if inString {
                        if current == UInt8(ascii: "\\") {
                            guard index < data.endIndex else { return false }
                            index = data.index(after: index)
                        } else if current == UInt8(ascii: "\"") {
                            inString = false
                        }
                    } else {
                        if current == UInt8(ascii: "\"") { inString = true }
                        else if current == UInt8(ascii: "{") || current == UInt8(ascii: "[") { inner += 1 }
                        else if current == UInt8(ascii: "}") || current == UInt8(ascii: "]") { inner -= 1 }
                    }
                }
                return inner == 0
            }
            while index < data.endIndex {
                let current = data[index]
                if current == UInt8(ascii: ",") || current == UInt8(ascii: "}")
                    || current == UInt8(ascii: "]") || current == 0x20 || current == 0x09
                    || current == 0x0A || current == 0x0D { break }
                index = data.index(after: index)
            }
            return true
        }
        skipWhitespace()
        guard index < data.endIndex, data[index] == UInt8(ascii: "{") else { return nil }
        index = data.index(after: index)
        var seen = Set<String>()
        while true {
            skipWhitespace()
            guard index < data.endIndex else { return nil }
            if data[index] == UInt8(ascii: "}") { return nil }
            guard let key = readString() else { return nil }
            if !seen.insert(key).inserted { return key }
            skipWhitespace()
            guard index < data.endIndex, data[index] == UInt8(ascii: ":") else { return nil }
            index = data.index(after: index)
            guard skipValue() else { return nil }
            skipWhitespace()
            guard index < data.endIndex else { return nil }
            if data[index] == UInt8(ascii: ",") {
                index = data.index(after: index)
            } else if data[index] == UInt8(ascii: "}") {
                return nil
            } else {
                return nil
            }
        }
    }

    /// 严格解析（冻结语义 §2.5 前两道＋R1 附注二第 1 条大小上限）：JSON 可解析、
    /// 大小 ≤ 64 KiB、字段集恰好匹配、类型正确、schemaVersion == 1、频道为三个合法值之一。
    static func parse(_ data: Data) -> Result<UpdateManifest, UpdateManifestError> {
        guard data.count <= 65_536 else { return .failure(.manifestTooLarge(data.count)) }
        // R1 附注三第 4 条：归一化之前拒绝原始 JSON 的重复顶层键（含转义等价键名）。
        if let duplicate = firstDuplicateTopLevelKey(in: data) {
            return .failure(.duplicateTopLevelKey(duplicate))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return .failure(.notJSON) }
        guard Set(dict.keys) == fieldNames else { return .failure(.fieldSetMismatch) }
        let raw: RawManifest
        do {
            raw = try JSONDecoder().decode(RawManifest.self, from: data)
        } catch {
            return .failure(.fieldTypeMismatch(String(describing: type(of: error))))
        }
        guard raw.schemaVersion == schemaVersion else { return .failure(.unsupportedSchema(raw.schemaVersion)) }
        guard let channel = UpdateChannel(rawValue: raw.channel) else { return .failure(.unknownChannel(raw.channel)) }
        guard !raw.version.isEmpty else { return .failure(.emptyVersion) }
        let shaPattern = #"^[0-9a-f]{64}$"#
        guard raw.packageSHA256.range(of: shaPattern, options: .regularExpression) != nil
        else { return .failure(.malformedSHA256) }
        guard raw.packageBytes >= 0 else { return .failure(.negativePackageBytes) }
        guard let signature = Data(base64Encoded: raw.signature), signature.count == 64
        else { return .failure(.malformedSignature) }
        return .success(UpdateManifest(
            channel: channel,
            version: raw.version,
            build: raw.build,
            minSystemVersion: raw.minSystemVersion,
            packageURL: raw.packageURL,
            packageSHA256: raw.packageSHA256,
            packageBytes: raw.packageBytes,
            publishedAt: raw.publishedAt,
            notes: raw.notes,
            signatureBase64: raw.signature
        ))
    }
}
