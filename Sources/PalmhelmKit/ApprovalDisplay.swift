import Foundation

/// 审批相关字段的“显示值”：只替换 Bridge 标出的生成原子范围（隐藏/路径/链接/图片），其余逐字保留。
/// 动作载荷、digest、选项编号与可选性仍读原字段；这些属性只给界面显示用。
extension ApprovalView {
    /// 固定摘要按 kind/count 语义本地化（Bridge 钩子生成的“提问（N 题）”“计划（…）”）；其余走范围替换。用户/自定义摘要不全局替换。
    public var summaryDisplayed: String {
        if pendingKind == .question, let n = questionCount, summary == "提问（\(n) 题）" { return KitL10n.format("提问（%lld 题）", n) }
        if pendingKind == .plan, summary == "计划（可打回，不能经钩子批准）" { return KitL10n.string("计划（可打回，不能经钩子批准）") }
        return BridgeDisplayText.render(summary, lossy: summaryDisplaySpans).text
    }
}
extension ProjectedQuestion {
    public var questionDisplayed: String { BridgeDisplayText.render(question, lossy: questionDisplaySpans).text }
}
extension ProjectedOption {
    public var labelDisplayed: String { BridgeDisplayText.render(label, lossy: labelDisplaySpans).text }
    public var descriptionDisplayed: String { BridgeDisplayText.render(description, lossy: descriptionDisplaySpans).text }
}
extension ApprovalText {
    /// 计划正文的显示值：整段等于“未附计划正文”占位时走既有换文案；真实计划逐字保留，只替换生成范围。读取时求值，语言切换即时生效。
    public static func planDisplayed(_ plan: String, spans: LossyDisplaySpans?) -> String {
        let t = planText(plan)
        return t != plan ? t : BridgeDisplayText.render(plan, lossy: spans).text
    }
}
extension ApprovalBody {
    public var planDisplayed: String? { plan.map { ApprovalText.planDisplayed($0, spans: planDisplaySpans) } }
}
extension ApprovalChange {
    public var pathDisplayed: String { BridgeDisplayText.render(path, lossy: pathDisplaySpans).text }
}
extension ProjectedOption {
    public var previewDisplayed: String? { preview.map { BridgeDisplayText.render($0, lossy: previewDisplaySpans).text } }
}
extension ApprovalHunk {
    public var oldDisplayed: String? { old.map { BridgeDisplayText.render($0, lossy: oldDisplaySpans).text } }
    public var newDisplayed: String { BridgeDisplayText.render(new, lossy: newDisplaySpans).text }
}
extension ApprovalCause.Prompt {
    public var textDisplayed: String { BridgeDisplayText.render(text, lossy: textDisplaySpans).text }
}
extension ApprovalCause.Note {
    public var textDisplayed: String { BridgeDisplayText.render(text, lossy: textDisplaySpans).text }
}
extension SearchHit {
    public var snippetDisplayed: DisplayedText { BridgeDisplayText.render(snippet, lossy: snippetDisplaySpans) }
}
