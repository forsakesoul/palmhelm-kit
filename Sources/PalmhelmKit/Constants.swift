import Foundation

// 与 Bridge（docs/ops/local-api.md）共享的契约常量。两端字面量必须一致；改这里时同步 Bridge 的 shared 常量。
public enum BridgeAPI {
    /// 连接期限（秒，绝对期限，从发起时刻起算；O1-348）。高延迟中继（实测 1.7s RTT，Tailscale 经 DERP / WireGuard）下，
    /// 一次全新 HTTPS 请求要 3 个往返（TCP 建连 + TLS 1.3 握手 + HTTP），约 5.2s；取约 2 倍余量：慢而可达的请求能完成，
    /// 真不可达的请求在期限内结束（不无限转圈）。URLRequest.timeoutInterval 只是空闲超时，不能用来限定这些期限。
    public enum Deadline {
        /// 常规请求、握手探测、更新地址检查、删除设备。
        public static let request: TimeInterval = 10
        /// 配对前的握手探测。
        public static let pairProbe: TimeInterval = 10
        /// 配对 POST：结果不确定的代价更高，给更长的期限。
        public static let pairSend: TimeInterval = 15
        /// 一轮刷新：最多两个地址各一次请求（最长 2 × request）。
        public static let refreshRound: TimeInterval = 20
        /// 事件流单次尝试的首字节期限（响应头到达即算）：期限到即取消本次尝试，由重连环按退避再试（#85）。
        public static let streamFirstByte: TimeInterval = 15
        /// 事件流的空闲超时（URLSession.timeoutInterval）：只是兜底，帧看门狗在应用层判定无帧（#85）。
        public static let streamIdle: TimeInterval = 90
    }

    /// 本机 API 协议版本（Bonjour TXT 的 v= 与 /health 的 protocol 都是它）。
    public static let protocolVersion = "local-api/1"
    public static let defaultPort = 47821
    public static let scheme = "http"

    public enum Path {
        public static let pair = "/pair"
        public static let health = "/v1/health"
        public static let state = "/v1/state"
        public static let messages = "/v1/messages"
        public static let events = "/v1/events"
        public static let approvals = "/v1/approvals"
        public static let devicesSelf = "/v1/devices/self"
        public static let usage = "/v1/usage"
        /// `GET /v1/accounts`（账户额度，只读；`?refresh=1` 手动刷新）。
        public static let accounts = "/v1/accounts"
        /// `GET /v1/search?q&limit`：会话记录内容搜索（h6b）。
        public static let search = "/v1/search"
        /// `POST /v1/targets/{id}/reveal`：id 为一个百分号编码的路径段。
        public static let targets = "/v1/targets"
        public static let revealSuffix = "/reveal"
        /// `GET /v1/targets/{id}/transcript?before&limit`：会话记录线程分页（2a）。
        public static let transcriptSuffix = "/transcript"
        /// `GET /v1/targets/{id}/history?before&limit`：目标账本历史分页（#97，历史离线目标的归档阅读）。
        public static let historySuffix = "/history"
        /// `GET /v1/targets/{id}/screen`：窗格当前视口的只读镜像（终端视图第一片）。
        public static let screenSuffix = "/screen"
        /// 终端输入第二片：`POST/DELETE/GET /v1/targets/{id}/input/session`、`POST /v1/targets/{id}/keys`。
        public static let inputSessionSuffix = "/input/session"
        public static let keysSuffix = "/keys"
    }

    /// Bridge 业务错误码（HTTP 4xx 的 error 字段）。
    public enum ErrorCode {
        public static let devicePaused = "device_paused"
        public static let readOnly = "read_only"
        public static let targetNotFound = "target_not_found"
        public static let paneGone = "pane_gone"
        public static let paneChanged = "pane_changed"
        public static let herdrUnavailable = "herdr_unavailable"
    }

