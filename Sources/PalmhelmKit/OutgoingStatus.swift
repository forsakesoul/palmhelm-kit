import Foundation

/// 一条发出消息的状态阶段（#23 重做，设计稿 design/reins-message-status）。两端共用这一个权威：客户端不再自己拼状态文案。
/// 阶段只前进：迟到的旧状态不回退；终态之后不再变化；unknown 不是终态，但不会再回到「处理中」，可以解析为任一终态。
public enum OutgoingPhase: Sendable, Equatable, CaseIterable {
    case sending, queued, queuedSteer, delivered, processing, unknown, done, merged, withdrawn, rejected, failed, expired, queueStopped
    /// 普通发送：命令已进入派发（Bridge queue.phase = dispatch），文字正在写入目标。
    case dispatching
    /// 已送达，回合还没开始（phase = awaiting）；与全局 working 无关。
    case awaiting
    /// 暂停且有“从未派发”的证明（stopDisposition = not_dispatched），且没有送达 / 完成 / 并入等强事实冲突。
    case stopped
    /// 暂停但不能证明未发出（存在派发记录、缺键、null 或未知值）：可能已执行，不写“未发出 / 被拒绝”。
    case stoppedUncertain
    /// 原生直达插话：已写入工作中终端，但并入未验证（Bridge 的 native_delivered）。
    case nativeDelivered
    /// 已改为原生直达插话、仍在排队：只说明会写入工作中终端，不承诺并入当前回合。
    case queuedNative
    /// 已知以原生直达插话发出，权威快照还没给出 native_delivered：中性「待确认」，不说已完成或已并入。
    case nativePending
    /// 立即发送：文字已送达且快捷键已提交（native_send_now_requested）。处理时机未验证，可能另起一轮。
    case nativeSendRequested
    /// 立即发送：文字已送达但未按热键（native_send_now_skipped）。部分结果：不可报未发送，不进入重试或恢复草稿。
    case nativeSendSkipped
    /// 原生直达插话被 Bridge 暂停：未送达，不会自动重发（O1-068）。本机保留失败行，等用户处理。
    case nativePaused
    /// owner 操作（面板 / 任务 / 重置占用 / 切换）已受理，系统回执还没到：不是排队，也不是 agent 在处理。
    case ownerSubmitted

    /// 单调排序（同一数值的阶段只有在相同时才视为不变；queued 与 queuedSteer 只由指令车道决定，不互相切换）。
    public var rank: Int {
        switch self {
        case .sending: 0
        case .ownerSubmitted: 12
        case .queued, .queuedSteer, .queuedNative: 10
        case .dispatching: 15
        case .delivered: 20
        case .awaiting: 22
        case .processing: 30
        case .unknown, .nativePending: 35
        case .done, .merged, .withdrawn, .rejected, .failed, .expired, .queueStopped, .nativeDelivered, .nativeSendRequested, .nativeSendSkipped, .nativePaused, .stopped, .stoppedUncertain: 40
        }
    }

    public var isTerminal: Bool { rank == 40 }
}

/// 解析阶段所需的事实（全部来自已有的投影，不含正文）。
public struct OutgoingFacts: Sendable, Equatable {
    public var hasEventKey: Bool // 发送响应已返回 eventKey：Bridge 已受理
    public var localError: Bool // 本机发送失败（HTTP / 网络）
    public var localUnknown: Bool // 本机发送结果不明（无效回复等）：不是确定失败，不给重试
    public var commandState: String? // ApiCommand.state
    public var commandReason: String? // ApiCommand.reason：withdrawn / merged
    public var steer: Bool // 指令车道为补充（use）
    public var receiptState: String? // TranscriptReceipt.receiptState：accepted / sent / done / unknown
    public var receiptMerged: Bool // TranscriptReceipt.reason == merged
    public var rejectText: String? // 拒绝原因短语（rejected: 回执）
    /// 目标当前正在工作。不再参与本条消息的阶段判定（全局忙不等于本条已开始处理）；保留字段只为调用方兼容。
    public var agentWorking: Bool
    public var nativeSteer: Bool // 以原生直达发出（mode=steer 或 send_now，且目标为直达）
    /// 本机回显对应的系统回执正文（uuid 为 ack:<eventKey>）。owner 指令（切换到等）不建排队指令，只能靠它收敛（#96）。
    public var ackText: String?
    /// 权威指令适用的发送阶段（queue.phase：dispatch / awaiting / running）；缺 = 旧 Bridge 或不适用。
    public var commandPhase: String?
    /// 权威指令的暂停分类；缺 = 缺键 / 非暂停。
    public var stop: StopDisposition?
    /// 本机发出的 owner 操作种类；非 nil 时没有排队指令记录，只由系统回执收敛。
    public var ownerKind: OwnerOperationKind?

