import Foundation

// 对话身份（设计文档 reins-thread-identity §4.2、§8）：两端共用的标题、身份行、位置行与线程编号。
// 只拼 Bridge 已投影的字段，不在客户端再推断 agent 名的含义。

public enum AgentRole: String, Sendable, CaseIterable {
    case design, execute, advisor

    public var label: String {
        switch self { case .design: KitL10n.string("设计"); case .execute: KitL10n.string("执行"); case .advisor: KitL10n.string("顾问") }
    }

    /// 编组内的固定顺序：设计 → 执行 → 顾问。
    public var order: Int {
        switch self { case .design: 0; case .execute: 1; case .advisor: 2 }
    }
}

public enum AgentStatus: String, Sendable {
    case working, idle, done, blocked, unknown

    public var label: String {
        switch self {
        case .working: KitL10n.string("工作中")
        case .idle: KitL10n.string("空闲")
        case .done: KitL10n.string("已完成")
        case .blocked: KitL10n.string("等你")
        case .unknown: KitL10n.string("未知")
        }
    }
}

public enum ThreadIdentity {
    /// 线程编号 = 机器 + 目标；旧 Bridge 没有 id 时用 "local"，多台 Mac 时不互相覆盖。
    public static func key(bridgeId: String?, targetId: String) -> String {
        "\(bridgeId ?? "local")/\(targetId)"
    }

    /// 这些名字说明不了是哪一个会话（社区常见的“都叫 Claude Code / fish”）。
    static let genericNames: Set<String> = ["claude code", "claude", "codex", "pi", "fish", "zsh", "bash", "sh", "shell", "terminal", "agents", "main"]

    static func isGeneric(_ s: String?) -> Bool {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return true }
        return genericNames.contains(s.lowercased())
    }

    public static func kindLabel(_ kind: String?) -> String? {
        guard let k = kind?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
        switch k.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "pi": return "Pi"
        default: return k.prefix(1).uppercased() + k.dropFirst()
        }
    }

    public static func role(_ t: TargetSummary) -> AgentRole? { t.role.flatMap(AgentRole.init(rawValue:)) }

    public static func status(_ t: TargetSummary) -> AgentStatus? { t.status.flatMap(AgentStatus.init(rawValue:)) }

    /// 行标题回退：会话主题 → 标签名（非通用名）→ “工作区 · 项目” → 项目名。
    public static func title(_ t: TargetSummary) -> String {
        if let topic = t.topic?.text.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty { return topic }
        if let tab = t.location?.tab, !isGeneric(tab) { return tab }
        if let ws = t.location?.workspace, !isGeneric(ws), ws != t.projectName { return "\(ws) · \(t.projectName)" }
        return t.projectName
    }

    /// 对话页顶部标题（两端共用）：“角色/agent 名 · 项目”。只用 Bridge 已投影的身份字段，不读 topic 与消息正文，
    /// 所以会话主题或最新消息变化不会改标题；列表、通知、搜索仍用 `title`。
    public static func conversationTitle(_ t: TargetSummary?) -> String {
        guard let t else { return ScreenCopy.tabChat }
        func clean(_ s: String?) -> String? {
            guard let v = s?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        var left: String? = clean(t.role).flatMap(AgentRole.init(rawValue:))?.label
        if left == nil, let n = clean(t.agentName), !isGeneric(n), !isGeneratedTaskName(n) { left = n }
        if left == nil, let tab = clean(t.location?.tab), !isGeneric(tab) { left = tab }
        if left == nil, let pane = clean(t.location?.pane) {
            left = KitL10n.format("窗格 %@", pane.split(separator: ":").last.map(String.init) ?? pane)
        }
        let project = clean(t.repo?.name) ?? clean(t.projectName).flatMap { isGeneratedTaskName($0) ? nil : $0 }
        let parts = [left, project].compactMap { $0 }
        if parts.count == 2, parts[0] == parts[1] { return parts[0] }
        return parts.isEmpty ? ScreenCopy.tabChat : parts.joined(separator: " · ")
    }

    /// Herdr 自动任务名 task_<十六进制>_<角色[序号]>，整串匹配；只用于显示过滤，不从中解析角色。
    static func isGeneratedTaskName(_ s: String) -> Bool {
        let p = s.split(separator: "_", omittingEmptySubsequences: false)
        guard p.count == 3, p[0] == "task", p[1].count >= 6, p[1].allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
              let role = p[2].first, role.isLowercase, role.isASCII else { return false }
        return p[2].allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }

    /// 身份行：“种类 · 角色 组号 · 项目”。没有角色时用非通用的 agent 名；未命名 agent 只剩种类与项目。
    /// 身份行：类型 · 角色（有角色时）或 agent 名 · 项目名。视角已不影响身份行（h10a：编组 / 分支去重随视角删除）。
    public static func line(_ t: TargetSummary) -> String {
        var parts: [String] = []
        if let k = kindLabel(t.kind) { parts.append(k) }
        if let r = role(t) {
            parts.append([r.label, t.groupShort].compactMap { $0 }.joined(separator: " "))
        } else if let name = t.agentName, !isGeneric(name), name != t.projectName {
            parts.append(name)
        }
        parts.append(t.projectName)
        return parts.joined(separator: " · ")
    }

    /// 位置行：“工作区 › 标签 · 窗格 p1T”；什么都没有时为 nil。
    public static func location(_ t: TargetSummary) -> String? {
        guard let l = t.location else { return nil }
        let place = [l.workspace, l.tab].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " › ")
        let pane = l.pane.map { KitL10n.format("窗格 %@", $0.split(separator: ":").last.map(String.init) ?? $0) } // Herdr 窗格号带工作区前缀（w1:p2），只显示窗格部分
        let s = [place.isEmpty ? nil : place, pane].compactMap { $0 }.joined(separator: " · ")
        return s.isEmpty ? nil : s
    }
}

