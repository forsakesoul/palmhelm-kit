import Foundation

// 发送时机的界面规则（#23）：两端共用，只做判定，不碰界面。
// 菜单只在目标工作中出现；「立即插入」只有 Bridge 声明支持时可用，否则灰掉并写原因；⌘↩ 在不支持时不能悄悄变成排队。

public enum SendMenuChoice: Sendable, Equatable {
    case queueAfterTurn, steerNow, sendNow, queueOneHour, queueOneDay

    public var mode: SendMode {
        switch self { case .steerNow: .steer; case .sendNow: .sendNow; default: .queue }
    }
    public var queueTTLSeconds: Int? {
        switch self { case .queueOneHour: 3600; case .queueOneDay: 86400; default: nil }
    }
    /// 发送方式的图标（SF Symbol 名）：两端浮层与入口行共用。
    public var symbol: String {
        switch self {
        case .queueAfterTurn: "clock"
        case .steerNow: "arrow.turn.down.right"
        case .sendNow: "paperplane"
        case .queueOneHour: "hourglass"
        case .queueOneDay: "calendar"
        }
    }
    public var title: String {
        switch self {
        case .queueAfterTurn: KitL10n.string("本轮结束后发送 · 一直等待")
        case .steerNow: KitL10n.string("立即插入当前回合")
        case .sendNow: SendTimingCopy.sendNowLabel
        case .queueOneHour: KitL10n.string("1 小时内开始")
        case .queueOneDay: KitL10n.string("24 小时内开始")
        }
    }
}

public struct SendMenuItem: Sendable, Equatable {
    public let choice: SendMenuChoice
    public let enabled: Bool
    /// 灰掉时的原因（可用时为 nil）。
    public let disabledReason: String?
}

public enum CommandReturnOutcome: Sendable, Equatable {
    case send(SendMode?)
    case blocked(reason: String)
}

public enum QueuedAction: Sendable, Hashable {
    case withdraw, promote, promoteSendNow, resend
    public var title: String {
        switch self {
        case .withdraw: KitL10n.string("撤回")
        case .promote: KitL10n.string("改为立即插入")
        case .promoteSendNow: KitL10n.format("改为%@", SendTimingCopy.sendNowLabel)
        case .resend: KitL10n.string("重新发送")
        }
    }
}

/// 排队消息的一个操作及其可用性。灰显（enabled = false）时带原因；任何入口（按钮、对话框、AX）都不得发请求。
public struct QueuedActionItem: Sendable, Equatable {
    public let action: QueuedAction
    public let enabled: Bool
    public let disabledReason: String?
    public init(action: QueuedAction, enabled: Bool, disabledReason: String?) {
        self.action = action; self.enabled = enabled; self.disabledReason = disabledReason
    }
    /// 按钮 / 对话框 / AX 共用的标题：灰显时带原因。
    public var title: String { enabled ? action.title : "\(action.title) — \(disabledReason ?? "不可用")" }
}

public enum QueuedResendRoute: Sendable, Equatable {
    case bound, direct(String), blocked
}

public enum SendTimingRules {
    /// 重发保持原路由：原绑定消息必须仍绑定原目标；原直达消息只可发回同名、可直达的原目标。
    public static func resendRoute(_ command: ApiCommand, bindingTargetId: String?, target: TargetSummary) -> QueuedResendRoute {
        guard target.id == command.targetId else { return .blocked }
        if let agent = command.directAgent {
            return OwnerCommand.canDirect(agentName: agent) && target.agentName == agent ? .direct(agent) : .blocked
        }
        return bindingTargetId == command.targetId ? .bound : .blocked
    }

    /// 未派发的期限行不会出现在 agent transcript；独立保留正文与操作，也用于重启后的快照。
    public static func deadlineRows(_ commands: [ApiCommand]) -> [ApiCommand] {
        commands.filter {
            ($0.state == "queued" && $0.queueDeadlineT != nil) || $0.reason == "queue_expired" || $0.reason == "queue_expired_uncertain"
        }.sorted { $0.inboxSeq < $1.inboxSeq }
    }

