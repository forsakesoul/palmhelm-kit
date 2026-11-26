import Foundation

// 与 Bridge docs/ops/local-api.md 对齐的最小模型。字段名跟接口 JSON 一致，缺省可空。

public struct BridgeHealth: Codable, Sendable, Equatable {
    public var ok: Bool
    public var protocolVersion: String?
    public var dispatch: Bool?
    public var version: String?

    enum CodingKeys: String, CodingKey { case ok, protocolVersion = "protocol", dispatch, version }
}

public struct Binding: Codable, Sendable, Equatable {
    public var targetId: String
    public var projectName: String
    public var agentName: String?
}

/// 最近记录的模型（#27）。basis 保留原始字符串：只认 last_used / last_configured，未知值由 ModelText 判为不展示（不让整条目标解码失败）。
public struct TargetModel: Codable, Sendable, Equatable {
    public var id: String
    public var basis: String
    public var effort: String?

    init(id: String, basis: String, effort: String? = nil) {
        self.id = id
        self.basis = basis
        self.effort = effort
    }
    private enum CodingKeys: String, CodingKey { case id, basis, effort }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        basis = try c.decode(String.self, forKey: .basis)
        // 新增的可选元数据损坏时，不让原本有效的模型或整份 state 解码失败。
        effort = try? c.decode(String.self, forKey: .effort)
    }
}

public struct TargetSummary: Codable, Sendable, Equatable, Identifiable {
    public var projectName: String
    public var online: Bool?
    /// 稳定 targetId（h3 起服务端总给；旧服务端没有时退回项目名）。
    public var targetId: String?
    public var agentName: String?
    /// 编组键（由 BRIDGE_TARGET_GROUP 规则得出），只用于展示。
    public var group: String?
    // 1a 身份字段：取不到时 Bridge 省略，旧 Bridge 全无。
    public var kind: String?
    public var status: String?
    public var topic: TargetTopic?
    public var role: String?
    public var groupShort: String?
    public var location: TargetLocation?
    /// 空间分组（#98）：所在工作区的稳定 ID 与终端 ID，只用于本机分组指纹（不展示）。旧 Bridge 没有时为 nil（按标签分组）。
    public var workspaceId: String?
    public var terminalId: String?
    /// 1b：执行端所在 git 仓库（Bridge 只读 .git 得出；不在仓库或读取失败时省略）。
    public var repo: TargetRepo?
    /// #27：最近记录的模型（只展示）；旧 Bridge 没有该字段时为 nil。
    public var model: TargetModel?
    /// #23：Bridge 的能力提示（只是提示，受理时仍会重新核对）。旧 Bridge 没有该字段时为 nil，不等于 false。
    public var capabilities: TargetCapabilities?
    /// 服务端权威：未解决的身份暂停的事件键（有则显示「确认是同一个会话，恢复」）；旧服务端没有此字段。
    public var identityPauseKey: String?
    /// 用户在 Palmhelm 起的名字（#134）：Bridge 权威，已是出站投影后的值；未设置或旧 Bridge 为 nil。
    public var customTitle: String?
    public var id: String { targetId ?? projectName }
    /// 立即插入是否可能可用：nil = 旧 Bridge 未声明，界面不能据此当作「不支持」。
    /// 是否为支持新发送协议的 Bridge：新 Bridge 的每个 target 都带 capabilities（steer 可为 false）；缺字段 = 旧 Bridge，不发 mode / attribution。
    public var supportsSendTiming: Bool { capabilities != nil }
    public var steerAvailability: SteerAvailability {
        guard let steer = capabilities?.steer else { return .unknown }
        return steer ? .available : .unavailable
    }
    /// 直达原生插话的能力（缺省 = 不支持；旧 Bridge 没有该字段）。
    public var nativeSteerEnabled: Bool { capabilities?.nativeSteer == true }

    enum CodingKeys: String, CodingKey { case projectName, online, targetId = "id", agentName, group, kind, status, topic, role, groupShort, location, workspaceId, terminalId, repo, model, capabilities, identityPauseKey, customTitle }

    public init(projectName: String, online: Bool? = nil, targetId: String? = nil, agentName: String? = nil, group: String? = nil,
                kind: String? = nil, status: String? = nil, topic: TargetTopic? = nil, role: String? = nil, groupShort: String? = nil, location: TargetLocation? = nil,
                repo: TargetRepo? = nil, model: TargetModel? = nil, capabilities: TargetCapabilities? = nil,
                workspaceId: String? = nil, terminalId: String? = nil, customTitle: String? = nil) {
        self.customTitle = customTitle
        self.workspaceId = workspaceId
        self.terminalId = terminalId
        self.projectName = projectName
        self.online = online
        self.targetId = targetId
        self.agentName = agentName
        self.group = group
        self.kind = kind; self.status = status; self.topic = topic; self.role = role; self.groupShort = groupShort; self.location = location
        self.repo = repo
        self.model = model
        self.capabilities = capabilities
    }

