import Foundation

// SC-6 失败回滚日志（冻结语义 §4.5）：纯本地追加文本，不联网、不上传、不删除。
// 相位 1 由本地夹具在 /tmp 演示；相位 2 接入真实更新流程时落 Application Support。
struct UpdateRollbackLog: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 追加一条回滚记录并返回该行原文（时间戳 UTC ISO-8601）。
    @discardableResult
    func record(
        channel: UpdateChannel,
        targetVersion: String,
        targetBuild: Int,
        category: String,
        reason: String,
        date: Date = Date()
    ) -> String {
        let timestamp = ISO8601DateFormatter().string(from: date)
        let line = "\(timestamp) channel=\(channel.rawValue) target=\(targetVersion)(\(targetBuild)) category=\(category) reason=\(reason)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
        return line
    }
}
