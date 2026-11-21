import Foundation

/// 「过期状态不冒充当前」的纯规则（Mac 与 iOS 共用）：当前活动 vs 历史 / 结果未知、提醒的当前性与已读账本。
/// 只做判定，不碰网络与存储；调用方把当前的连接 / 快照证据传进来。

// MARK: - D2 当前活动

public enum CurrentActivity {
    public enum Phase: Equatable, Sendable {
        /// 已知的 started，且目标在最近一次成功的完整目标快照里。
        case working
        /// 已知的 queued，同上。
        case queued
        /// 状态已知但离线 / 未就绪 / 还没有目标快照：不能说是当前，也不能说已结束。
        case pendingSync
        /// Bridge 明说结果未知：不是成功，不播工作动画，不计入待处理。
        case resultUnknown
        /// 无法识别的状态值（新 Bridge 的新状态）：同样不当成功。
        case unsupported
        /// 已终结，或目标已不在快照里：只属于历史。
        case history
    }

    /// linked：会话已连通且完成过同步；targets：最近一次成功的完整目标快照的编号集合（nil = 还没有）。
    public static func phase(state: String, targetId: String?, linked: Bool, targets: Set<String>?) -> Phase {
        guard let known = CommandState(rawValue: state) else { return .unsupported }
        switch known {
        case .unknown: return .resultUnknown
        case .finished, .paused, .rejected: return .history
        case .queued, .started:
            guard linked, let targets else { return .pendingSync }
            guard let targetId, targets.contains(targetId) else { return .history }
            return known == .started ? .working : .queued
        }
    }

    public static func phase(of c: ApiCommand, linked: Bool, targets: Set<String>?) -> Phase {
        phase(state: c.state, targetId: c.targetId, linked: linked, targets: targets)
    }

    /// 只有这两种可以显示成「当前工作」（动画、计数、刘海 / 菜单计数）。
    public static func isCurrent(_ p: Phase) -> Bool { p == .working || p == .queued }

    /// 非当前、但仍要诚实说明的状态文案；working / queued / history 为 nil。
    public static func note(_ p: Phase) -> String? {
        switch p {
        case .pendingSync: KitL10n.string("状态待同步")
        case .resultUnknown: KitL10n.string("结果未知")
        case .unsupported: KitL10n.string("暂不支持此状态")
        case .working, .queued, .history: nil
        }
    }

    /// 指令行上的状态文案：当前态沿用原标签；待同步 / 未知 / 不识别用诚实文案；目标已不在快照的在途态不再说「处理中」。
    public static func displayLabel(of c: ApiCommand, linked: Bool, targets: Set<String>?) -> String {
        if c.reason == "native_delivered" { return OutgoingStatus.label(.nativeDelivered) }
        if c.reason == "native_send_now_requested" { return OutgoingStatus.label(.nativeSendRequested) }
        if c.reason == "native_send_now_skipped" { return OutgoingStatus.label(.nativeSendSkipped) }
        if SendTimingRules.isNativePending(c) { return OutgoingStatus.label(.nativePending) }
        let p = phase(of: c, linked: linked, targets: targets)
        if let n = note(p) { return n }
        // 连接 / 当前性 note 与“目标已不在”的诚实分支在前；started（含缺 / 未知 phase）与暂停再统一到消息阶段文案。
        if c.state == CommandState.paused.rawValue { return SendTimingCopy.commandStatus(c) }
        if c.state == CommandState.started.rawValue {
            if p == .history { return KitL10n.string("目标已不在 · 结果未确认") }
            return SendTimingCopy.commandStatus(c)
        }
        return displayLabel(state: c.state, targetId: c.targetId, linked: linked, targets: targets)
    }
    /// 只有状态字符串（progress 事件的 inflight）时的同一套文案：自己发出的气泡也不直接显示原始状态。
    public static func displayLabel(state: String, targetId: String?, linked: Bool, targets: Set<String>?) -> String {
        let p = phase(state: state, targetId: targetId, linked: linked, targets: targets)
        if let n = note(p) { return n }
        // 只有 state 字符串时，普通暂停保守为可能已执行（旧 ProgressState 文案不得漏出“被拒绝 / 未发出”）。
        if state == CommandState.paused.rawValue { return OutgoingStatus.label(.stoppedUncertain) }
        // 目标已不在快照的在途态：可能已经执行过，不能说「未执行」——只有 Bridge 明确发出未派发收敛回执（命令随之变为 paused）才有这个说法。
        if p == .history, let k = CommandState(rawValue: state), !k.isTerminal { return KitL10n.string("目标已不在 · 结果未确认") }
        // 只有 state 时的 started 与有 phase 的指令同一中性文案（processing 只由 phase=running 产生）。
        if state == CommandState.started.rawValue { return OutgoingStatus.label(.delivered) }
        return CommandState(rawValue: state)?.label ?? KitL10n.string("暂不支持此状态")
    }