    /// 排队状态族（排队中 / 补充排队 / 已撤回 / 已并入）：这些状态由状态行统一表达，身份行不再重复状态（O1-327）。
    public static func isQueuedFamily(state: String, reason: String?) -> Bool {
        state == CommandState.queued.rawValue || reason == "withdrawn" || reason == "merged" || reason == "native_delivered" || reason == "queue_expired" || reason == "queue_expired_uncertain"
            || reason == "native_send_now_requested" || reason == "native_send_now_skipped"
    }

    /// 以原生直达插话发出、权威快照还没给出 native_delivered：显示「待确认」，不说已完成（与 OutgoingStatus.nativePending 同一判据）。
    public static func isNativePending(_ c: ApiCommand) -> Bool {
        c.state == "finished" && c.reason == nil && c.lane == "use" && c.directAgent != nil
    }

    /// 发送按钮的下拉箭头：只在目标工作中出现（空闲时发送就是普通发送）。直达与绑定目标一样（O1-325）。
    public static func showsMenu(targetStatus: String?) -> Bool { targetStatus == "working" }

    /// 主按钮与回车用的 mode（#77）：
    /// - 直达 Claude、目标工作中、Bridge 声明 nativeSteer → 立即插入（steer，走既有直达插话链路）；
    /// - 工作中的绑定目标 → 「本轮结束后发送」排队；
    /// - 其它（空闲、非 Claude、缺能力位、旧 Bridge）→ 不传 mode（直达的请求形状不变）。
    /// hook 的 steer 不授权直达；kind 与 nativeSteer 缺省时等同旧规则（Watch 保持缺省）。
    public static func primaryMode(direct: Bool, targetStatus: String?, kind: String? = nil, nativeSteer: Bool = false) -> SendMode? {
        if direct, kind == "claude", targetStatus == "working", nativeSteer { return .steer }
        return !direct && showsMenu(targetStatus: targetStatus) ? .queue : nil
    }

    /// 菜单项。排队永远可用；立即插入按路由：绑定目标看 hook 的 steer，直达只看 Bridge 的 nativeSteer（hook steer 不授权直达）。
    /// 立即发送只出现在直达目标：nil 隐藏、false 灰显、true 可选；绑定目标永不出现，且不借 steer / nativeSteer 授权。
    public static func menu(steer: SteerAvailability, direct: Bool = false, nativeSteer: Bool = false, nativeSendNow: Bool? = nil, queueDeadline: Bool = false) -> [SendMenuItem] {
        let steerEnabled = direct ? nativeSteer : steer == .available
        let sendNow: [SendMenuItem] = direct && nativeSendNow != nil ? [
            SendMenuItem(choice: .sendNow, enabled: nativeSendNow == true, disabledReason: nativeSendNow == true ? nil : SendTimingCopy.directNoSteer),
        ] : []
        return [
            SendMenuItem(choice: .queueAfterTurn, enabled: true, disabledReason: nil),
            SendMenuItem(
                choice: .steerNow,
                enabled: steerEnabled,
                disabledReason: steerEnabled ? nil : (direct ? SendTimingCopy.directNoSteer : steerDisabledReason(steer))
            ),
        ] + sendNow + (queueDeadline ? [.queueOneHour, .queueOneDay].map {
            SendMenuItem(choice: $0, enabled: true, disabledReason: nil)
        } : [])
    }

    /// ⌘↩：空闲 → 普通发送（旧行为）；直达无论工作与否都是普通发送（工作中即排队，立即插入只从菜单显式选择，Owner 裁决 S5）；
    /// 绑定目标工作中且支持 → 立即插入；工作中但不支持 → 拦下并说明，绝不排队。
    public static func commandReturn(working: Bool, steer: SteerAvailability, direct: Bool = false) -> CommandReturnOutcome {
        guard working, !direct else { return .send(nil) }
        if steer == .available { return .send(.steer) }
        return .blocked(reason: steerDisabledReason(steer) ?? SendTimingCopy.steerUnavailable)
    }