    public enum Header {
        public static let authorization = "Authorization"
        public static let bearerPrefix = "Bearer "
        public static let accept = "Accept"
        public static let eventStream = "text/event-stream"
        public static let contentType = "Content-Type"
        public static let json = "application/json"
    }

    /// 事件流窗口：超出则 Bridge 返回 reset_required，客户端重拉状态。
    public static let eventWindow = 500
    /// 服务端保留的历史条数上限（state.history 与 state.commands）。
    public static let historyLimit = 200
    /// ApiCommand.text 的码元上限，超过则 truncated。
    public static let commandTextUnits = 2000
    /// 会话记录每页条数上限（limit 缺省与最大值相同）。
    public static let transcriptPageLimit = 20
    /// 搜索结果条数：客户端固定请求 30 条，不做分页。
    public static let searchLimit = 30
    /// 终端镜像轮询间隔（秒），只在终端页可见时拉取。
    public static let screenPollSeconds: Double = 2
    /// 终端输入：文本上限（UTF-16 单位）与每次按键数上限；白名单键名与 Bridge 一致。
    public static let inputTextMax = 200
    public static let inputKeysMax = 8
    public static let inputKeys: [String] = ["enter", "esc", "tab", "up", "down", "left", "right", "backspace", "ctrl+c", "ctrl+d", "space"]
}

/// SSE 事件名（Bridge h2/h3 契约）。
public enum SSEEventName: String, Sendable {
    case sync, outbox, ready, progress, ping, approval, inbound, targets, device
    case resetRequired = "reset_required"
    case transcriptChanged = "transcript_changed"
}

/// 指令来源（ApiCommand.origin）：只由 Bridge 的认证适配器设定。
public enum InboundOrigin: String, Sendable {
    case feishu, api

    public var label: String { switch self { case .feishu: KitL10n.string("来自飞书"); case .api: KitL10n.string("来自设备") } }
}

/// 指令受理投影状态（ApiCommand.state）= queued + 进度状态。
public enum CommandState: String, Sendable {
    case queued, started, finished, unknown, paused, rejected

    public var isTerminal: Bool { ProgressState(rawValue: rawValue)?.isTerminal ?? false }
    public var label: String { self == .queued ? KitL10n.string("排队中") : (ProgressState(rawValue: rawValue)?.label ?? rawValue) }
}

/// owner 私聊队列的进度投影状态（Bridge progress 事件）。
public enum ProgressState: String, Sendable, CaseIterable {
    case started, finished, unknown, paused, rejected

    /// 到了这些状态不再变化，客户端可从“在途”里移除。
    public var isTerminal: Bool {
        switch self { case .finished, .paused, .rejected: true; case .started, .unknown: false }
    }

    public var label: String {
        switch self {
        case .started: KitL10n.string("处理中"); case .finished: KitL10n.string("已完成"); case .unknown: KitL10n.string("结果未知"); case .paused: KitL10n.string("已暂停"); case .rejected: KitL10n.string("被拒绝")
        }
    }
}

/// 目标占用状态（state.occupancy）。
public enum Occupancy: String, Sendable {
    case none, active, unknown, sending

    public var label: String {
        switch self { case .none: KitL10n.string("空闲"); case .active: KitL10n.string("处理中"); case .unknown: KitL10n.string("未知"); case .sending: KitL10n.string("kit.sending.short", default: "发送中") }
    }
}

/// 审批决定（POST /v1/approvals/{id}）。没有“始终允许”。
public enum ApprovalDecision: String, Sendable {
    case allowOnce = "allow_once"
    case deny
}

/// 审批状态（approval 事件与 GET /v1/approvals）。
public enum ApprovalStatus: String, Sendable {
    case pending, allowed, denied, expired, withdrawn

    public var label: String {
        switch self { case .pending: KitL10n.string("等待"); case .allowed: KitL10n.string("已允许"); case .denied: KitL10n.string("已拒绝"); case .expired: KitL10n.string("已过期"); case .withdrawn: KitL10n.string("已撤回") }
    }
}

