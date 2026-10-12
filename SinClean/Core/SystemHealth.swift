import Foundation

// SC-4：本文件只保留系统健康模块共用的**数据形状**与格式化工具。
// 旧版的状态快照类型、事实提供者与刷新视图模型已全部删除，避免出现两套互相矛盾的指标口径：
// SC-4.1 要求内存以系统压力为准、CPU 以持续状态为准、运行时间与核心数退出扣分，
// 这些语义现在只有一份实现（见 SinClean/Core 的语义与采样文件），界面由共享的仪表盘模型驱动。

struct BatterySnapshot: Equatable {
    let level: Double
    let isCharging: Bool
    let timeRemaining: TimeInterval?
}

struct NetworkSnapshot: Equatable {
    let isConnected: Bool
    let interfaceName: String
    let uploadBytesPerSecond: Double
    let downloadBytesPerSecond: Double
}

enum SystemFormatters {
    static var bytes: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }

    static var rate: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .decimal
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }

    static func bytesPerSecond(_ value: Double) -> String {
        String(localized: "\(rate.string(fromByteCount: Int64(max(0, value))))/秒")
    }

    static func uptime(_ interval: TimeInterval) -> String {
        let hours = max(0, Int(interval / 3_600))
        let days = hours / 24
        let remainingHours = hours % 24
        return days > 0 ? String(localized: "\(days) 天 \(remainingHours) 小时") : String(localized: "\(remainingHours) 小时")
    }
}