/// 最近记录的模型的展示文案（两端共用，#27）：「最近使用：<id>」（Claude / Pi）或「最近配置：<id>」（Codex）。
/// basis 未知或 id 为空时不展示（返回 nil），不猜测。
public enum ModelText {
    private static let efforts: Set<String> = ["off", "none", "minimal", "low", "medium", "high", "xhigh", "max"]
    private static func suffix(_ m: TargetModel, spoken: Bool = false) -> String {
        guard let effort = m.effort, efforts.contains(effort) else { return "" }
        return (spoken ? KitL10n.string("，思考等级 ") : " · ") + effort
    }
    public static func label(basis: String) -> String? {
        switch basis {
        case "last_used": return KitL10n.string("最近使用")
        case "last_configured": return KitL10n.string("最近配置")
        default: return nil
        }
    }

    public static func line(_ m: TargetModel) -> String? {
        guard !m.id.isEmpty, let l = label(basis: m.basis) else { return nil }
        return KitL10n.format("%@：%@", l, m.id) + suffix(m)
    }

    /// 目标上可展示的模型文案；没有模型、basis 未知或 id 为空时为 nil。离线（没连上 Bridge）时是上一份快照，标「上次记录」，不当作当前。
    public static func line(_ t: TargetSummary, offline: Bool = false) -> String? {
        guard let l = t.model.flatMap(line) else { return nil }
        return offline ? KitL10n.format("上次记录 · %@", l) : l
    }

    /// 线程页那一行：没有可展示的模型写「模型未提供」。
    public static func thread(_ t: TargetSummary?, offline: Bool) -> String {
        t.flatMap { line($0, offline: offline) } ?? KitL10n.string("模型未提供")
    }

    /// 无障碍读出来源、完整模型和等级；没有模型时由调用方决定是否给占位。
    public static func accessibility(_ t: TargetSummary?, offline: Bool = false) -> String? {
        guard let m = t?.model, !m.id.isEmpty, let l = label(basis: m.basis) else { return nil }
        let text = KitL10n.format("%@：%@", l, m.id) + suffix(m, spoken: true)
        return offline ? KitL10n.format("上次记录 · %@", text) : text
    }