    /// 排队中的消息可做的操作。撤回只在未派发（queued）且未撤回时；改为立即插入按原消息的路由判定：
    /// 绑定消息看 hook 的 steer，直达消息只看原目标的 nativeSteer（调用方传原 ApiCommand 的 directAgent 与原目标能力）。
    /// 改为立即发送只对原直达消息出现（nil 隐藏、false 灰显带原因、true 可选），能力由原目标的 nativeSendNow 给出。
    /// 只返回当前可用的操作（旧调用方与测试用）；界面需要灰显原因时用 queuedActionItems。
    public static func queuedActions(state: String, reason: String?, steer: SteerAvailability, direct: Bool = false, nativeSteer: Bool = false, nativeSendNow: Bool? = nil) -> [QueuedAction] {
        queuedActionItems(state: state, reason: reason, steer: steer, direct: direct, nativeSteer: nativeSteer, nativeSendNow: nativeSendNow).filter(\.enabled).map(\.action)
    }

    public static func queuedActionItems(state: String, reason: String?, steer: SteerAvailability, direct: Bool = false, nativeSteer: Bool = false, nativeSendNow: Bool? = nil) -> [QueuedActionItem] {
        if state == "paused", reason == "queue_expired" { return [QueuedActionItem(action: .resend, enabled: true, disabledReason: nil)] }
        guard state == CommandState.queued.rawValue, reason != "withdrawn" else { return [] }
        var items = [QueuedActionItem(action: .withdraw, enabled: true, disabledReason: nil)]
        if direct ? nativeSteer : steer == .available {
            items.append(QueuedActionItem(action: .promote, enabled: true, disabledReason: nil))
        }
        if direct, let nativeSendNow {
            items.append(QueuedActionItem(
                action: .promoteSendNow,
                enabled: nativeSendNow,
                disabledReason: nativeSendNow ? nil : SendTimingCopy.directNoSteer
            ))
        }
        return items
    }

    static func steerDisabledReason(_ steer: SteerAvailability) -> String? {
        switch steer {
        case .available: nil
        case .unavailable: SendTimingCopy.steerUnavailable
        case .unknown: KitL10n.string("当前 Bridge 没有声明是否支持立即插入，请升级 Bridge")
        }
    }
}

/// 命令行的合并规则（两端共用，#89 S2 收敛）。三条规则，全部在这里实现，两端只调用：
/// A. 状态能否接受：canFollow，基于 Bridge INBOX_TRANSITIONS 的多步可达性（读面与 SSE 都可能跳过中间状态）。
/// B. 扩展组归属：最终接受的命令决定组（状态与车道的适用性在所有返回路径上规范化）。
/// C. inflight 派生：已知命令的在途状态以最终命令为准；只有无命令的 key 才回退到本地或快照。
public enum CommandMerge {
    /// Bridge internal/inboxstate/status.go 的 INBOX_TRANSITIONS，客户端只保留会被观察到的边。
    /// 普通车道的 sending → queued（恢复）不参与：恢复只经 queued_use（线上 queued + lane=use，由调用方的有序来源规则接受）。
    private static var dbEdges: [String: [String]] { [
        "queued": ["sending", "queued_use", "paused_blocked", "finished", "withdrawn"],
        "queued_use": ["sending", "paused_blocked", "finished", "withdrawn"],
        "sending": ["queued_use", "delivered", "unknown", "paused_blocked", "finished"],
        "delivered": ["unknown", "paused_blocked", "finished"],
        "unknown": ["paused_blocked", "finished"],
    ] }
    private static let dbStates = ["queued", "queued_use", "sending", "delivered", "unknown", "finished", "paused_blocked", "paused_closed", "rejected", "withdrawn"]

