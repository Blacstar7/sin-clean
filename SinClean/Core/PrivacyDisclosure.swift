import Foundation

// SC-5 隐私页语义载体（§5、§6）。
// 每条声明都必须对应一个**可验证事实**，并写明「如何自行验证」；
// 不得出现无法验证的承诺。本文件不联网、不读写任何用户文件。

struct PrivacyClaim: Identifiable, Equatable, Sendable {
    let id: String
    let claim: String
    let verifiableFact: String
    let howToVerify: String
}

enum PrivacyDisclosure {
    /// 冻结的五条声明（§5 表格）。新增声明必须同时给出可验证事实与验证方法。
    static let claims: [PrivacyClaim] = [
        PrivacyClaim(
            id: "no-upload",
            claim: String(localized: "不上传任何数据。"),
            verifiableFact: String(localized: "除您主动点按「检查更新…」（获取更新清单）与确认后的「下载并安装」（下载更新包）两处、且仅连接 blacstar7.github.io 外，应用进程没有任何网络套接字；网络接口调用只存在于更新下载实现文件。"),
            howToVerify: String(localized: "在不点按「检查更新」的状态下，于终端对运行中的应用执行 `lsof -a -p <进程号> -i`，输出应为空；在源码中检索网络接口名，命中应仅存在于更新下载实现文件。")
        ),
        PrivacyClaim(
            id: "read-only-scan",
            claim: String(localized: "扫描是只读的。"),
            verifiableFact: String(localized: "扫描前后目录集合与文件元数据（占用块数、inode、链接数、容量、纳秒修改时间）零变化；源码中没有写入或删除调用。"),
            howToVerify: String(localized: "对比扫描前后同一目录的文件清单与 `stat` 结果；或在源码中检索写入与删除接口名。")
        ),
        PrivacyClaim(
            id: "trash-only",
            claim: String(localized: "唯一的处理动作是把您选中的项目移入系统废纸篓。"),
            verifiableFact: String(localized: "整个工程只有一个系统废纸篓调用点；面向用户文件没有任何永久删除入口。"),
            howToVerify: String(localized: "在源码中检索废纸篓与永久删除接口名，核对调用点数量与归属。")
        ),
        PrivacyClaim(
            id: "local-storage",
            claim: String(localized: "数据只保存在本机，并且可以随时清除。"),
            verifiableFact: String(localized: "系统健康趋势保存在应用自身的 Application Support 目录；设置页可一键清空，清空后采样点数为 0。"),
            howToVerify: String(localized: "打开「设置」查看存储位置与当前采样点数，点击「清空趋势数据」后确认点数归零。")
        ),
        PrivacyClaim(
            id: "no-telemetry",
            claim: String(localized: "不含遥测、崩溃上报或第三方分析。"),
            verifiableFact: String(localized: "工程中不存在任何遥测、崩溃上报或第三方分析 SDK 的引用；除手动「检查更新／下载安装」连接 blacstar7.github.io 外，无任何网络端点。"),
            howToVerify: String(localized: "在源码中检索相关依赖与接口名，命中应为 0；在不点按「检查更新」的状态下，`lsof` 实测亦无网络套接字。")
        )
    ]

    /// 不可验证承诺的禁用词：出现即视为不成立。
    static let unverifiablePromises = [
        "绝不泄露", "绝对安全", "军用级加密", "100% 安全", "永不联网", "完全匿名"
    ]

    static func containsUnverifiablePromise(_ text: String) -> Bool {
        unverifiablePromises.contains { text.contains($0) }
    }
}
