import Foundation

// #89 排队状态（两端共用）：Bridge 的扩展组（queueReason、queuePosition、observedAt、phase）与界面文案。
// 写模式的帧显式给出四键（不适用为 null）；旧 Bridge 不给任何键。键缺失 = 未启用（不是清除），null = 清除。

/// 扩展组的值。整组缺失时 ApiCommand.queue 为 nil。
public struct QueueMeta: Codable, Sendable, Equatable {
    public var reason: String?
    public var position: Int?
    /// 真实观察墙钟（毫秒）；为 nil 时不显示任何时间（不造时间）。
    public var observedAt: Int?
    public var phase: String?

    public init(reason: String? = nil, position: Int? = nil, observedAt: Int? = nil, phase: String? = nil) {
        self.reason = reason; self.position = position; self.observedAt = observedAt; self.phase = phase
    }

    /// 按状态去掉不再适用的字段（#89：离开排队清原因与排位，离开发送中清阶段）。
    public func applicable(toState state: String) -> QueueMeta? {
        switch state {
        case CommandState.queued.rawValue:
            return QueueMeta(reason: reason, position: position, observedAt: observedAt, phase: nil)
        case CommandState.started.rawValue:
            return QueueMeta(phase: phase)
        default:
            return nil
        }
    }

    /// 解码扩展组：四键全部缺失返回 nil（旧帧）；存在任一键即返回组，其余为 null 的字段为 nil。
    static func decode(from decoder: Decoder) throws -> QueueMeta? {
        let c = try decoder.container(keyedBy: WireKeys.self)
        guard c.contains(.queueReason) || c.contains(.queuePosition) || c.contains(.observedAt) || c.contains(.phase) else { return nil }
        return QueueMeta(
            reason: try c.decodeIfPresent(String.self, forKey: .queueReason),
            position: try c.decodeIfPresent(Int.self, forKey: .queuePosition),
            observedAt: try c.decodeIfPresent(Int.self, forKey: .observedAt),
            phase: try c.decodeIfPresent(String.self, forKey: .phase)
        )
    }

    /// 写模式的四键：整组写出（不适用的为 null），与解码互逆。
    func encodeWire(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKeys.self)
        try c.encode(reason, forKey: .queueReason)
        try c.encode(position, forKey: .queuePosition)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(phase, forKey: .phase)
    }

    private enum WireKeys: String, CodingKey { case queueReason, queuePosition, observedAt, phase }
}

/// 暂停分类（Bridge stopDisposition，只读事实）：只回答“能否证明从未派发”，不是停止原因。
/// - notDispatched：没有任何 commands 行引用该输入 → “已停止，未发出”；
/// - uncertain：存在引用，或 Bridge 给出 null / 未知值（容错解码），或旧 Bridge 缺键后的保守值 → “已停止跟踪，可能已执行”。
public enum StopDisposition: String, Codable, Sendable, Equatable {
    case notDispatched = "not_dispatched"
    case uncertain = "execution_uncertain"

    /// 键存在才返回值（含显式 null / 未知字符串 / 错误类型 → uncertain）；键缺失返回 nil（缺键 ≠ null）。
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> StopDisposition? {
        guard c.contains(key) else { return nil }
        let raw = (try? c.decode(String?.self, forKey: key)) ?? nil
        return raw == StopDisposition.notDispatched.rawValue ? .notDispatched : .uncertain
    }
}

/// progress 帧（SSE）：状态与可选原因，加上可选扩展组。
public struct ProgressPayload: Sendable, Equatable {
    public var eventKey: String
    public var state: String
    public var reason: String?
    /// nil = 旧帧（没有扩展组键）；非 nil = 写模式帧，整组替换。
    public var queue: QueueMeta?
    /// nil = 缺键（不抹已有事实）；非 nil = 暂停帧带的分类（显式 null / 未知已归一为 uncertain）。
    public var stop: StopDisposition?

    public init(eventKey: String, state: String, reason: String? = nil, queue: QueueMeta? = nil, stop: StopDisposition? = nil) {
        self.eventKey = eventKey; self.state = state; self.reason = reason; self.queue = queue; self.stop = stop
    }
}

/// 排队卡的呈现（两端共用的唯一文案来源）。nil = 不显示卡，沿用旧文案。
public struct QueueStatusCard: Sendable, Equatable {
    public var title: String
    public var detail: String?
    /// 有“原因待确认”或“尚无有效判定”这类不确定性时为 true（界面可用警示色；语义也写在文字里）。
    public var uncertain: Bool
    /// 排队期限（单独一行，不与 detail 互相覆盖）：只在 queued 且服务端给出 queueDeadlineT 时有值。
    public var deadlineText: String? = nil
}