    /// 列表副标题简写 id 与等级；不可展示时为 nil，不留下分隔符。
    public static func short(_ t: TargetSummary, offline: Bool = false) -> String? {
        guard line(t) != nil, let m = t.model else { return nil }
        let text = m.id + suffix(m)
        return offline ? KitL10n.format("上次记录 %@", text) : text
    }
}

/// “等你”的待办种类：本期只接审批，提问与计划随提问通道接入（§11）。
public enum PendingKind: String, Sendable {
    case approval, question, plan
}

public enum ApprovalText {
    /// exact 优先用目标 ID；旧 Bridge / candidate 只按唯一标签回退，不能把同项目的另一个 agent 当来源。
    public static func target(of approval: ApprovalView, in targets: [TargetSummary]) -> TargetSummary? {
        if approval.attribution == ApprovalAttribution.exact.rawValue, let id = approval.targetId {
            return targets.first { $0.id == id }
        }
        let name = projectName(ofLabel: approval.targetLabel)
        let hits = targets.filter { $0.projectName == name }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Bridge 对按目录推测的归属在 targetLabel 前加的前缀（只是展示推断，不是身份认证）。
    /// Bridge 的协议前缀（与 approvals/service.go 输出一致），只用于解析，不本地化。
    public static let candidatePrefix = "候选："
    /// 显示用的同义前缀（按访问取当前语言）；解析一律用 candidatePrefix。
    public static var candidateDisplayPrefix: String { KitL10n.string("候选：") }
    /// 审批归属的项目名：去掉“候选：”前缀（两端的待答计数与按目标分组都用这一条规则）。
    public static func projectName(ofLabel label: String) -> String {
        label.hasPrefix(candidatePrefix) ? String(label.dropFirst(candidatePrefix.count)) : label
    }
    /// 展示用的审批标签：协议前缀换成当前语言的前缀，其余原样；解析仍用 projectName(ofLabel:)。
    public static func displayLabel(_ label: String) -> String {
        label.hasPrefix(candidatePrefix) ? candidateDisplayPrefix + label.dropFirst(candidatePrefix.count) : label
    }

    /// 来源标签：只认识 codex；没有 provider（旧 Bridge / Claude）或未知的 provider 都不显示，不替别家贴标签。
    public static func providerLabel(_ a: ApprovalView) -> String? {
        a.provider == "codex" ? "Codex" : nil
    }
    /// 卡片 / 列表的身份行：有来源标签时在前面加「Codex · 」。
    public static func identityLine(_ a: ApprovalView, base: String) -> String {
        providerLabel(a).map { "\($0) · \(base)" } ?? base
    }

    // MARK: 审批选项的展示（wire 不变；每次访问按当前语言查表，不存已翻译副本）
    // Bridge 的审批固定文案（approval/constants.go）是旧 wire 的中文原文，没有稳定 code：
    // 只在完整等于已知常量（或已知生成语法）时换成本地化句子，其余服务端/agent 原文逐字保留。
    private static let ruleDisabled = "本期只允许一次，不记住规则"
    private static let ruleUnsupported = "agent 建议了一条本期不支持展示的规则"
    private static let rulePrefix = "允许规则："
    private static let omittedHead = "另有 ", omittedTail = " 条 agent 建议未展示"
    private static let reviseHintWire = "同一计划已连续打回多次，agent 可能停止修改；可到 Mac 上处理"
    private static let planBodyMissingWire = "此请求未附计划正文，请回终端核对"

    /// 审批卡对 options 的唯一分类：两端都消费它。动作只来自已知的 allow_once / deny；
    /// 记住规则只读（不算动作）；未知 kind 无动作但只读显示（Label/detail/原因原样），不混入“记住规则”的条数。
    public struct OptionPresentation: Equatable, Sendable {
        public var allow: ApprovalOption?
        public var deny: ApprovalOption?
        public var rules: [ApprovalOption] = []
        public var unknown: [ApprovalOption] = []
    }
    public static func presentation(of options: [ApprovalOption]) -> OptionPresentation {
        var p = OptionPresentation()
        for o in options {
            switch o.kind {
            case .allowOnce: if p.allow == nil { p.allow = o }
            case .deny: if p.deny == nil { p.deny = o }
            case .allowRule: p.rules.append(o)
            case .unknown: p.unknown.append(o)
            }
        }
        return p
    }

    /// 标签只看 kind；未知 kind 保留服务端 Label，不按 Label 反推动作。
    public static func optionLabel(_ o: ApprovalOption) -> String {
        switch o.kind {
        case .allowOnce: KitL10n.string("允许一次")
        case .allowRule: KitL10n.string("允许并记住规则")
        case .deny: KitL10n.string("拒绝")
        case .unknown: o.label
        }
    }
    /// 仅 allow_rule 的已知生成语法：完整“不支持”句、“另有 N 条…未展示”、“允许规则：”前缀（后缀逐字保留）。
    public static func optionDetail(_ o: ApprovalOption) -> String? {
        guard let d = o.detail, o.kind == .allowRule else { return o.detail }
        if d == ruleUnsupported { return KitL10n.string("agent 建议了一条本期不支持展示的规则") }
        if d.hasPrefix(rulePrefix) { return KitL10n.string("允许规则：") + d.dropFirst(rulePrefix.count) }
        if d.hasPrefix(omittedHead), d.hasSuffix(omittedTail), d.count >= omittedHead.count + omittedTail.count + 1 {
            let mid = String(d.dropFirst(omittedHead.count).dropLast(omittedTail.count))
            if let n = Int(mid), n > 0, String(n) == mid { return KitL10n.format("另有 %lld 条 agent 建议未展示", n) }
        }
        return d
    }
    /// 完整等于已知的 RuleDisabled 才换；新 Bridge 的其他原因原样展示。
    public static func optionDisabledReason(_ o: ApprovalOption) -> String? {
        guard let r = o.disabledReason, case .allowRule = o.kind, r == ruleDisabled else { return o.disabledReason }
        return KitL10n.string("本期只允许一次，不记住规则")
    }
    /// 计划打回后 Bridge 的固定提示；未知提示保留。
    public static func reviseHint(_ hint: String?) -> String? {
        hint == reviseHintWire ? KitL10n.string("同一计划已连续打回多次，agent 可能停止修改；可到 Mac 上处理") : hint
    }
    /// 计划展示上下文：仅完整等于“未附计划正文”占位时换；真实计划正文逐字保留（原 body.plan 不改）。
    public static func planText(_ plan: String) -> String {
        plan == planBodyMissingWire ? KitL10n.string("此请求未附计划正文，请回终端核对") : plan
    }

    /// 卡片标题写动作，而不是工具名。
    public static func actionTitle(toolName: String) -> String {
        switch toolName {
        case "Bash": KitL10n.string("要运行一条命令")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": KitL10n.string("要修改文件")
        case "Read", "Glob", "Grep": KitL10n.string("要读取文件")
        case "WebFetch", "WebSearch": KitL10n.string("要访问网络")
        default: KitL10n.format("要使用 %@", toolName)
        }
    }
}

public enum RevealText {
    /// 「在 Herdr 中显示」失败时给人看的原因（Bridge 的固定错误码 → 文案）。
    public static func failure(_ code: String?) -> String {
        switch code {
        case BridgeAPI.ErrorCode.readOnly: KitL10n.string("这台设备是只读，不能切换 Mac 上的窗格")
        case BridgeAPI.ErrorCode.targetNotFound: KitL10n.string("这个目标已不在 Bridge 里")
        case BridgeAPI.ErrorCode.paneGone: KitL10n.string("窗格已关闭")
        case BridgeAPI.ErrorCode.paneChanged: KitL10n.string("窗格里已经换了会话，没有切换")
        case BridgeAPI.ErrorCode.herdrUnavailable: KitL10n.string("Mac 上的 Herdr 没有响应")
        default: KitL10n.format("没能切换（%@）", code ?? KitL10n.string("未知错误"))
        }
    }
}
