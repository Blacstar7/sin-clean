import Foundation

// SC-6 冻结语义修订记录 R1（2026-09-30）§2.4：正式更新签名公钥内嵌。
// 公钥 SHA-256＝d39b17c5b3380ff956d7764a8413a9bd48b35700d0b63b82475d29174d9dd370。
// 私钥由用户自管（PSW/），不入工程、不入归档；与 Developer ID 证书为两套独立信任链。
// 密钥轮换须以新的冻结语义修订记录登记新公钥指纹；本常量一经冻结不得改写。

enum UpdatePublicKey {
    /// Ed25519 公钥原始 32 字节（十六进制常量，冻结取值）。
    static let rawHex = "07687f65d084226b2eaf87ff0ef368002b8ff242dfa6574b741ecd58c42d0189"

    static var rawData: Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rawHex.count / 2)
        var index = rawHex.startIndex
        while index < rawHex.endIndex {
            let next = rawHex.index(index, offsetBy: 2)
            guard next <= rawHex.endIndex, let byte = UInt8(rawHex[index..<next], radix: 16) else {
                preconditionFailure("UpdatePublicKey.rawHex 不是合法的 64 位十六进制常量")
            }
            bytes.append(byte)
            index = next
        }
        precondition(bytes.count == 32, "Ed25519 公钥必须是 32 字节")
        return Data(bytes)
    }
}