    /// 其它字段与合成解码相同（缺失 = nil，类型错误 = 整条失败）；customTitle 是新增的可选元数据，
    /// 形状不对（对象、数字、数组）时当作未设置，不让整条目标、整帧 state 或 SSE targets 解码失败。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectName = try c.decode(String.self, forKey: .projectName)
        online = try c.decodeIfPresent(Bool.self, forKey: .online)
        targetId = try c.decodeIfPresent(String.self, forKey: .targetId)
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        topic = try c.decodeIfPresent(TargetTopic.self, forKey: .topic)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        groupShort = try c.decodeIfPresent(String.self, forKey: .groupShort)
        location = try c.decodeIfPresent(TargetLocation.self, forKey: .location)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        terminalId = try c.decodeIfPresent(String.self, forKey: .terminalId)
        repo = try c.decodeIfPresent(TargetRepo.self, forKey: .repo)
        model = try c.decodeIfPresent(TargetModel.self, forKey: .model)
        capabilities = try c.decodeIfPresent(TargetCapabilities.self, forKey: .capabilities)
        identityPauseKey = try c.decodeIfPresent(String.self, forKey: .identityPauseKey)
        customTitle = try? c.decodeIfPresent(String.self, forKey: .customTitle)
    }
}

/// 仓库 › 分支：`name` 为主仓库目录名（linked worktree 也归主仓库），`worktree` 表示 linked worktree。
public struct TargetRepo: Codable, Sendable, Equatable {
    public var name: String
    public var branch: String
    public var worktree: Bool
    public init(name: String, branch: String, worktree: Bool = false) { self.name = name; self.branch = branch; self.worktree = worktree }
}

/// 会话主题：窗格标题，或标题无意义时最近一条用户消息（均已由 Bridge 投影、截断）。
public struct TargetTopic: Codable, Sendable, Equatable {
    public var text: String
    public var source: String
    public init(text: String, source: String) { self.text = text; self.source = source }
}

/// 目标在 Herdr 里的位置：工作区 / 标签的 label 与窗格编号。
public struct TargetLocation: Codable, Sendable, Equatable {
    public var workspace: String?
    public var tab: String?
    public var pane: String?
    public init(workspace: String? = nil, tab: String? = nil, pane: String? = nil) { self.workspace = workspace; self.tab = tab; self.pane = pane }
}

/// Bridge 自身：id 为数据目录里首次生成的固定编号（区分多台 Mac），name 为机器名。
public struct BridgeMeta: Codable, Sendable, Equatable {
    public var pushConfigured: Bool?
    public var id: String?
    public var name: String?
    public var version: String?
    public var dispatch: Bool?
    /// 多台 Mac B1：可达地址表，手机据此更新已保存的地址（IP 变了也能跟上）。
    public var endpoints: [ApiEndpoint]?
    /// Bridge 能按请求语言生成 owner 报告的语言（["zh","en"]）；缺失 = 旧 Bridge，只会生成中文。
    public var messageResponseLanguages: [String]?
}

extension BridgeMeta {
    public func supportsReportLanguage(_ l: MessageResponseLanguage) -> Bool { messageResponseLanguages?.contains(l.rawValue) == true }
}

/// 工作区里没有 agent 的标签数（只用于在分组底部计数；Bridge 不外发这些标签的名字）。
public struct SpaceInfo: Codable, Sendable, Equatable {
    public var workspace: String
    public var agentlessTabCount: Int
    /// 空间分组（#98）：工作区的稳定 ID。旧 Bridge 没有时为 nil。
    public var workspaceId: String?
    public init(workspace: String, agentlessTabCount: Int, workspaceId: String? = nil) {
        self.workspace = workspace; self.agentlessTabCount = agentlessTabCount; self.workspaceId = workspaceId
    }
}

/// 回执归属：指令受理时冻结的目标快照（不是当前切换指针）。
public struct TargetRef: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var projectName: String
    public var agentName: String?

    public init(id: String, projectName: String, agentName: String? = nil) {
        self.id = id
        self.projectName = projectName
        self.agentName = agentName
    }
}

public struct HistoryItem: Codable, Sendable, Equatable, Identifiable {
    public var seq: Int
    public var uuid: String
    public var text: String
    public var kind: String
    public var replyTo: String?
    /// 归属目标；系统回执或快照缺失为 nil（归“系统”线程）。
    public var target: TargetRef?
    /// 回执入队时间（毫秒）；旧 Bridge/旧行没有。
    public var t: Int?
    /// Bridge 对 canonical 状态文案给出的语义（key + 有界参数）与 final 来源头的生成范围；旧 Bridge 没有。只用于显示。
    public var displayMessage: LossyDisplayMessage?
    public var displaySpans: LossyDisplaySpans?
    public var id: Int { seq }

