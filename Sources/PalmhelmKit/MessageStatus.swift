import Foundation

/// 一条消息此刻应显示的状态（#89 片 B）：阶段、一行文案与可选排队卡，三者同源，两端父级 / 行 / 账本共用。
/// 不是新状态机：阶段由 `OutgoingStatus` 与 `OutgoingStatusTracker` 给出，这里只负责把阶段与权威指令组合成呈现值。
public struct MessageStatus: Sendable, Equatable {
    public var phase: OutgoingPhase
    public var label: String
    /// 排队卡：只在阶段与指令一致地处于排队 / 发送中序列时有值；停止、未知、终态不借卡表达，直接用 label。
    public var card: QueueStatusCard?

    public init(phase: OutgoingPhase, label: String, card: QueueStatusCard? = nil) {
        self.phase = phase; self.label = label; self.card = card
    }
}

public enum MessageStatusRules {
    /// 一行文案：排队族且有权威指令时沿用统一的排队文案（含期限），其余按阶段。
    public static func label(_ phase: OutgoingPhase, command c: ApiCommand?, rejectText: String? = nil) -> String {
        if [.queued, .queuedSteer, .queuedNative].contains(phase), let c {
            return SendTimingCopy.commandStatus(state: "queued", reason: c.reason, lane: c.lane, direct: c.directAgent != nil, queueDeadlineT: c.queueDeadlineT)
        }
        return OutgoingStatus.label(phase, rejectText: rejectText)
    }

    /// 权威指令的事实（command-only 行：没有本机 Sent）。owner 指令的系统回执（ack）作为兜底来源。
    public static func facts(for c: ApiCommand, inflight: String? = nil, ackText: String? = nil) -> OutgoingFacts {
        var f = OutgoingFacts.fromCommand(c, inflight: inflight)
        f.ackText = ackText
        return f
    }

    /// 把已解析的阶段与指令组合成呈现值（阶段来自 tracker 或独立求值，调用方决定）。
    public static func status(for c: ApiCommand, phase: OutgoingPhase) -> MessageStatus {
        MessageStatus(phase: phase, label: label(phase, command: c), card: QueueStatusPresentation.card(for: c, phase: phase))
    }

    /// 不经 tracker 的独立求值（只读账本的历史行：不借历史改变当前 scope 的消息结论）。
    public static func standalone(_ c: ApiCommand) -> MessageStatus {
        status(for: c, phase: OutgoingStatus.phase(facts(for: c)))
    }

    /// 账本行的状态（#110 B）：只有来自 inbox 且带指令、指令与账本 scope 同目标的行参与。当前会话里有同 key（且同目标）的指令时，
    /// 交给 `live` 求值（两端的 `messageStatus(for:)`：同 inflight、同 tracker、同规则），所以账本与对话页同一事实给出同一结论；
    /// 没有当前指令时只对缓存的指令做独立求值（不借 scope 内别条消息、全局 working 或正文推断）。
    public static func ledger(row: TargetHistoryRow, scopeTarget: String, current: ApiCommand?, live: (ApiCommand) -> MessageStatus) -> MessageStatus? {
        guard row.source == "inbox", let cached = row.command, cached.targetId == scopeTarget, row.targetId == nil || row.targetId == scopeTarget else { return nil }
        if let current, current.key == cached.key, current.targetId == scopeTarget { return live(current) }
        return standalone(cached)
    }

    /// 回执关联的状态里，不应被 tracker 旧终态压住的强事实：精确 receipt 已给出的最终结果。
    public static func isStrongReceiptResult(_ p: OutgoingPhase) -> Bool {
        switch p {
        case .done, .merged, .withdrawn, .rejected, .expired, .queueStopped, .nativeDelivered, .nativeSendRequested, .nativeSendSkipped: true
        default: false
        }
    }
}