    /// 数据库状态投影到线上状态。
    private static func wire(_ db: String) -> String? {
        switch db {
        case "queued", "queued_use": CommandState.queued.rawValue
        case "sending", "delivered": CommandState.started.rawValue
        case "unknown": "unknown"
        case "finished": "finished"
        case "paused_blocked", "paused_closed": "paused"
        case "rejected", "withdrawn": "rejected"
        default: nil
        }
    }

    private static func isTerminal(_ state: String) -> Bool {
        state == "finished" || state == "paused" || state == "rejected"
    }

    /// 线上 from 之后能否到达 to：从 from 的任一数据库状态出发，沿合法边多步可达（不含 started → queued，那一条由 lane 与来源规则决定）。
    /// 未知的 to 不做判断，但已知终态不再接受任何变化（不重开终态）。
    public static func canFollow(from: String, to: String) -> Bool {
        if from == to { return true }
        if from == CommandState.started.rawValue && to == CommandState.queued.rawValue { return false }
        if isTerminal(from) { return false }
        guard ["queued", "started", "unknown"].contains(from) else { return true }
        guard ["queued", "started", "unknown", "finished", "paused", "rejected"].contains(to) else { return true }
        var seen = Set<String>()
        var frontier = dbStates.filter { wire($0) == from }
        while let db = frontier.popLast() {
            if !seen.insert(db).inserted { continue }
            if wire(db) == to { return true }
            frontier.append(contentsOf: dbEdges[db] ?? [])
        }
        return false
    }

    /// 完整判定（规则 A + O1-048 恢复边）：started → queued 仅当新命令 lane = use 且来源有序。
    public static func canFollow(from: String, to: String, lane: String?, ordered: Bool) -> Bool {
        if from == CommandState.started.rawValue && to == CommandState.queued.rawValue {
            return lane == "use" && ordered
        }
        return canFollow(from: from, to: to)
    }

    /// progress 帧能否改写这条指令的状态（规则 A；progress 来自有序的 SSE）。
    public static func progressAccepted(_ c: ApiCommand, state: String) -> Bool {
        canFollow(from: c.state, to: state, lane: c.lane, ordered: true)
    }

    /// 规则 B 的规范化：组只保留给仍适用的状态与车道；离开排队清原因与位置，离开发送中清阶段；车道不是 ordinary 时为空组。
    /// 缺四键的旧帧（组为 nil）保持 nil。
    private static func settled(_ c: ApiCommand) -> ApiCommand {
        var out = c
        // 暂停分类只属于暂停态：离开（或不在）暂停时无条件清除，不依赖扩展组是否存在（队列组缺失时也必须清）。
        if out.state != CommandState.paused.rawValue { out.stopDisposition = nil }
        guard let q = out.queue else { return out }
        out.queue = q.applicable(toState: out.state)
        if (out.lane ?? "ordinary") != "ordinary", out.queue != nil { out.queue = QueueMeta() }
        return out
    }

    /// 增量合并（inbound，有序）：较新的事实（车道、mode、直达路由）照常更新；状态不可接受时保留本地阶段。
    public static func merged(old: ApiCommand?, new: ApiCommand, ordered: Bool = true) -> ApiCommand {
        guard let old else { return settled(new) }
        var out = new
        if !canFollow(from: old.state, to: new.state, lane: new.lane, ordered: ordered) {
            out.state = old.state
            out.reason = old.reason ?? new.reason
            out.queue = old.queue
            // 被拒绝的倒退帧不借 stop：最终接受的状态连同它的暂停分类一起保留。
            out.stopDisposition = old.stopDisposition
            return settled(out)
        }
        // reason 一旦出现就留在这一行：merged（已并入）经过 started → finished 仍然成立；撤回也是事实。
        if let kept = old.reason, new.reason == nil { out.reason = kept }
        // 增量帧：不带组即未启用（旧 Bridge），保留原组；带组即整组替换。
        out.queue = new.queue ?? old.queue
        // 同一暂停生命周期：缺键的旧增量不抹已见事实；显式值（含 null / 未知 → uncertain）有序覆盖。
        out.stopDisposition = new.stopDisposition ?? old.stopDisposition
        return settled(out)
    }