/// 审批归属类型：exact=精确匹配；candidate=按目录推测（展示启发式，不是身份认证）；unregistered=无法判断。
public enum ApprovalAttribution: String, Sendable {
    case exact, candidate, unregistered
}

/// 回执 uuid 前缀（与 Bridge shared UuidPrefix 对齐）。
public enum UuidPrefix {
    public static let blockedReminder = "nblocked2:"
}

/// 回执 uuid 的前缀：系统类回执在线程里居中小字显示。
public enum ReceiptPrefix {
    public static let system: [String] = ["switched:", "rejected:", "ack:", "["]
}

/// 系统回执的人话摘要：线程里的居中行与会话预览共用；非系统回执原样返回。
/// 来源格式（Bridge）：`queued:task:<id>`、`ack:<key>[:pN]`、`switched:<target>@<rev>（说明）`、`rejected:<code>[:detail][（说明）]`。
public enum ReceiptText {
    /// 直达被拒的回执原文：replyTo 关联到该条发送的 eventKey 且以 rejected: 开头。每次按当前 history 求值，回执先到或 eventKey 后回填都成立。
    public static func rejection(replyTo key: String, in history: [HistoryItem]) -> String? {
        history.first { $0.replyTo == key && $0.text.hasPrefix("rejected:") }?.text
    }

    /// 这条回执在当前显示语言下的正文：英文等非中文下优先用 Bridge 的语义（displayMessage），其次只替换 Bridge 标出的生成范围（来源头）；其余原样。
    /// 只用于显示——解析/关联/复制仍读 item.text。
    public static func display(_ item: HistoryItem) -> String {
        if let m = item.localizedDisplayMessage { return m }
        return BridgeDisplayText.render(item.text, lossy: item.displaySpans).text
    }

    /// 回执的一行摘要（收件箱预览、提醒、线程里的系统行）：`display` 之后再套既有的前缀摘要。
    public static func summary(_ item: HistoryItem) -> String { summary(display(item)) }

    /// 与 `rejection(replyTo:in:)` 同判定，返回整条回执（显示按语义，不重解析原文）。
    public static func rejectionItem(replyTo key: String, in history: [HistoryItem]) -> HistoryItem? {
        history.first { $0.replyTo == key && $0.text.hasPrefix("rejected:") }
    }

    public static func isSystem(_ text: String) -> Bool {
        text.hasPrefix("queued:") || ReceiptPrefix.system.contains { text.hasPrefix($0) }
    }

    /// 线程里的一条回执是否系统回执：uuid 为 ack:（Bridge 的受理 / 撤回 / 并入回执，正文可以是普通句子）或正文带系统前缀。
    /// 系统回执不冒充 agent 消息（O1-327）。
    public static func isSystem(_ item: HistoryItem) -> Bool {
        item.uuid.hasPrefix("ack:") || isSystem(item.text)
    }

    /// 身份暂停（直达 direct_identity_changed / 普通 target_identity_changed）的中文说明（O1-332 B）。
    public static var identityPauseCopy: String { KitL10n.string("这个会话背后的 agent 已重启或换了会话，Palmhelm 暂停了发送，防止发错对象。") }

    /// 是不是身份暂停的回执（直达或普通目标）：客户端据此给出「确认是同一个会话，恢复」。
    public static func isIdentityPause(_ text: String) -> Bool {
        text.hasPrefix("rejected:direct_identity_changed") || text.hasPrefix("rejected:target_identity_changed")
    }