    /// 仍未终结、但不属于当前活动的指令数（结果未知 / 不识别），菜单等处单独说明，不并入待处理。
    public static func unresolved(_ commands: [ApiCommand], linked: Bool, targets: Set<String>?) -> Int {
        commands.filter { [.resultUnknown, .unsupported].contains(phase(of: $0, linked: linked, targets: targets)) }.count
    }

    public static func current(_ commands: [ApiCommand], linked: Bool, targets: Set<String>?) -> [ApiCommand] {
        commands.filter { isCurrent(phase(of: $0, linked: linked, targets: targets)) }
    }
}

// MARK: - D4 提醒的当前性

public enum ReminderStatus: Equatable, Sendable {
    /// 提醒对应的命令此刻仍是该目标上正在阻塞的那一条：允许「重置占用」，并带上要核对的 eventKey。
    case current(eventKey: String)
    /// 新 Bridge 的投影明确表示它已不再阻塞：历史提醒。
    case history
    /// 证据有缺口（旧 Bridge / 离线 / 命令列表被截断 / 提醒缺归属）：只能说「历史提醒 · 当前状态待核」。
    case unverified

    public var allowsReset: Bool { if case .current = self { true } else { false } }
    public var label: String? {
        switch self {
        case .current: nil
        case .history: KitL10n.string("历史提醒")
        case .unverified: KitL10n.string("历史提醒 · 当前状态待核")
        }
    }
}

/// 提醒页的一条候选（两端各自从本机状态映射，可见性规则只在 ReminderRules.visibleIds 里）。
/// t：有效时间（毫秒），拿不到可信时间时为 nil，不用 0 冒充。restorable：可恢复的失败（Mac）；restored：已恢复（优先隐藏）。
public struct ReminderCandidate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case blocked(ReminderStatus)
        case plain
    }
    public let id: String
    public let t: Int?
    public let kind: Kind
    public let seen: Bool
    public let restorable: Bool
    public let restored: Bool
    public init(id: String, t: Int?, kind: Kind, seen: Bool, restorable: Bool = false, restored: Bool = false) {
        self.id = id; self.t = t; self.kind = kind; self.seen = seen; self.restorable = restorable; self.restored = restored
    }
}

public enum ReminderRules {
    public static let maxAgeMs = 72 * 3_600_000

    /// 提醒页可见的 id（保持输入顺序）。规则：
    /// - 恢复成功、超过 72 小时（恰好 72 小时保留）优先隐藏，任何保留集都不豁免；
    /// - 超时提醒：current 始终显示（已读也保留，需要操作）；history 隐藏；unverified 有时间时只按已读收敛，无时间的非 current 直接隐藏；
    /// - 普通项：已读即隐藏，除非在本次打开的保留集里；可恢复失败在恢复成功前不按已读隐藏。
    /// retained 只豁免「本次标已读造成的隐藏」，不冻结正文、状态或恢复资格。
    public static func visibleIds(_ items: [ReminderCandidate], retained: Set<String>, nowMs: Int) -> [String] {
        items.filter { c in
            if c.restored { return false }
            if let t = c.t, t < nowMs - maxAgeMs { return false }
            let readHidden = c.seen && !retained.contains(c.id)
            switch c.kind {
            case .blocked(let status):
                switch status {
                case .current: return true
                case .history: return false
                case .unverified: return c.t != nil && !readHidden
                }
            case .plain:
                return c.restorable || !readHidden
            }
        }.map(\.id)
    }