    public init(seq: Int, uuid: String, text: String, kind: String, replyTo: String? = nil, target: TargetRef? = nil, t: Int? = nil, displayMessage: LossyDisplayMessage? = nil, displaySpans: LossyDisplaySpans? = nil) {
        self.displayMessage = displayMessage; self.displaySpans = displaySpans
        self.seq = seq
        self.t = t
        self.uuid = uuid
        self.text = text
        self.kind = kind
        self.replyTo = replyTo
        self.target = target
    }
}

/// owner 私聊指令的受理投影（state.commands 与 SSE inbound）。只读投影，不证明已派发或送达。
public struct ApiCommand: Codable, Sendable, Equatable, Identifiable {
    public struct Device: Codable, Sendable, Equatable { public var id: String; public var name: String }
    public var key: String
    public var inboxSeq: Int
    public var text: String
    public var truncated: Bool
    public var origin: String
    public var device: Device?
    public var targetId: String?
    public var state: String
    /// Bridge 的可选原因：withdrawn（撤回，state 为 rejected）、merged（已被 hook 确认并入同一回合；只表示收到并入，不代表采纳）。
    public var reason: String?
    /// 排队车道（服务端事实）：use = 补充（立即插入）；旧 Bridge 没有该字段时为 nil。
    public var lane: String?
    /// 受理时间（毫秒，服务端）；旧 Bridge 没有该字段时为 nil（线程退回按回执锚定的旧排序）。
    public var createdT: Int?
    public var queueDeadlineT: Int?
    /// 原消息的发送方式：仅 send_now 显式给出；缺省 = 旧行为（不等于 steer）。未知值保留为字符串，不影响解码。
    public var mode: String?
    /// 原消息的直达路由；缺字段按绑定消息处理，不能按当前 agent 名猜路由。
    public var directAgent: String?
    /// #89 队列扩展组：nil = 旧帧（不含四键，不等于清除）；非 nil = 写模式帧，整组替换（null 即清除）。
    public var queue: QueueMeta? = nil
    /// 暂停分类（#89 B）：nil = 缺键（非暂停态、旧 Bridge 或旧增量）；有值只在 state == paused 时有意义。
    /// 显式 null / 未知字符串按“不确定”保存（保守），不是“缺键”。
    public var stopDisposition: StopDisposition? = nil
    public var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key, inboxSeq, text, truncated, origin, device, targetId, state, reason, lane, createdT, queueDeadlineT, mode, directAgent, stopDisposition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        inboxSeq = try c.decode(Int.self, forKey: .inboxSeq)
        text = try c.decode(String.self, forKey: .text)
        truncated = try c.decode(Bool.self, forKey: .truncated)
        origin = try c.decode(String.self, forKey: .origin)
        device = try c.decodeIfPresent(Device.self, forKey: .device)
        targetId = try c.decodeIfPresent(String.self, forKey: .targetId)
        state = try c.decode(String.self, forKey: .state)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        lane = try c.decodeIfPresent(String.self, forKey: .lane)
        createdT = try c.decodeIfPresent(Int.self, forKey: .createdT)
        queueDeadlineT = try c.decodeIfPresent(Int.self, forKey: .queueDeadlineT)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        directAgent = try c.decodeIfPresent(String.self, forKey: .directAgent)
        queue = try QueueMeta.decode(from: decoder)
        stopDisposition = StopDisposition.decode(c, forKey: .stopDisposition)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(inboxSeq, forKey: .inboxSeq)
        try c.encode(text, forKey: .text)
        try c.encode(truncated, forKey: .truncated)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(device, forKey: .device)
        try c.encodeIfPresent(targetId, forKey: .targetId)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(lane, forKey: .lane)
        try c.encodeIfPresent(createdT, forKey: .createdT)
        try c.encodeIfPresent(queueDeadlineT, forKey: .queueDeadlineT)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(directAgent, forKey: .directAgent)
        try c.encodeIfPresent(stopDisposition, forKey: .stopDisposition)
        try queue?.encodeWire(to: encoder)
    }

    public init(key: String, inboxSeq: Int, text: String, truncated: Bool = false, origin: String, device: Device? = nil, targetId: String? = nil, state: String, reason: String? = nil, lane: String? = nil, stopDisposition: StopDisposition? = nil) {
        self.stopDisposition = stopDisposition
        self.key = key
        self.inboxSeq = inboxSeq
        self.text = text
        self.truncated = truncated
        self.origin = origin
        self.device = device
        self.targetId = targetId
        self.state = state
        self.reason = reason
        self.lane = lane
    }
}

