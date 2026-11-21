import Foundation

/// `POST /v1/messages` 的可选 `responseLanguage`：只影响 Bridge 自己生成的 owner 报告（任务/面板）的语言，
/// 不翻译用户正文，也不改变 agent 收到的内容。缺省（= 中文）时不发该字段，旧 Bridge 与旧请求体字节不变。
public enum MessageResponseLanguage: String, Sendable, Equatable, Codable {
    case zh, en

    /// 这条 wire 在当前显示语言下应请求的报告语言；nil = 省略字段（中文、非报告类指令）。
    public static func requested(forWire wire: String, resource: String? = nil) -> MessageResponseLanguage? {
        guard isReportCommand(wire) else { return nil }
        return (resource ?? KitL10n.resourceLanguage).hasPrefix("en") ? .en : nil
    }

    /// Bridge 同步生成报告的 owner 指令：面板 / 任务 / 查找 <词> / 关注 <名> / 取消关注 <名> / 关注列表（整串语法，与服务端同一空白集）。
    static func isReportCommand(_ wire: String) -> Bool {
        if let k = OwnerOperation.kind(ofWire: wire), k == .panel || k == .tasks { return true }
        let t = wire.unicodeScalars.split(whereSeparator: OwnerOperation.isSpace).map { String(String.UnicodeScalarView($0)) }
        guard let head = t.first else { return false }
        switch head {
        case "关注列表": return t.count == 1
        case "关注", "取消关注": return t.count == 2
        case "查找": return t.count >= 2
        default: return false
        }
    }
}

/// 一次发送的报告语言取值方式：首次发送取当前显示语言；重投沿用首次请求时记下的值（中文也要沿用，不能因界面切到英文而改变同一条消息的请求）。
public enum ResponseLanguageSource: Sendable, Equatable {
    case current
    case fixed(MessageResponseLanguage?)

    public func resolve(forWire wire: String) -> MessageResponseLanguage? {
        switch self {
        case .current: MessageResponseLanguage.requested(forWire: wire)
        case .fixed(let l): l
        }
    }
}
