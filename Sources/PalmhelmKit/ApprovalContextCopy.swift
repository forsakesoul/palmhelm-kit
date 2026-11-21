import Foundation

/// 审批卡「起因 / 改动」两段的固定文案（两端一致；设计稿 T2b）。
public enum ApprovalContextCopy {
    public static var causeTitle: String { KitL10n.string("起因") }
    public static var changeTitle: String { KitL10n.string("改动") }
    public static var causeUnavailable: String { KitL10n.string("起因没取到") }
    public static var retry: String { KitL10n.string("重试") }
    public static var expand: String { KitL10n.string("展开") }
    public static var collapse: String { KitL10n.string("收起") }
    public static var changeTruncated: String { KitL10n.string("只显示了前面一部分；完整内容在终端里") }

    /// 起因第一行的来源前缀。
    public static func originLabel(_ origin: String) -> String {
        switch origin {
        case InboundOrigin.feishu.rawValue: return KitL10n.string("来自飞书")
        case "terminal": return TranscriptCopy.typedInTerminal
        default: return KitL10n.string("来自 Palmhelm")
        }
    }

    /// 「来自飞书 · 今天 15:32」；无时间只有前半。
    public static func promptLine(_ p: ApprovalCause.Prompt, now: Date = Date()) -> String {
        guard let t = p.t else { return originLabel(p.origin) }
        return originLabel(p.origin) + " · " + TranscriptCopy.time(t, now: now)
    }

    /// 改动块首行：「Edit · 替换 1 处」「MultiEdit · 前 5 处，另有 2 处改动未展示」「Write · 新文件开头」。
    public static func changeHeader(_ c: ApprovalChange, toolName: String) -> String {
        if c.hidden == true { return toolName }
        switch c.kind {
        case "write": return KitL10n.format("%@ · 新文件开头", toolName)
        case "notebook": return KitL10n.format("%@ · 单元格新内容", toolName)
        default:
            let shown = c.hunks.count
            if c.more > 0 { return KitL10n.format("%@ · 前 %lld 处，另有 %lld 处改动未展示", toolName, shown, c.more) }
            return KitL10n.format("%@ · 替换 %lld 处", toolName, shown) + (c.hunks.first?.replaceAll == true ? KitL10n.string("（全部匹配）") : "")
        }
    }
}