/// 审批视图（state.approvals、GET /v1/approvals、SSE approval）。summary 已由 Bridge 投影，不含原始 tool_input。
public struct ApprovalView: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var status: String
    public var targetId: String?
    public var targetLabel: String
    public var attribution: String?
    public var toolName: String
    public var summary: String
    /// summary 内 Bridge 生成原子（隐藏/路径/链接等）的范围；旧 Bridge 没有。只用于显示。
    public var summaryDisplaySpans: LossyDisplaySpans? = nil
    public var truncated: Bool
    public var createdT: Int
    public var expiresT: Int
    public var decidedBy: String?
    /// agent 本次实际提供的选项（Bridge 投影后的展示信息；缺失=旧 Bridge，只有允许一次/拒绝）。可执行的仍只有 allow_once/deny。
    public var options: [ApprovalOption]?
    /// 同一请求多个钩子上送的选项不一致（以首次为准）。
    public var optionsVaried: Bool?
    /// 当前等待的钩子是否支持把拒绝原因转达给 agent。
    public var messageSupported: Bool?
    /// 待办种类：approval（默认）/ question / plan；旧 Bridge 没有该字段。
    public var kind: String?
    /// question：本次提问的问题数（正文经 approvalDetail 取）。
    public var questionCount: Int?
    /// plan：同一计划已连续打回的次数；hint 为达到提示次数时的固定提示。
    public var reviseCount: Int?
    public var hint: String?
    /// 来源 agent：只在非 Claude 时出现（目前只有 "codex"）；旧 Bridge / 旧记录没有该字段 = Claude，不显示来源标签。
    public var provider: String?

    public var pendingKind: PendingKind { kind.flatMap(PendingKind.init(rawValue:)) ?? .approval }

    public init(id: String, status: String, targetLabel: String, attribution: String? = nil, toolName: String, summary: String, truncated: Bool = false, createdT: Int, expiresT: Int, decidedBy: String? = nil, options: [ApprovalOption]? = nil, optionsVaried: Bool? = nil, messageSupported: Bool? = nil, targetId: String? = nil) {
        self.targetId = targetId
        self.id = id; self.status = status; self.targetLabel = targetLabel; self.attribution = attribution
        self.toolName = toolName; self.summary = summary; self.truncated = truncated
        self.createdT = createdT; self.expiresT = expiresT; self.decidedBy = decidedBy
        self.options = options; self.optionsVaried = optionsVaried; self.messageSupported = messageSupported
    }

    /// 展示用的选项列表：Bridge 没给就退回固定两项。
    public var displayOptions: [ApprovalOption] {
        options ?? [ApprovalOption(id: "allow_once", kind: .allowOnce, label: KitL10n.string("允许一次"), enabled: true), ApprovalOption(id: "deny", kind: .deny, label: KitL10n.string("拒绝"), enabled: true)]
    }

    /// 期限只看 expiresT；恰好到期即过期（与 Bridge 一致）。
    public func isPending(now: Date = Date()) -> Bool {
        status == ApprovalStatus.pending.rawValue && Double(expiresT) > now.timeIntervalSince1970 * 1000
    }
}

public struct ApprovalsResponse: Codable, Sendable, Equatable { public var approvals: [ApprovalView] }

/// 提问 / 计划的投影正文（GET /v1/approvals/{id}）。markdown 已在 Bridge 降级：没有可远程加载的图片或链接。
public struct ProjectedOption: Codable, Sendable, Equatable {
    public var label: String
    public var description: String
    public var preview: String?
    public var labelDisplaySpans: LossyDisplaySpans? = nil
    public var descriptionDisplaySpans: LossyDisplaySpans? = nil
    public var previewDisplaySpans: LossyDisplaySpans? = nil
    /// 命中敏感内容被遮蔽的选项不能作答。
    public var selectable: Bool
}

public struct ProjectedQuestion: Codable, Sendable, Equatable {
    public var header: String
    public var question: String
    public var questionDisplaySpans: LossyDisplaySpans? = nil
    public var multiSelect: Bool
    public var options: [ProjectedOption]
}

public struct ApprovalBody: Codable, Sendable, Equatable {
    public var questions: [ProjectedQuestion]?
    public var plan: String?
    public var planDisplaySpans: LossyDisplaySpans? = nil
    public var truncated: Bool?
    /// 文件类工具的改动正文（2b 第 1 步，hookVersion ≥ 4）；Bash 等工具没有。
    public var change: ApprovalChange?
}

/// 一处改动：`old` 仅 edit 有；Write / NotebookEdit 只有 `new`。两侧都已投影、可能被截断为空串。
public struct ApprovalHunk: Codable, Sendable, Equatable {
    public var old: String?
    public var new: String
    public var replaceAll: Bool?
    public var oldDisplaySpans: LossyDisplaySpans? = nil
    public var newDisplaySpans: LossyDisplaySpans? = nil
    public init(old: String? = nil, new: String, replaceAll: Bool? = nil) { self.old = old; self.new = new; self.replaceAll = replaceAll }
}

