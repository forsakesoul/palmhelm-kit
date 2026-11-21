import Foundation

/// 撤回成功后回填原文的规则（两端共用）。
/// 原文只来自本机发送时保存的记录；不从 command 正文按外形猜测署名（用户自己写的同形首行不能被误删，O1-331 R1）。
public enum WithdrawnDraft {
    /// 输入框是否没有可替换的内容（空白文本即视为空）。
    public static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