public enum QueueStatusPresentation {
    /// 队列原因的固定文案；未知值降级为通用说明，不让整帧失败。
    public static func reasonText(_ reason: String) -> String {
        switch reason {
        case "paused": KitL10n.string("目标已暂停")
        case "config_unavailable": KitL10n.string("目标配置暂不可用")
        case "unknown_occupied": KitL10n.string("上一条送达结果未知，目标被占用")
        case "offline": KitL10n.string("目标不在线")
        case "wait_turn": KitL10n.string("等待目标空闲")
        case "draft": KitL10n.string("终端输入框有未发送的文字")
        case "screen_unknown": KitL10n.string("无法确认终端输入框是否为空")
        case "unconfirmed": KitL10n.string("原因待确认")
        case "unobserved": KitL10n.string("尚无有效判定")
        default: KitL10n.string("排队中")
        }
    }

    public static func phaseText(_ phase: String) -> String? {
        switch phase {
        case "dispatch": OutgoingStatus.label(.dispatching)
        case "awaiting": OutgoingStatus.label(.awaiting)
        case "running": OutgoingStatus.label(.processing)
        default: nil
        }
    }

    /// 观察时间的显示（只用于显示；毫秒转本地时分秒）。
    public static func observedText(_ ms: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return KitL10n.string("截至 ") + f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    /// 排队卡：排队中且有扩展组时给出位置与原因；发送中或已送达时给出阶段；其余不显示。
    public static func card(for c: ApiCommand) -> QueueStatusCard? {
        if c.state == CommandState.queued.rawValue {
            // 期限来自服务端 queueDeadlineT，与扩展组是否存在无关；两者都没有就不显示卡（沿用旧文案）。
            let deadline = c.queueDeadlineT.map(SendTimingCopy.deadlineText)
            guard c.queue != nil || deadline != nil else { return nil }
            let q = c.queue ?? QueueMeta()
            let reason = q.reason
            let uncertain = reason == "unconfirmed" || reason == "unobserved"
            var detail: String?
            switch reason {
            case nil:
                detail = nil
            case "unconfirmed":
                // 原因待确认必须带真实时间；没有时间即“尚无有效判定”（不造时间）。
                detail = q.observedAt.map { KitL10n.string("原因待确认 · ") + observedText($0) } ?? reasonText("unobserved")
            case "draft", "screen_unknown":
                detail = q.observedAt.map { reasonText(reason!) + " · " + observedText($0) } ?? reasonText(reason!)
            default:
                detail = reasonText(reason!)
            }
            let title: String
            if c.lane == "use" {
                title = KitL10n.string("补充排队")
            } else if let p = q.position {
                title = KitL10n.format("队列第 %lld 位", p)
            } else {
                title = KitL10n.string("排队中")
            }
            return QueueStatusCard(title: title, detail: detail, uncertain: uncertain, deadlineText: deadline)
        }
        if c.state == CommandState.started.rawValue, let phase = c.queue?.phase, let text = phaseText(phase) {
            return QueueStatusCard(title: text, detail: nil, uncertain: false)
        }
        return nil
    }

    /// 带已解析阶段的排队卡（tracker 之后）：卡标题必须与有效阶段一致。
    /// 排队序列（queued / 补充 / 原生排队）沿用 `card(for:)`（含期限）；发送中序列（正在发送 / 等待回合 / 回合进行中）以有效阶段文案为准，不带期限；
    /// 停止、未知、终态不借卡表达（调用方直接用阶段文案），避免 tracker 已不确定时仍展示 raw awaiting / running 卡。
    public static func card(for c: ApiCommand, phase: OutgoingPhase) -> QueueStatusCard? {
        switch phase {
        case .queued, .queuedSteer, .queuedNative:
            return c.state == CommandState.queued.rawValue ? card(for: c) : nil
        case .dispatching, .awaiting, .processing:
            return QueueStatusCard(title: OutgoingStatus.label(phase), detail: nil, uncertain: false)
        default:
            return nil
        }
    }

    /// 指令的排队卡是否真的会在界面上出现：飞书折叠行只显示一行文字，不渲染卡（#89 F4）。
    public static func rendersCard(_ c: ApiCommand, folded: Bool) -> Bool {
        !folded && card(for: c) != nil
    }

    /// 原生直达的投递回执（ack:<eventKey>）是否已被气泡自己的状态行表达（界面渲染层隐藏用，不删除数据）。
    /// 只认精确 eventKey 的 ack 身份与调用方已解析的有效阶段，不比较文案；其余回执（面板 / 任务 / 错误）不受影响。
    public static func statusCoversAck(uuid: String, eventKey: String, phase: OutgoingPhase?) -> Bool {
        guard let phase, [.nativeDelivered, .nativeSendRequested, .nativeSendSkipped].contains(phase) else { return false }
        return uuid == "ack:" + eventKey
    }

    /// 系统回执是否已被排队卡覆盖（界面渲染层隐藏用，不删除数据）。
    /// dirty 用 replyTo 指向的被挡消息键；busy 与 blocked 用去掉固定前缀后的完整 event_key（不切最后一个冒号）。
    public static func receiptCovered(uuid: String, replyTo: String?, coveredKeys: Set<String>) -> Bool {
        if uuid.hasPrefix("dirty:") {
            guard let replyTo else { return false }
            return coveredKeys.contains(replyTo)
        }
        for prefix in ["busy:", "blocked:"] where uuid.hasPrefix(prefix) {
            return coveredKeys.contains(String(uuid.dropFirst(prefix.count)))
        }
        return false
    }
}

/// 命令尚未出现时到达的 progress 帧序列（#89 O1-052 N1、O1-054）。
/// - 每 key 保存帧序列，最多保留最新 8 帧（超出丢最旧）；每帧带会话内单调递增的 SSE 序号（由调用方分配）。
/// - key 上限 200。满额时淘汰 FIFO：按“首次入表”的先后淘汰，之后对同一 key 的更新不移动次序。
/// - take 取出即消费：整个 key 的帧从表中移除。
/// - 会话代次变化（stopStream、重置）与 commands 重置时 clear；调用方同时把 SSE 序号归零。
public struct PendingProgress: Sendable {
    public static let capacity = 200
    public static let framesPerKey = 8