    /// 超时提醒的有效时间：优先提醒本身的时间；缺失时用投影里同目标同 eventKey 的 blockedSince（仅当前有效）。
    public static func blockedSince(of item: HistoryItem, currentBlocked: [CurrentBlocked]?) -> Int? {
        guard let key = item.replyTo, let tid = item.target?.id else { return nil }
        return currentBlocked?.first(where: { $0.targetId == tid && $0.eventKey == key })?.blockedSince
    }

    /// 只有「受支持的新投影（含空数组）且证据新鲜」才算证据；旧 Bridge（nil）、离线、截断、Herdr 快照过期（evidenceFresh == false / 缺失）都是缺口，
    /// 「支持但证据过期」不能伪装成可靠的空数组。
    public static func status(of item: HistoryItem, currentBlocked: [CurrentBlocked]?, evidenceFresh: Bool?, linked: Bool, commandsTruncated: Bool) -> ReminderStatus {
        guard linked, !commandsTruncated, evidenceFresh == true, let currentBlocked, let key = item.replyTo, let tid = item.target?.id else { return .unverified }
        return currentBlocked.contains { $0.targetId == tid && $0.eventKey == key } ? .current(eventKey: key) : .history
    }

    /// 卡片上的等待时长：只在「当前」时取投影里的 blockedSince（解除阻塞后又再次阻塞，起点是新的 blockedSince）；毫秒时间戳。
    public static func waitedMinutes(of item: HistoryItem, currentBlocked: [CurrentBlocked]?, nowMs: Int) -> Int? {
        guard let key = item.replyTo, let tid = item.target?.id,
              let b = currentBlocked?.first(where: { $0.targetId == tid && $0.eventKey == key }) else { return nil }
        return max(0, (nowMs - b.blockedSince) / 60_000)
    }
}

// MARK: - D3 提醒已读账本

/// 快照式已读：只有打开提醒弹层 / 页时才把「当时看到的」标已读，之后到的仍是未读；键 = Bridge 身份 + 条目 id
/// （回执 uuid；发送失败用 `sent:<Sent UUID>`；不用 IP / 展示名 / seq）。所有展示出来的提醒（超时提醒、普通 rejected 回执、发送失败）共用这一个账本。
/// 每个 Bridge 首次出现时把已有的普通旧提醒归入历史（baseline），不当成升级后的一屏未读。
/// 容量按 Bridge 各自计：每个 Bridge 只淘汰自己最旧的已读记录（上限远大于单个 Bridge 的历史保留窗口 500 条），不会被别的 Bridge 挤掉，回访不会复活为未读；
/// 未读与恢复项从不进入「已读」，所以不受任何裁剪影响。
public struct ReminderLedger: Codable, Equatable, Sendable {
    public private(set) var seenByBridge: [String: [String]] = [:]
    public private(set) var baselined: [String] = []
    public static let perBridgeLimit = 1000
    public init() {}

