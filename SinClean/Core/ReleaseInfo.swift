import Foundation

/// SC-6 发布信息（冻结语义 §3、§6）：版本号、构建号、预发布通道与更新频道
/// 全部来自构建配置注入的 Info.plist 值，界面只读展示，不做任何网络动作。
struct ReleaseInfo: Equatable, Sendable {
    let marketingVersion: String
    let buildNumber: String
    let prereleaseChannel: String?
    let updateChannel: UpdateChannel?
    let copyright: String

    static func current(bundle: Bundle = .main) -> ReleaseInfo {
        let info = bundle.infoDictionary
        return ReleaseInfo(
            marketingVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            buildNumber: info?["CFBundleVersion"] as? String ?? "",
            prereleaseChannel: info?["SinCleanPrereleaseChannel"] as? String,
            updateChannel: (info?["SinCleanUpdateChannel"] as? String).flatMap(UpdateChannel.init(rawValue:)),
            copyright: info?["NSHumanReadableCopyright"] as? String ?? ""
        )
    }

    /// 关于页版本行（冻结语义 §6.1）：版本 1.0.0（构建 8）。
    var versionLine: String { String(localized: "版本 \(marketingVersion)（构建 \(buildNumber)）") }

    /// 关于页通道行；正式版构建无预发布标记时缺省。
    var channelLine: String? { prereleaseChannel.map { String(localized: "通道 \($0)") } }

    var buildNumberInt: Int? { Int(buildNumber) }
}