/// 改动正文：`hidden` 为 true 时 `path` 是固定占位、`hunks` 为空（敏感内容整段隐藏）。
public struct ApprovalChange: Codable, Sendable, Equatable {
    public var path: String
    public var pathDisplaySpans: LossyDisplaySpans? = nil
    public var kind: String
    public var hunks: [ApprovalHunk]
    public var more: Int
    public var truncated: Bool
    public var hidden: Bool?
    public init(path: String, kind: String, hunks: [ApprovalHunk], more: Int = 0, truncated: Bool = false, hidden: Bool? = nil) {
        self.path = path; self.kind = kind; self.hunks = hunks; self.more = more; self.truncated = truncated; self.hidden = hidden
    }
}

/// 起因（2b 第 2 步）：详情接口按需算，不落库。`status` 为 `unavailable` 时两个子字段都没有。
public struct ApprovalCause: Codable, Sendable, Equatable {
    public struct Prompt: Codable, Sendable, Equatable {
        public var text: String
        public var origin: String // feishu / reins / terminal
        public var t: Int?
        public var textDisplaySpans: LossyDisplaySpans? = nil
        public init(text: String, origin: String, t: Int? = nil) { self.text = text; self.origin = origin; self.t = t }
    }
    public struct Note: Codable, Sendable, Equatable {
        public var text: String
        public var t: Int?
        public var truncated: Bool
        public var textDisplaySpans: LossyDisplaySpans? = nil
        public init(text: String, t: Int? = nil, truncated: Bool = false) { self.text = text; self.t = t; self.truncated = truncated }
    }
    public var status: String
    public var prompt: Prompt?
    public var note: Note?
    public init(status: String, prompt: Prompt? = nil, note: Note? = nil) { self.status = status; self.prompt = prompt; self.note = note }
    public var isAvailable: Bool { status == "ok" }
}

public struct ApprovalDetail: Codable, Sendable, Equatable {
    public var view: ApprovalView
    public var body: ApprovalBody?
    public var reviseCount: Int?
    /// 旧 Bridge 没有该字段：按缺省处理（不显示起因段）。
    public var cause: ApprovalCause?
}

public struct ApprovalDetailResponse: Codable, Sendable, Equatable { public var approval: ApprovalDetail }

/// 一题的答案：按选项索引（单选恰一项、多选为集合）或自由文本（≤500 单位，Bridge 会投影）。
public enum QuestionAnswer: Sendable, Equatable, Encodable {
    case options(question: Int, indexes: [Int])
    case text(question: Int, text: String)

    enum CodingKeys: String, CodingKey { case question, option, text }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .options(let q, let idx): try c.encode(q, forKey: .question); try c.encode(idx, forKey: .option)
        case .text(let q, let t): try c.encode(q, forKey: .question); try c.encode(t, forKey: .text)
        }
    }
}
public struct DecisionResponse: Codable, Sendable, Equatable {
    public var status: String
    /// 计划打回后：连续打回次数与达到提示次数时的固定提示。
    public var reviseCount: Int?
    public var hint: String?
    /// deny 时 Bridge 实际转达的最终文本（可能已按安全规则替换）；只回给决定者。
    public var message: String?
    public var messageProjected: Bool?
}

/// agent 提供的一个审批选项。kind 为 allow_rule 时本期恒 enabled=false（只展示，不记住规则）。
public struct ApprovalOption: Codable, Sendable, Equatable, Identifiable {
    /// 未知 kind 保留原字符串（编码回原值），展示只读：永远不是可提交的动作，也不让整张卡解码失败；非字符串仍解码失败。
    public enum Kind: Codable, Sendable, Equatable, RawRepresentable {
        case allowOnce, allowRule, deny
        case unknown(String)
        public init(rawValue: String) {
            switch rawValue {
            case "allow_once": self = .allowOnce
            case "allow_rule": self = .allowRule
            case "deny": self = .deny
            default: self = .unknown(rawValue)
            }
        }
        public var rawValue: String {
            switch self {
            case .allowOnce: "allow_once"
            case .allowRule: "allow_rule"
            case .deny: "deny"
            case .unknown(let s): s
            }
        }
        public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    }
    public var id: String
    public var kind: Kind
    public var label: String
    public var detail: String?
    public var enabled: Bool
    public var disabledReason: String?
    public init(id: String, kind: Kind, label: String, detail: String? = nil, enabled: Bool, disabledReason: String? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.detail = detail; self.enabled = enabled; self.disabledReason = disabledReason
    }
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var paused: Bool
    /// readonly | control；旧 Bridge 没有该字段时按 control（与迁移后的老设备一致）。
    public var permission: String?
    public var canControl: Bool { permission != DevicePermission.readonly.rawValue }
}

public enum DevicePermission: String, Sendable { case readonly, control }

public struct DeviceResponse: Codable, Sendable, Equatable { public var device: DeviceInfo }

