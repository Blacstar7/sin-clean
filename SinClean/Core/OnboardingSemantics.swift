import Foundation

// SC-5 首次使用语义载体（§1、§2、§7）。
// 口径见 work/SC-5-frozen-semantics.md：三屏硬上限、四项原则逐字措辞、中性文案。
// 本文件不申请任何权限、不读写任何用户文件。

enum OnboardingSemantics {
    /// 硬上限：不得出现第四屏。
    static let maximumStepCount = 3

    /// 完成标记只含布尔值与标记版本号。
    static let completionMarkerVersion = 1

    /// 禁用词（§7）：出现即视为不成立。
    static let bannedWording = [
        "垃圾", "无用文件", "废文件", "冗余", "junk", "garbage",
        "立即释放", "马上清理", "一键加速", "立即清理", "再不清理",
        "100% 安全", "绝对不会"
    ]

    static func containsBannedWording(_ text: String) -> Bool {
        bannedWording.contains { text.contains($0) }
    }
}

/// 四项核心安全原则（§2）：措辞逐字冻结，界面必须原文呈现。
enum OnboardingPrinciple: String, CaseIterable, Identifiable, Sendable {
    case readOnlyScan
    case nothingPreselected
    case trashOnly
    case localProcessing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnlyScan: String(localized: "只读扫描")
        case .nothingPreselected: String(localized: "默认不选")
        case .trashOnly: String(localized: "只进废纸篓")
        case .localProcessing: String(localized: "本地处理")
        }
    }

    /// 冻结措辞：不得改写、不得夸张。
    var statement: String {
        switch self {
        case .readOnlyScan:
            String(localized: "扫描只读取目录与文件的元数据，不移动、不删除、不修改任何文件。")
        case .nothingPreselected:
            String(localized: "分析结果默认全部不勾选；只有您逐项选择的项目才会被处理。")
        case .trashOnly:
            String(localized: "唯一的处理动作是把您选中的项目移入系统废纸篓，不做永久删除。")
        case .localProcessing:
            String(localized: "所有数据都在本机处理，不上传、不联网。")
        }
    }

    var symbol: String {
        switch self {
        case .readOnlyScan: "eye"
        case .nothingPreselected: "checklist"
        case .trashOnly: "trash"
        case .localProcessing: "lock.shield"
        }
    }
}

/// 三屏内容（§1 冻结）。
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case readOnlyAndSelection = 0
    case singleAction = 1
    case permissionsOnDemand = 2

    var id: Int { rawValue }

    static var count: Int { OnboardingSemantics.maximumStepCount }

    var title: String {
        switch self {
        case .readOnlyAndSelection: String(localized: "先看清楚")
        case .singleAction: String(localized: "只做一件事")
        case .permissionsOnDemand: String(localized: "权限按需")
        }
    }

    var subtitle: String {
        switch self {
        case .readOnlyAndSelection: String(localized: "分析不碰您的文件，也从不替您做选择。")
        case .singleAction: String(localized: "需要处理时，只做一件可恢复的事。")
        case .permissionsOnDemand: String(localized: "只有在真的需要时才申请权限，拒绝也能继续用。")
        }
    }

    var principles: [OnboardingPrinciple] {
        switch self {
        case .readOnlyAndSelection: [.readOnlyScan, .nothingPreselected]
        case .singleAction: [.trashOnly, .localProcessing]
        case .permissionsOnDemand: []
        }
    }

    var permissionNote: String? {
        switch self {
        case .permissionsOnDemand:
            String(localized: "本应用涉及两项可选权限：读取受保护目录、发送提醒。它们都只在您执行相关操作时才申请，说明会写明为什么需要、用来做什么、不做会怎样；被拒绝时其余功能照常可用。本引导不会申请任何权限。")
        default: nil
        }
    }

    var positionText: String { String(localized: "第 \(rawValue + 1) / \(OnboardingSemantics.maximumStepCount) 屏") }
}
