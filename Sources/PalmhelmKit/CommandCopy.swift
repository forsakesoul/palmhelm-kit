import Foundation

/// 命令 reason 的显示文案（#63 切片 ①）。key 与 Bridge 的 internal/uimsg 一致；文字在本包的 Localizable.xcstrings（源语言 en）。
/// 每次取值都解析，不缓存：语言切换由下一次取值生效。没有译文的语言（ja 暂缺）回退英文。
public enum CommandCopy {
    /// `locale` 缺省（autoupdatingCurrent）= 用当前显示语言（DisplayLanguage 或 KitL10n.$locale）；显式 locale 按该语言的 .lproj 取值：
    /// String(localized:locale:) 不会改变查表所用的 bundle 语言，所以自己选表。
    public static func text(_ reason: CommandReason, locale: Locale = .autoupdatingCurrent) -> String {
        if locale == .autoupdatingCurrent {
            return KitL10n.string(reason.rawValue, default: reason.english)
        }
        return KitL10n.$locale.withValue(locale) { KitL10n.string(reason.rawValue, default: reason.english) }
    }
}

/// Bridge 的 displayMessage.key 中，本包已有文案的那几个（与 internal/uimsg 的 Command* 常量一致）。
public enum CommandReason: String, CaseIterable, Sendable {
    case queueExpired = "command.queue_expired"
    case queueExpiredUncertain = "command.queue_expired_uncertain"
    case withdrawn = "command.withdrawn"
    case merged = "command.merged"

    /// 源语言（en）文本，只在查不到译文时使用。
    var english: String {
        switch self {
        case .queueExpired: "Expired, not sent"
        case .queueExpiredUncertain: "Queueing stopped; earlier results unconfirmed"
        case .withdrawn: "Withdrawn, not sent"
        case .merged: "Merged into the current turn"
        }
    }
}