    /// 权威快照（HTTP）与本地行合并（规则 A + B）。
    /// - 状态不可接受：保留本地状态与组（规范化后）。
    /// - 最终状态与车道都等于本地，且本地在快照途中被 SSE 更新过：保留本地组（含显式 null）。
    /// - 其他情况：采用快照（最终来源）的组；快照不带四键即旧 Bridge，清除（F3）。
    public static func snapshotMerged(old: ApiCommand?, new: ApiCommand, touchedDuringRequest: Bool) -> ApiCommand {
        guard let old else { return settled(new) }
        var out = merged(old: old, new: new, ordered: !touchedDuringRequest)
        if !canFollow(from: old.state, to: new.state, lane: new.lane, ordered: !touchedDuringRequest) { return out }
        let sameState = old.state == new.state
        let sameLane = (old.lane ?? "ordinary") == (new.lane ?? "ordinary")
        out.queue = touchedDuringRequest && sameState && sameLane ? old.queue : new.queue
        // 暂停分类不随队列组的“缺键即清除”：快照途中被 SSE 更新过则保留 SSE 的值（HTTP 晚到的显式值也不盖它）。
        if touchedDuringRequest && sameState { out.stopDisposition = old.stopDisposition ?? new.stopDisposition }
        return settled(out)
    }

    /// 规则 C：在途状态以最终命令为准。已知命令：在途（started、unknown）取其状态，其余（排队、终态）不在途；
    /// 只有无命令的 key 才保留本地或快照的值。
    public static func deriveInflight(commands: [String: ApiCommand], local: [String: String], snapshot: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        let keys = Set(commands.keys).union(local.keys).union(snapshot.keys)
        for key in keys {
            guard let c = commands[key] else {
                if let v = local[key] ?? snapshot[key] { out[key] = v }
                continue
            }
            if let v = inflight(after: c, current: nil) { out[key] = v }
        }
        return out
    }

    /// 命令更新后的在途表项（规则 C 的单条形式）：在途（started、unknown）为命令状态，其余为空。
    public static func inflight(after c: ApiCommand, current: String?) -> String? {
        isInFlight(state: c.state) ? c.state : nil
    }

    /// 线上状态是否在途（started 与 unknown 仍占用目标；排队与终态不在途）。
    public static func isInFlight(state: String) -> Bool {
        state == CommandState.started.rawValue || state == CommandState.unknown.rawValue
    }

    /// 命令出现后物化尚未消费的 progress 帧：按序逐帧等同于有序 SSE 更新（规则 A、B），在途随之派生（规则 C）。
    public static func materialized(_ c: ApiCommand, pending frames: [ProgressPayload]) -> ApiCommand {
        frames.reduce(c) { progressed($0, state: $1.state, reason: $1.reason, queue: $1.queue, stop: $1.stop) }
    }

    public static func materialized(_ c: ApiCommand, pending p: ProgressPayload?) -> ApiCommand {
        materialized(c, pending: p.map { [$0] } ?? [])
    }

    /// progress 帧：有 reason 就记下；终态不因缺 reason 清掉已有原因。
    /// 队列组：写模式帧整组替换（null 即清除）；旧帧不带组则保留原组；两者都按新状态去掉不再适用的字段。
    public static func progressed(_ c: ApiCommand, state: String, reason: String?, queue: QueueMeta? = nil, stop: StopDisposition? = nil) -> ApiCommand {
        var out = c
        if c.reason == "queue_expired" || c.reason == "queue_expired_uncertain" { return c }
        guard progressAccepted(c, state: state) else { return c }
        out.state = state
        out.reason = reason ?? c.reason
        out.queue = queue ?? c.queue
        out.stopDisposition = stop ?? c.stopDisposition
        return settled(out)
    }
}