public struct History: Codable, Sendable, Equatable {
    public var highWater: Int
    public var items: [HistoryItem]
}

public struct InflightItem: Codable, Sendable, Equatable {
    public var eventKey: String
    public var state: String
}

/// 某目标上当前正阻塞（等审批 / 回答）的在途命令；eventKey 是该命令受理时的原始事件键，与 nblocked2 提醒的 replyTo 同源。
public struct CurrentBlocked: Codable, Sendable, Equatable {
    public var targetId: String
    public var eventKey: String
    public var blockedSince: Int
    public init(targetId: String, eventKey: String, blockedSince: Int) { self.targetId = targetId; self.eventKey = eventKey; self.blockedSince = blockedSince }
}

public struct BridgeState: Codable, Sendable, Equatable {
    /// 当前阻塞投影；缺失 = 旧 Bridge（不能当成「没有阻塞」），空数组 = 新 Bridge 确认没有目标在阻塞。
    public var currentBlocked: [CurrentBlocked]?
    /// currentBlocked 的证据是否新鲜（Bridge 的 Herdr 快照未过期）：false / 缺失 = 不能把它当成可靠的当前阻塞（含「空」）。
    public var currentBlockedFresh: Bool?
    /// 目标观察证据（#97）：缺失 = 旧 Bridge，不能据此整理（归档）线程。
    public var observation: BridgeObservation?
    public var bridge: BridgeMeta?
    public var spaces: [SpaceInfo]?
    public var binding: Binding?
    public var occupancy: String
    public var hold: String?
    public var targets: [TargetSummary]
    public var history: History
    public var inflight: [InflightItem]?
    public var device: DeviceInfo?
    public var commands: [ApiCommand]?
    public var commandsTruncated: Bool?
    public var pendingApprovals: Int?
    public var approvals: [ApprovalView]?
}

public struct PairResponse: Codable, Sendable, Equatable {
    public var deviceId: String
    public var token: String
    /// https 时 Bridge 回报自己的 SPKI 摘要；客户端只拿它与实际握手证书交叉校验，不当信任根。
    public var spkiSha256: String?
    /// 多台 Mac B1：Bridge 的可达地址表（lan / tailscale / loopback），手机一次保存多个地址。旧 Bridge 没有。
    public var endpoints: [ApiEndpoint]?
}

/// Bridge 自报的可达地址：`kind` ∈ lan（RFC1918 字面量）/ tailscale（.ts.net 主机名）/ loopback。
public struct ApiEndpoint: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var transport: Transport
    public var kind: String
    public init(host: String, port: Int, transport: Transport, kind: String) { self.host = host; self.port = port; self.transport = transport; self.kind = kind }
}

public struct MessageReceipt: Codable, Sendable, Equatable {
    public var received: Bool
    public var eventKey: String?
}

// SSE 事件：按 Bridge 契约 sync → outbox* → ready，之后实时 outbox / progress；越窗 reset_required；心跳 ping。
public enum BridgeEvent: Sendable, Equatable {
    case sync(highWater: Int, count: Int, mode: String)
    case outbox(HistoryItem)
    case ready(highWater: Int)
    case progress(ProgressPayload)
    case inbound(ApiCommand)
    case approval(ApprovalView)
    /// 目标身份/状态快照变化（全量）；连接时 Bridge 先发一帧。
    case targets([TargetSummary], spaces: [SpaceInfo]?, currentBlocked: [CurrentBlocked]? = nil, currentBlockedFresh: Bool? = nil, observation: BridgeObservation? = nil)
    /// 本设备自己的权限 / 暂停状态变化（同 /v1/state 的 device）：只推给本设备；旧 Bridge 没有这个帧。
    case device(DeviceInfo)
    case resetRequired(highWater: Int)
    /// 某目标的会话记录有变化（只含版本，不含正文）；客户端只对当前打开的线程补拉最新页。
    case transcriptChanged(TranscriptChange)
    case ping
    case unknown(name: String)
}

// MARK: - 会话记录线程（2a）

/// `GET /v1/targets/{id}/transcript` 的一页。`status == "unavailable"` 不是空对话：客户端回退到 Bridge 自己的记录。
public struct TranscriptPage: Codable, Sendable, Equatable {
    public var status: String
    public var sessionEpoch: String?
    public var revision: String?
    public var items: [TranscriptItem]
    public var nextBefore: String?
    public var hasMore: Bool
    public var partial: Bool
    /// 不可用的可选原因（Bridge 只对归属错绑给出 `owner_mismatch`）；未知值与缺失都按通用不可用处理。
    public var reason: String?
    /// 回执后补关联：只在首页条件读取带了 receipt 声明时出现（旧 Bridge 没有）；省略与空数组都表示没有变化。
    public var receiptUpdates: [TranscriptReceiptUpdate]?