    /// 从权威指令填充事实（两端 Session、回执关联与指令文案共用的唯一入口）。`inflight` 为进度表里更新的状态（缺省用指令自身状态）。
    public static func fromCommand(_ c: ApiCommand, inflight: String? = nil, agentWorking: Bool = false) -> OutgoingFacts {
        let state = inflight ?? c.state
        var f = OutgoingFacts(hasEventKey: true, commandState: state, commandReason: c.reason, steer: c.lane == "use", agentWorking: agentWorking,
                              nativeSteer: c.directAgent != nil && c.lane == "use")
        if state == CommandState.started.rawValue { f.commandPhase = c.queue?.phase }
        if state == CommandState.paused.rawValue { f.stop = c.stopDisposition }
        return f
    }

    /// 会话记录回执的事实。回执不带 native 信息：只有能对上权威指令（同一 eventKey）时才叠加它的 reason（C2'）。
    /// 回执的 receiptState 原样保留：原生插话的回执本就是 unknown（Bridge steer-dispatch），普通 done 仍是已完成。
    /// `command` 只在 eventKey 与回执精确相等时才使用（防误用：不按正文、时间或项目名配对）。
    public static func fromReceipt(_ r: TranscriptReceipt, agentWorking: Bool = false, command: ApiCommand? = nil, inflight: String? = nil) -> OutgoingFacts {
        let linked = r.eventKey != nil && command?.key == r.eventKey ? command : nil
        var f = linked.map { fromCommand($0, inflight: inflight, agentWorking: agentWorking) } ?? OutgoingFacts(hasEventKey: true, agentWorking: agentWorking)
        f.receiptState = r.receiptState
        f.receiptMerged = r.reason == "merged"
        return f
    }

    public init(hasEventKey: Bool = false, localError: Bool = false, localUnknown: Bool = false, commandState: String? = nil, commandReason: String? = nil,
                steer: Bool = false, receiptState: String? = nil, receiptMerged: Bool = false, rejectText: String? = nil, agentWorking: Bool = false,
                nativeSteer: Bool = false, ackText: String? = nil, commandPhase: String? = nil, stop: StopDisposition? = nil, ownerKind: OwnerOperationKind? = nil) {
        self.commandPhase = commandPhase; self.stop = stop; self.ownerKind = ownerKind
        self.hasEventKey = hasEventKey; self.localError = localError; self.localUnknown = localUnknown; self.commandState = commandState; self.commandReason = commandReason
        self.steer = steer; self.receiptState = receiptState; self.receiptMerged = receiptMerged; self.rejectText = rejectText; self.agentWorking = agentWorking
        self.nativeSteer = nativeSteer; self.ackText = ackText
    }

    /// 按回显的 eventKey 在历史里找系统回执（uuid 为 ack:<eventKey>）的正文；没有则为 nil。
    /// 双重关联：uuid 精确为 ack:<eventKey> 且 replyTo 精确等于 eventKey（Bridge 的 outbox 触发器为 ack 回填 replyTo）；缺 / 错的 replyTo 不采纳。
    public static func ackText(eventKey: String, in items: [HistoryItem]) -> String? {
        items.last { $0.uuid == "ack:" + eventKey && $0.replyTo == eventKey }?.text
    }
}