/// 最新阅读窗尾部的“当前指令 / 回显”投影（两端共用的纯结果）：期限行、补行与本机回显一次得出，同一份实际行集合决定去重与覆盖。
public struct ThreadTail<Echo> {
    /// 实际显示的期限行（排队中、已过期）。
    public var deadline: [ApiCommand]
    /// 实际补行（queued / started / unknown / paused，且不与记录、期限行、回显重复）。
    public var supplement: [ApiCommand]
    public var echoes: [Echo]

    public init(deadline: [ApiCommand] = [], supplement: [ApiCommand] = [], echoes: [Echo] = []) {
        self.deadline = deadline; self.supplement = supplement; self.echoes = echoes
    }

    public static var empty: ThreadTail { ThreadTail() }

    /// 期限行与补行按受理序合并成一条尾部序列。
    public var commandRows: [ApiCommand] { (deadline + supplement).sorted { $0.inboxSeq < $1.inboxSeq } }
}

extension ThreadTail: Equatable where Echo: Equatable {}

public enum ThreadTailRules {
    /// 最新阅读窗：可读、非定位页、窗口下方无行、无更新内容。历史 / 定位窗不追加当前指令的任何补充（数据仍保留）。
    public static func isLatest(_ t: TranscriptThread?) -> Bool {
        guard let t else { return false }
        return t.status == .ok && t.pinnedHit == nil && !t.hasRowsBelowWindow && !t.hasNewer
    }

    /// 期限行：窗口成员、未被记录关联、不属于其他原生会话代次。
    public static func deadline(commands: [ApiCommand], window: CommandWindow, linkedKeys: Set<String>, foreignKeys: Set<String>) -> [ApiCommand] {
        SendTimingRules.deadlineRows(commands.filter { window.contains($0.key) && !linkedKeys.contains($0.key) && !foreignKeys.contains($0.key) })
    }

    /// 已加载窗口里最晚的 user 记录时间（ms；Bridge 的 createdT 与 TranscriptItem.t 同单位）。
    public static func latestUserTime(_ t: TranscriptThread) -> Int? {
        t.items.last(where: { $0.role == "user" && $0.t != nil })?.t
    }

    /// 尾部投影：先定期限行，再把实际期限键交给回显规则，最后用回显键与期限键作为补行的覆盖集合。
    public static func tail<Echo>(commands: [ApiCommand], window: CommandWindow, threadId: String, transcript: TranscriptThread?, foreignKeys: Set<String>,
                                  echoes: (_ deadlineKeys: Set<String>) -> [Echo], echoKey: (Echo) -> String?) -> ThreadTail<Echo> {
        guard isLatest(transcript), let t = transcript else { return .empty }
        let mine = commands.filter { $0.targetId == threadId }
        let deadline = deadline(commands: mine, window: window, linkedKeys: t.linkedEventKeys, foreignKeys: foreignKeys)
        let deadlineKeys = Set(deadline.map(\.key))
        let shown = echoes(deadlineKeys)
        let covered = Set(shown.compactMap(echoKey)).union(deadlineKeys)
        let supplement = ThreadCommandSupplement.rows(commands: mine, window: window, threadId: threadId, linkedKeys: t.linkedEventKeys, coveredKeys: covered, foreignKeys: foreignKeys, latestWindow: true, latestUserT: latestUserTime(t))
        return ThreadTail(deadline: deadline, supplement: supplement, echoes: shown)
    }
}

/// 只读消息账本页面持有的 scope（目标 + 连接代次 + Bridge 身份 + 账户）：任一变化即视为旧页面，离页 / 零请求。
public struct LedgerScope: Equatable, Hashable, Sendable {
    public var targetId: String
    public var epoch: Int
    public var bridgeId: String
    public var accountId: String?
    public init(targetId: String, epoch: Int, bridgeId: String, accountId: String? = nil) {
        self.targetId = targetId; self.epoch = epoch; self.bridgeId = bridgeId; self.accountId = accountId
    }
}

extension LedgerScope: Identifiable { public var id: LedgerScope { self } }