    public var isAvailable: Bool { status == "ok" }

    public init(status: String, sessionEpoch: String? = nil, revision: String? = nil, items: [TranscriptItem] = [], nextBefore: String? = nil, hasMore: Bool = false, partial: Bool = false, reason: String? = nil, receiptUpdates: [TranscriptReceiptUpdate]? = nil) {
        self.status = status; self.sessionEpoch = sessionEpoch; self.revision = revision; self.items = items; self.nextBefore = nextBefore; self.hasMore = hasMore; self.partial = partial; self.reason = reason; self.receiptUpdates = receiptUpdates
    }
}

/// 一条会话记录：`role` 为 user / assistant / gap（gap 的文案由 Bridge 固定给出）。正文已由 Bridge 投影，不含工具/思考。
public struct TranscriptItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var role: String
    public var text: String
    /// 毫秒；旧记录可能没有。
    public var t: Int?
    public var truncated: Bool
    public var projected: Bool?
    /// 只在 Bridge 内匹配到的回执：这条用户消息是经 Palmhelm / 飞书发出的。
    public var receipt: TranscriptReceipt?
    /// gap 的原因（W2-137）：oversized_record 表示单条记录超过上限未展示；旧 Bridge 与其它 gap 没有该字段。
    public var reason: String?
    /// 截断条目的按条续读令牌（#88 S1）：只在 truncated 为真且 Bridge 能安全续读时出现；旧 Bridge 没有该字段。
    public var continuation: String?
    /// Bridge 标出的生成原子范围（相对 text 的 UTF-16）；旧 Bridge 没有。只用于显示，不参与搜索、回执匹配与内容版本。
    public var displaySpans: LossyDisplaySpans?
    /// gap 行的语义（transcript.gap.*）；其它条目没有。
    public var displayMessage: LossyDisplayMessage?

    public init(id: String, role: String, text: String, t: Int? = nil, truncated: Bool = false, projected: Bool? = nil, receipt: TranscriptReceipt? = nil, reason: String? = nil, continuation: String? = nil, displaySpans: LossyDisplaySpans? = nil, displayMessage: LossyDisplayMessage? = nil) {
        self.displayMessage = displayMessage
        self.id = id; self.role = role; self.text = text; self.t = t; self.truncated = truncated; self.projected = projected; self.receipt = receipt; self.reason = reason; self.continuation = continuation; self.displaySpans = displaySpans
    }
    /// 当前显示语言下的正文（只替换 Bridge 标出的生成原子）；无范围时就是 text。
    public var displayed: DisplayedText { BridgeDisplayText.render(text, lossy: displaySpans) }
}

public struct TranscriptReceipt: Codable, Sendable, Equatable {
    public var commandKey: String
    public var origin: String
    public var receiptState: String
    /// merged：补充已被 hook 确认并入同一回合（只表示收到并入，不代表采纳）；旧 Bridge 没有该字段时为 nil。
    public var reason: String?
    /// 本设备自己经 API 发出的指令的受理键（与发送响应的 eventKey 相同）：客户端精确关联，不做文字比对；其他设备与飞书来源不给（O1-365）。
    public var eventKey: String?

    public init(commandKey: String, origin: String, receiptState: String, reason: String? = nil, eventKey: String? = nil) {
        self.commandKey = commandKey; self.origin = origin; self.receiptState = receiptState; self.reason = reason; self.eventKey = eventKey
    }
}

/// SSE `transcript_changed`：`kind` 为 session（换了会话或连接初始版本）/ reset（旧游标失效，从最新页重来）/ append（同会话追加）。
public struct TranscriptChange: Codable, Sendable, Equatable {
    public var targetId: String
    public var sessionEpoch: String
    public var revision: String
    public var kind: String

    public init(targetId: String, sessionEpoch: String, revision: String, kind: String) { self.targetId = targetId; self.sessionEpoch = sessionEpoch; self.revision = revision; self.kind = kind }
}

public enum TranscriptRole: String, Sendable { case user, assistant, gap }
public enum TranscriptChangeKind: String, Sendable { case session, reset, append }
/// 回执投递状态（TranscriptReceipt.receiptState）。
public enum TranscriptReceiptState: String, Sendable {
    case accepted, sent, done, unknown
    public var label: String { switch self { case .accepted: KitL10n.string("已受理"); case .sent: KitL10n.string("已送达"); case .done: KitL10n.string("已执行"); case .unknown: KitL10n.string("状态未知") } }
}