public enum OutgoingStatus {
    /// 事实 → 阶段（优先级：失败 > 撤回 > 拒绝 > 并入 > 完成 > 结果未知 > 处理中 / 已送达 > 排队 > 发送中）。
    public static func phase(_ f: OutgoingFacts) -> OutgoingPhase {
        if f.localError { return .failed }
        if f.localUnknown { return .unknown }
        if f.commandReason == "queue_expired" { return .expired }
        if f.commandReason == "queue_expired_uncertain" { return .queueStopped }
        if f.commandReason == "withdrawn" { return .withdrawn }
        if f.commandState == "rejected" || f.rejectText != nil { return .rejected }
        // 暂停：普通暂停不是“被拒绝”。只有 Bridge 证明从未派发、且没有送达 / 完成 / 并入等强事实冲突，才写“未发出”；其余保守为可能已执行。
        // 已有 native_* / merged 等准确结果时不在这里改写，交给下面各自的分支。
        if f.commandState == "paused", !hasStrongResult(f) {
            let conflict = ["sent", "done", "unknown"].contains(f.receiptState ?? "")
            if f.stop == .notDispatched, !conflict { return f.nativeSteer ? .nativePaused : .stopped }
            return .stoppedUncertain
        }
        if f.commandReason == "native_delivered" { return .nativeDelivered }
        if f.commandReason == "native_send_now_requested" { return .nativeSendRequested }
        if f.commandReason == "native_send_now_skipped" { return .nativeSendSkipped }
        if f.commandReason == "merged" || f.receiptMerged { return .merged }
        if f.commandState == "finished" || f.receiptState == "done" { return f.nativeSteer ? .nativePending : .done }
        if f.commandState == "unknown" || f.receiptState == "unknown" { return .unknown }
        // owner 指令没有排队的指令记录（#96）：系统回执说明已处理（切换到 → 已完成；被拒绝 → 已拒绝）。普通排队消息的回执是 queued:，不在此列。
        // 本机 owner 操作（没有指令记录）：按操作种类只认它自己的明确结果；畸形 / 未知 / 种类不符的回执不造完成，停在“已提交”。
        if f.commandState == nil, let kind = f.ownerKind {
            return ownerPhase(kind, ack: f.ackText, hasEventKey: f.hasEventKey)
        }
        // 旧路径（无 ownerKind）：切换 / 拒绝的系统回执收敛（#96）；普通排队消息的回执是 queued:，不在此列。
        if f.commandState == nil, let ack = f.ackText {
            if ack.hasPrefix("switched:") { return .done }
            if ack.hasPrefix("rejected:") { return .rejected }
        }
        if f.commandState == "started" || f.receiptState == "sent" {
            // 只按本条指令的规范阶段推进；缺阶段（旧 Bridge）是中性“已送达”，不由目标忙闲推断。
            switch f.commandState == "started" ? f.commandPhase : nil {
            case "dispatch": return .dispatching
            case "awaiting": return .awaiting
            case "running": return .processing
            default: return .delivered
            }
        }
        if f.commandState == "queued" || f.receiptState == "accepted" || f.hasEventKey {
            if f.steer && f.commandState == "queued" { return f.nativeSteer ? .queuedNative : .queuedSteer }
            return .queued
        }
        return .sending
    }

    private static func ownerPhase(_ kind: OwnerOperationKind, ack: String?, hasEventKey: Bool) -> OutgoingPhase {
        guard hasEventKey else { return .sending }
        guard let ack else { return .ownerSubmitted }
        let result = OwnerOperationParser.result(ack: ack)
        if case .rejected = result { return .rejected }
        switch kind {
        case .resetOccupancy: if case .reset = result { return .done }
        case .switchTo: if case .switched = result { return .done }
        // 面板 / 任务的结果是正文分片：首片就是 Bridge 的明确处理结果；排队类回执（queued:）不是。
        case .panel, .tasks: if !ack.isEmpty, !ack.hasPrefix("queued:"), result == nil { return .done }
        }
        return .ownerSubmitted
    }

    private static func hasStrongResult(_ f: OutgoingFacts) -> Bool {
        f.receiptMerged || ["merged", "native_delivered", "native_send_now_requested", "native_send_now_skipped"].contains(f.commandReason ?? "")
    }

    /// 一行文案。rejected 需要原因短语（缺省「被拒绝」）。
    public static func label(_ p: OutgoingPhase, rejectText: String? = nil, locale: Locale = .autoupdatingCurrent) -> String {
        switch p {
        case .sending: KitL10n.string("kit.sending.ellipsis", default: "发送中…")
        case .queued: KitL10n.string("排队中 · 本轮结束后发送")
        case .queuedSteer: KitL10n.string("补充排队中 · 将并入当前回合")
        case .queuedNative: SendTimingCopy.queuedNative
        case .delivered: KitL10n.string("已送达")
        case .dispatching: KitL10n.string("正在发送")
        case .awaiting: KitL10n.string("已送达 · 等待回合开始")
        case .processing: KitL10n.string("已送达 · 回合进行中")
        case .stopped: KitL10n.string("已停止，未发出")
        case .stoppedUncertain: KitL10n.string("已停止跟踪，可能已执行")
        case .unknown: KitL10n.string("结果未知")
        case .done: KitL10n.string("已完成")
        case .nativeDelivered: KitL10n.string("已送达工作中终端（并入未验证）")
        case .nativePending: KitL10n.string("待确认")
        case .nativeSendRequested: KitL10n.string("已送达并提交立即发送快捷键（可能另起一轮，处理未验证）")
        case .nativeSendSkipped: KitL10n.string("文字已送达，未触发立即发送")
        case .nativePaused: KitL10n.string("未发送 · 已暂停，不会自动重发")
        case .ownerSubmitted: KitL10n.string("已提交操作，等待结果")
        case .merged: CommandCopy.text(.merged, locale: locale)
        case .withdrawn: CommandCopy.text(.withdrawn, locale: locale)
        case .expired: CommandCopy.text(.queueExpired, locale: locale)
        case .queueStopped: CommandCopy.text(.queueExpiredUncertain, locale: locale)
        case .rejected: KitL10n.string("未发出 · ") + (rejectText ?? KitL10n.string("被拒绝"))
        case .failed: KitL10n.string("发送失败 · 重试")
        }
    }