    /// 条件恢复命令「恢复身份 #<eventKey>」（O1-343）：只带身份暂停的事件键；目标与执行端由服务端从暂停记录解析，客户端不传 agent 名。
    /// 事件键必须是单个 token；不合法返回 nil，不给恢复入口。服务端逐项核验，不满足就零写入。
    public static func identityRecoverCommand(eventKey: String) -> String? {
        func token(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "#" } }
        guard token(eventKey) else { return nil }
        return "恢复身份 #\(eventKey)"
    }

    /// 恢复被拒的固定原因（服务端回 rejected:identity_recover_refused:<reason>，不含路径或原文）。
    public static func identityRecoverRefusalCopy(_ reason: String) -> String? {
        switch reason {
        case "unknown_target": KitL10n.string("没有找到这个目标")
        case "no_matching_pause": KitL10n.string("这次暂停已经不在了，或不属于这个目标")
        case "revision_changed": KitL10n.string("目标已经变了（重新登记或配置已更新），请重新发送")
        case "generation_changed": KitL10n.string("这个目标的执行端刚刚变过，请以最新状态为准")
        case "active_command": KitL10n.string("这个目标还有未完成的命令，先等它结束")
        case "not_observed": KitL10n.string("暂时看不到这个 agent，请确认它在 Herdr 里运行后再试")
        default: nil
        }
    }

    public static func summary(_ text: String) -> String {
        if isIdentityPause(text) { return identityPauseCopy }
        if text == "rejected:identity_recover_private_only" { return KitL10n.string("恢复身份只能在私聊里发起") }
        if text.hasPrefix("rejected:identity_recover_refused:") {
            let reason = String(text.dropFirst("rejected:identity_recover_refused:".count))
            return identityRecoverRefusalCopy(reason) ?? KitL10n.string("恢复没有完成")
        }
        if let r = OwnerOperationParser.result(ack: text), let s = OwnerOperationParser.summary(r) { return s }
        if text.hasPrefix("queued:") { return KitL10n.string("已排队，等 agent 空闲后发送") }
        if text.hasPrefix("ack:") { return KitL10n.string("已受理") }
        if text.hasPrefix("switched:") {
            let body = text.dropFirst("switched:".count)
            let target = body.prefix { $0 != "@" && $0 != "（" }
            let note = body.firstIndex(of: "（").map { String(body[$0...]) } ?? ""
            return KitL10n.format("已切换到 %@%@", String(target), note)
        }
        if text.hasPrefix("rejected:") {
            let body = text.dropFirst("rejected:".count)
            if let i = body.firstIndex(of: "（") { return KitL10n.string("已拒绝") + String(body[i...]) }
            let code = body.prefix { $0 != ":" }
            return KitL10n.string("已拒绝 · ") + code.replacingOccurrences(of: "_", with: " ")
        }
        return text
    }
}

/// Owner 指令文本（与飞书私聊相同）。
public enum OwnerCommand {
    public static func switchTo(project: String, agent: String? = nil) -> String {
        agent.map { "切换到 \(project) \($0)" } ?? "切换到 \(project)"
    }
    public static let panel = "面板"
    public static let tasks = "任务"
    public static func resetOccupancy(_ project: String) -> String { "重置占用 \(project)" }
    /// 提醒卡的条件重置：Bridge 在同一事务里核对该目标当前阻塞的命令正是 eventKey，不符则拒绝（reset_stale）、零写入。
    public static func resetOccupancy(_ project: String, expectedEventKey: String) -> String { "重置占用 \(project) #\(expectedEventKey)" }
    /// Bridge 多匹配回执里候选列表的定位片段。
    public static let multiMatchMarker = "个 agent："
    public static let rejectedNotVerified = "rejected:target_not_verified"
    /// 直达派活：Bridge 的「派给 <agent名>：正文」。发送方保存用户原文，只在传输时包装。
    public static func direct(agent: String, text: String) -> String { "派给 \(agent)：\(text)" }
    /// 名字是合法 agent 名（`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`）。协作角色（`_execute`/`_advisor`）不再影响能否直达（#81）。
    public static func canDirect(agentName: String?) -> Bool {
        guard let n = agentName, let first = n.unicodeScalars.first, n.unicodeScalars.count <= 64 else { return false }
        func alnum(_ u: Unicode.Scalar) -> Bool { (48...57).contains(u.value) || (65...90).contains(u.value) || (97...122).contains(u.value) }
        return alnum(first) && n.unicodeScalars.allSatisfy { alnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }
}