    enum CodingKeys: String, CodingKey { case seenByBridge, baselined, seen }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baselined = try c.decodeIfPresent([String].self, forKey: .baselined) ?? []
        if let m = try c.decodeIfPresent([String: [String]].self, forKey: .seenByBridge) { seenByBridge = m }
        // 旧格式：全局 "bridge~id" 列表
        if let legacy = try c.decodeIfPresent([String].self, forKey: .seen) {
            for k in legacy {
                guard let i = k.firstIndex(of: "~") else { continue }
                seenByBridge[String(k[..<i]), default: []].append(String(k[k.index(after: i)...]))
            }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seenByBridge, forKey: .seenByBridge)
        try c.encode(baselined, forKey: .baselined)
    }

    public static func sentId(_ uuid: UUID) -> String { "sent:\(uuid.uuidString)" }

    /// 账本键的身份：优先 Bridge 自报的 id；旧 Bridge 没有 id 时退回稳定的本机配对账号键（iOS：账号 id；Mac：该 Bridge 给本机配对签发的设备 id），
    /// 不用 IP 或展示名（会变、会重名）。两者都没有 → 不持久化（persistent == false，只在内存里按 ephemeral 键用，退出即忘，不会与别的 Bridge 共用）。
    public static func identity(bridgeId: String?, accountKey: String?) -> (id: String, persistent: Bool) {
        if let b = bridgeId, !b.isEmpty { return (b, true) }
        if let a = accountKey, !a.isEmpty { return ("acct:" + a, true) }
        return ("ephemeral", false)
    }

    // 按条目 id
    public func isSeen(bridgeId: String, id: String) -> Bool { seenByBridge[bridgeId]?.contains(id) == true }
    public func unread(bridgeId: String, ids: [String]) -> [String] { ids.filter { !isSeen(bridgeId: bridgeId, id: $0) } }
    public mutating func baselineIfNeeded(bridgeId: String, ids: [String], keepUnread: (String) -> Bool = { _ in false }, retained: Set<String> = []) {
        guard !baselined.contains(bridgeId) else { return }
        baselined.append(bridgeId)
        mark(bridgeId, ids.filter { !keepUnread($0) }, retained: retained)
    }
    /// retained：仍然保留着的提醒 id（历史窗口里的回执 + 本机 Sent 里的失败项，不论是否还在提醒页里可见）。
    /// 容量满时只淘汰「已不在保留集里」的最旧已读；仍保留着的已读标记受保护（否则 Sent 一直追加时，旧的已读失败项会因为后来的已读而重新变成未读）。
    public mutating func markSeen(bridgeId: String, ids: [String], retained: Set<String> = []) { mark(bridgeId, ids, retained: retained) }
    private mutating func mark(_ bridgeId: String, _ ids: [String], retained: Set<String> = []) {
        var list = seenByBridge[bridgeId] ?? []
        let have = Set(list)
        for id in ids where !have.contains(id) { list.append(id) }
        if list.count > Self.perBridgeLimit {
            var over = list.count - Self.perBridgeLimit
            list = list.filter { id in
                if over > 0, !retained.contains(id) { over -= 1; return false }
                return true
            }
        }
        seenByBridge[bridgeId] = list
    }

    // HistoryItem 便捷形式
    public func isSeen(bridgeId: String, _ item: HistoryItem) -> Bool { isSeen(bridgeId: bridgeId, id: item.uuid) }
    public func unread(bridgeId: String, _ items: [HistoryItem]) -> [HistoryItem] { items.filter { !isSeen(bridgeId: bridgeId, $0) } }
    public mutating func baselineIfNeeded(bridgeId: String, items: [HistoryItem], keepUnread: (HistoryItem) -> Bool = { _ in false }, retained: Set<String> = []) {
        guard !baselined.contains(bridgeId) else { return }
        baselined.append(bridgeId)
        mark(bridgeId, items.filter { !keepUnread($0) }.map(\.uuid), retained: retained)
    }
    public mutating func markSeen(bridgeId: String, _ items: [HistoryItem], retained: Set<String> = []) { mark(bridgeId, items.map(\.uuid), retained: retained) }

}

extension ReminderLedger {
    private static let defaultsKey = "palmhelm.reminderLedger.v1"
    public static func load(from defaults: UserDefaults) -> ReminderLedger {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(ReminderLedger.self, from: $0) } ?? ReminderLedger()
    }
    public func save(to defaults: UserDefaults) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.defaultsKey) }
    }
}