    /// 来源行 / 气泡下方的唯一一行：「[经 Palmhelm ·] 状态 · 时间」。终端直接输入不走这里（TranscriptCopy 处理）。
    public static func line(label: String, time: String?) -> String {
        [label, time].compactMap { $0 }.joined(separator: " · ")
    }
}

/// 同一消息的阶段只前进（O1-365）：记录每条消息见过的最高阶段，迟到的旧事实不把它拉回去。
/// 纯值类型，由持有者（会话状态）保存；键通常是 eventKey 或本机发送 id。
public struct OutgoingStatusTracker: Sendable {
    private var seen: [String: OutgoingPhase] = [:]
    /// 见过“可能已送达”的证据（派发 / 已送达 / 处理中 / 结果未知）的消息：之后不得再被细化为“未发出”。
    private var sawDelivery: Set<String> = []
    public init() {}

    private static let unsentClaims: Set<OutgoingPhase> = [.stopped, .nativePaused]

    /// 在事实被采纳的共同入口记录“可能已送达”的证据（Session 的 SSE / HTTP / progress 采纳后调用），不依赖视图读取时机：
    /// 同一事件序列，先读到 started 与直到暂停才首次读取结论一致。只记证据，不改已见阶段。
    public mutating func observe(_ c: ApiCommand, inflight: String? = nil) {
        observe(key: c.key, facts: OutgoingFacts.fromCommand(c, inflight: inflight))
    }

    /// 命令尚未出现时到达的 progress（待物化帧）：按每个被接受的帧各记一次，不等物化后只看最后的 reduce 结果；
    /// 待物化帧有界淘汰也不丢证据。只用状态与阶段，不造 ApiCommand。
    public mutating func observeProgress(key: String, state: String, phase: String? = nil) {
        observe(key: key, facts: OutgoingFacts(hasEventKey: true, commandState: state, commandPhase: state == CommandState.started.rawValue ? phase : nil))
    }

    private mutating func observe(key: String, facts: OutgoingFacts) {
        if (15...35).contains(OutgoingStatus.phase(facts).rank) { sawDelivery.insert(key) }
    }

    /// 返回这条消息应显示的阶段：新阶段不低于已见阶段才接受；终态不变；unknown / 待确认 只能进入终态。
    /// 唯一的终态细化：done（finished 无 reason）经权威快照的 native_delivered / 立即发送结果变为对应终态；迟到的无 reason 快照不回退。
    public mutating func advance(_ key: String, to raw: OutgoingPhase) -> OutgoingPhase {
        if (15...35).contains(raw.rank) { sawDelivery.insert(key) }
        // 任何入口：见过送达 / unknown 证据的消息，不得再被断言“未发出”（冲突时保守为“可能已执行”）。
        let next = Self.unsentClaims.contains(raw) && sawDelivery.contains(key) ? OutgoingPhase.stoppedUncertain : raw
        guard let prev = seen[key] else {
            seen[key] = next
            return next
        }
        if prev == next { return prev }
        if prev == .done && [.nativeDelivered, .nativeSendRequested, .nativeSendSkipped].contains(next) { seen[key] = next; return next }
        // 同一消息、同一暂停的受限细化：“未发出”遇到显式不确定 / 冲突必须变保守；无证明可在从未见过送达证据时细化为“未发出”。
        if Self.unsentClaims.contains(prev), next == .stoppedUncertain { seen[key] = next; return next }
        if prev == .stoppedUncertain, Self.unsentClaims.contains(next), !sawDelivery.contains(key) { seen[key] = next; return next }
        if prev.isTerminal { return prev }
        if next.rank > prev.rank || ([.unknown, .nativePending].contains(prev) && next.isTerminal) { seen[key] = next }
        return seen[key] ?? prev
    }

    public func current(_ key: String) -> OutgoingPhase? { seen[key] }
}