    private struct Frame: Sendable {
        let seq: Int
        let payload: ProgressPayload
    }

    private var order: [String] = []
    private var frames: [String: [Frame]] = [:]

    public init() {}

    public var count: Int { frames.count }

    public mutating func put(_ p: ProgressPayload, seq: Int) {
        if frames[p.eventKey] == nil {
            order.append(p.eventKey)
            if order.count > Self.capacity { frames[order.removeFirst()] = nil }
        }
        var list = frames[p.eventKey, default: []]
        list.append(Frame(seq: seq, payload: p))
        if list.count > Self.framesPerKey { list.removeFirst(list.count - Self.framesPerKey) }
        frames[p.eventKey] = list
    }

    /// 取出 key 的待物化帧（按序）。`after` 为 nil 时取全部（inbound 出现时）；否则只取序号大于 `after` 的帧
    /// （HTTP 快照只补请求发起之后到达的事实，更早的帧已被快照覆盖）。无论取到与否，整个 key 的帧都从表中移除。
    public mutating func take(_ key: String, after seqStart: Int?) -> [ProgressPayload] {
        guard let list = frames.removeValue(forKey: key) else { return [] }
        order.removeAll { $0 == key }
        return list.filter { f in seqStart.map { f.seq > $0 } ?? true }.map(\.payload)
    }

    public mutating func clear() {
        order = []
        frames = [:]
    }
}

/// 当前消息窗口（#89 片 A）：Session 私有、有界的“当前线程可能需要状态行的指令集合”。
/// 它只决定哪些已缓存指令可以在最新阅读窗里补行，不是消息状态机，也不删除 commands 缓存（精确关联仍靠字典）。
/// - 容量 200（Bridge commands 窗口上限）；成员来自成功 HTTP 的明确列表、本 scope 线上已接受的新 inbound / 已知指令的真实变化。
/// - HTTP 缺 commands 键 ≠ 空列表：缺键不改窗口（调用方不调 rebuild）；空列表移除非暂停旧成员。
/// - 本次缺席的暂停成员作为“最近停止”在余位内保留，先于更旧的停止被淘汰；超过容量按 inboxSeq 保留最新并记 truncated。
public struct CommandWindow: Sendable, Equatable {
    public static let capacity = 200

    struct Meta: Sendable, Equatable {
        var inboxSeq: Int
        var paused: Bool
        init(_ c: ApiCommand) { inboxSeq = c.inboxSeq; paused = c.state == CommandState.paused.rawValue }
    }

    private var meta: [String: Meta] = [:]
    /// 服务端窗口已满或本地容量截断过：入口提示“当前只显示部分消息”，不宣称全量。
    public private(set) var truncated = false

    public init() {}

    public var count: Int { meta.count }
    public func contains(_ key: String) -> Bool { meta[key] != nil }