/// 窗格当前视口的只读镜像（终端视图第一片）。`status` 为 `unavailable` 时其余字段缺省。
/// `hidden` 为 true 时 `lines` 只有一行固定占位（整屏命中敏感规则）。
public struct ScreenSnapshot: Codable, Sendable, Equatable {
    public var status: String
    public var revision: String?
    public var t: Int?
    public var cols: Int?
    public var rows: Int?
    public var lines: [String]?
    public var truncated: Bool?
    public var hidden: Bool?
    public init(status: String, revision: String? = nil, t: Int? = nil, cols: Int? = nil, rows: Int? = nil, lines: [String]? = nil, truncated: Bool? = nil, hidden: Bool? = nil) {
        self.status = status; self.revision = revision; self.t = t; self.cols = cols; self.rows = rows; self.lines = lines; self.truncated = truncated; self.hidden = hidden
    }
    public var isOK: Bool { status == "ok" }
}

/// 终端镜像页的固定文案（两端一致；设计稿 Ttv）。
public enum ScreenCopy {
    public static var live: String { KitL10n.string("实时镜像 · 只读 · 每 2 秒刷新") }
    public static var unavailableTitle: String { KitL10n.string("读不到这个窗格的画面") }
    public static var unavailableBody: String { KitL10n.string("窗格没有执行端，或 Herdr 暂时不可用。对话页仍可看会话记录与回执。") }
    public static var failedTitle: String { KitL10n.string("暂时读不到终端") }
    public static var truncated: String { KitL10n.string("视口超过 400 列，已截断") }
    public static var toBottom: String { KitL10n.string("回到底部") }
    public static var retry: String { KitL10n.string("重试") }
    public static var tabChat: String { KitL10n.string("对话") }
    public static var tabTerminal: String { KitL10n.string("终端") }
}


/// 终端输入会话（第二片）：只有可控设备能开启，10 分钟到期。
public struct InputSession: Codable, Sendable, Equatable {
    /// GET 带 `open`；POST 开启只回 `expiresT`（有到期时间即已开启）。
    public var open: Bool?
    public var expiresT: Int?
    public init(open: Bool? = nil, expiresT: Int? = nil) { self.open = open; self.expiresT = expiresT }
    public var isOpen: Bool { open ?? (expiresT != nil) }
}
public struct KeysResponse: Codable, Sendable, Equatable { public var sent: Int }

// MARK: - 会话搜索（h6b，契约见 docs/ops/local-api.md §8d）

/// `GET /v1/search` 的一条命中。`pageBefore` 缺省表示最新一页；`ranges` 为 snippet 内的 UTF-16 `[起始, 长度]`。
public struct SearchHit: Codable, Sendable, Equatable, Identifiable {
    public var targetId: String
    public var itemId: String
    public var sessionEpoch: String
    public var pageBefore: String?
    public var role: String
    public var t: Int?
    public var snippet: String
    public var ranges: [[Int]]
    /// snippet 内 Bridge 生成原子的范围（相对 snippet，含前置省略号偏移）；旧 Bridge 没有。
    public var snippetDisplaySpans: LossyDisplaySpans? = nil

    /// 不同目标的条目 id 可能重复，身份用二元组。
    public var id: String { targetId + "\u{1F}" + itemId }

    public init(targetId: String, itemId: String, sessionEpoch: String, pageBefore: String? = nil, role: String, t: Int? = nil, snippet: String, ranges: [[Int]] = []) {
        self.targetId = targetId; self.itemId = itemId; self.sessionEpoch = sessionEpoch; self.pageBefore = pageBefore
        self.role = role; self.t = t; self.snippet = snippet; self.ranges = ranges
    }
}

public struct SearchScanned: Codable, Sendable, Equatable {
    public var targets: Int
    public var pages: Int
}

public struct SearchSkip: Codable, Sendable, Equatable {
    public var targetId: String
    public var reason: String
}

public struct SearchResponse: Codable, Sendable, Equatable {
    public var results: [SearchHit]
    /// `true` 且 `results` 为空不等于没有匹配（预算 / 忙碌 / 页数上限）。
    public var partial: Bool
    public var scanned: SearchScanned
    public var skipped: [SearchSkip]

    public init(results: [SearchHit], partial: Bool, scanned: SearchScanned, skipped: [SearchSkip]) {
        self.results = results; self.partial = partial; self.scanned = scanned; self.skipped = skipped
    }
}

public enum InputCopy {
    public static var allow: String { KitL10n.string("允许输入（10 分钟）") }
    public static var banner: String { KitL10n.string("输入已开启") }
    public static var close: String { KitL10n.string("关闭") }
    public static var approvalFirst: String { KitL10n.string("有审批在等你：先处理审批，按键条暂时收起") }
    public static var send: String { KitL10n.string("发送") }
    public static var placeholder: String { KitL10n.string("输入一行文字，回车另按 Enter") }
    public static var keyLabels: [String: String] { ["enter": "Enter", "esc": "Esc", "tab": "Tab", "up": "↑", "down": "↓", "left": "←", "right": "→", "backspace": "⌫", "ctrl+c": "Ctrl+C", "ctrl+d": "Ctrl+D", "space": KitL10n.string("空格")] }
}