    /// 可“同内容再次确认”的成员：只有真正非终态的 queued / started / unknown。paused 是终态：被淘汰后的同内容重放不得复活，
    /// 新的或内容真实改变的 paused 走 changed 分支按原预算准入。
    private static let reconfirmableStates: Set<String> = [CommandState.queued.rawValue, CommandState.started.rawValue, CommandState.unknown.rawValue]

    /// 同内容再次到来是否构成新的“存在”事实（调用方记序号，供请求期间的 HTTP 重建保留）。
    public static func isReconfirmable(_ c: ApiCommand) -> Bool { reconfirmableStates.contains(c.state) }

    /// inbound 采纳后是否要准入：内容变化，或这是一条仍非终态、却不在窗口里的指令（被 HTTP 空列表移除 / 被截断后同内容再次到来）。
    public func needsAdmission(_ c: ApiCommand, changed: Bool) -> Bool {
        changed || (Self.isReconfirmable(c) && !contains(c.key))
    }

    /// 超容量时的唯一选择：按 inboxSeq 保留最新（同值按 key 稳定），与 HTTP 重建同一条规则；新输入自身也参与比较。
    private static func fit(_ m: inout [String: Meta]) -> Bool {
        guard m.count > capacity else { return false }
        let keep = m.sorted { ($0.value.inboxSeq, $1.key) > ($1.value.inboxSeq, $0.key) }.prefix(capacity)
        m = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        return true
    }

    /// 线上新事实（inbound 新指令 / 已知指令真实变化 / 活动成员再次到来）：加入或更新成员；返回是否改变（含 truncated 翻转），调用方只在改变时才发布。
    @discardableResult
    public mutating func admit(_ c: ApiCommand) -> Bool {
        let m = Meta(c)
        if meta[c.key] == m { return false }
        let before = meta, wasTruncated = truncated
        meta[c.key] = m
        if Self.fit(&meta) { truncated = true }
        return meta != before || truncated != wasTruncated
    }

    /// 成功 HTTP 的明确指令列表 + 请求期间线上更新的成员（已是最新合并结果）。
    @discardableResult
    public mutating func rebuild(server: [ApiCommand], concurrent: [ApiCommand]) -> Bool {
        var next: [String: Meta] = [:]
        for c in server + concurrent { next[c.key] = Meta(c) }
        var cut = server.count >= Self.capacity
        if next.count > Self.capacity {
            _ = Self.fit(&next)
            cut = true
        }
        let stops = meta.filter { $0.value.paused && next[$0.key] == nil }.sorted { $0.value.inboxSeq > $1.value.inboxSeq }
        for s in stops where next.count < Self.capacity { next[s.key] = s.value }
        let changed = next != meta || cut != truncated
        meta = next
        truncated = cut
        return changed
    }

    public mutating func clear() { meta = [:]; truncated = false }
}

/// 最新阅读窗里需要补行的服务端指令（纯规则，两端 ThreadRows 共用）。只在最新原生阅读窗补；历史 / 定位窗不追加。
public enum ThreadCommandSupplement {
    /// - linkedKeys：会话记录已关联（含不在当前可见窗口的）的 eventKey：不补到尾部。
    /// - coveredKeys：本屏已由本机回显 / 期限行显示的 key：同 key 只显示一份正文。
    /// - foreignKeys：本机 Sent 带的会话代次与当前不同的 key（不属于当前原生会话）。
    /// - latestUserT：已加载窗口里最晚的 user 记录时间（ms）。unknown / paused 是结束状态，对话已有更晚的 user 回合后它属于历史（账本可查），不再挂在尾部；
    ///   queued / started 仍在途，不受影响；createdT 或 latestUserT 缺失时保持原行为。
    public static func rows(commands: [ApiCommand], window: CommandWindow, threadId: String, linkedKeys: Set<String>, coveredKeys: Set<String>,
                            foreignKeys: Set<String> = [], latestWindow: Bool, latestUserT: Int? = nil) -> [ApiCommand] {
        guard latestWindow else { return [] }
        let states: Set<String> = [CommandState.queued.rawValue, CommandState.started.rawValue, CommandState.unknown.rawValue, CommandState.paused.rawValue]
        func isHistory(_ c: ApiCommand) -> Bool {
            guard c.state == CommandState.unknown.rawValue || c.state == CommandState.paused.rawValue, let created = c.createdT, let latest = latestUserT else { return false }
            return latest > created
        }
        return commands.filter {
            $0.targetId == threadId && window.contains($0.key) && states.contains($0.state)
                && !linkedKeys.contains($0.key) && !coveredKeys.contains($0.key) && !foreignKeys.contains($0.key)
                && !isHistory($0)
        }.sorted { $0.inboxSeq < $1.inboxSeq }
    }
}
