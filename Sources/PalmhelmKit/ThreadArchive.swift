import Foundation

// 历史会话整理（#97）：每台设备本地记录，不跨设备同步、不改 Bridge 账本。归档与删除只改本机列表展示与缓存。
// 7 天语义：自首次“完整有效快照”确认目标不可用起计 7 天，且当前仍有有效缺席证据才归档。
// 时间只比较 Bridge 给出的观察时刻（同一台 Bridge 的时钟），不比较手机与 Mac 的墙钟。

/// Bridge 的目标观察证据（`/v1/state` 与 SSE targets 帧的 `observation`）：
/// `t` 为该次成功快照的 Bridge 时刻；`complete` 为列表无跳过行；`fresh` 为服务端按其新鲜度规则判定的结论（客户端不自行比较时钟）。
/// 缺少 `fresh` 或 `fresh` 为假（快照已过期）时不能据此归档；旧 Bridge 没有该字段（整个 observation 为 nil）同样不归档。
public struct BridgeObservation: Codable, Sendable, Equatable {
    public var t: Int
    public var complete: Bool
    public var fresh: Bool?
    public init(t: Int, complete: Bool, fresh: Bool? = true) { self.t = t; self.complete = complete; self.fresh = fresh }
}

public enum ArchiveReason: String, Codable, Sendable, Equatable {
    case auto
    case manual
}

/// 一个线程在本设备上的整理记录。键为 `bridgeId|targetId`；title/lastActivity 只用于离开主列表后仍能列出它。
public struct ArchiveRecord: Codable, Sendable, Equatable {
    /// 首次完整确认不可用时的 Bridge 观察时刻；有效缺席证据中断即清空。
    public var absentSince: Int?
    /// 最近一次推进证据的 Bridge 观察时刻（单调；回拨时重新建立候选）。
    public var lastObserved: Int?
    public var archived: ArchiveReason?
    /// 删除墓碑：抑制旧历史重放重新出现在列表；在线正证据或新待处理工作出现时清除。
    public var deleted: Bool
    public var title: String?
    public var lastActivity: Int?
    public init(absentSince: Int? = nil, lastObserved: Int? = nil, archived: ArchiveReason? = nil, deleted: Bool = false, title: String? = nil, lastActivity: Int? = nil) {
        self.absentSince = absentSince; self.lastObserved = lastObserved; self.archived = archived
        self.deleted = deleted; self.title = title; self.lastActivity = lastActivity
    }
}

/// 归档保护的工作事实（与“正在工作”动画分开：动画只看在线且在列表中的排队/处理中，这里还要保留未知、待同步、未确认发送与草稿）。
/// 调用方在 state 快照与 commands/approvals 全部合并之后再汇总这些事实。
public struct ArchiveWorkFacts: Sendable, Equatable {
    /// 该目标下指令的状态（ApiCommand.state 原文）。
    public var commandStates: [String]
    public var pendingApprovals: Int
    /// 本机发出、尚未确认结果的消息数。
    public var unconfirmedSends: Int
    /// 待同步（本机有、Bridge 尚未确认）的变更数。
    public var pendingSync: Int
    public var hasDraft: Bool
    public init(commandStates: [String] = [], pendingApprovals: Int = 0, unconfirmedSends: Int = 0, pendingSync: Int = 0, hasDraft: Bool = false) {
        self.commandStates = commandStates; self.pendingApprovals = pendingApprovals; self.unconfirmedSends = unconfirmedSends
        self.pendingSync = pendingSync; self.hasDraft = hasDraft
    }

    /// 任何仍需保留可见的工作。
    public var pending: Bool {
        pendingApprovals > 0 || unconfirmedSends > 0 || pendingSync > 0 || hasDraft || commandStates.contains(where: ArchiveWorkFacts.unfinished)
    }

    /// 本机发出、结果尚未确定、且还没有对应指令的消息是否仍需保护（F1）。这类记录只在本机的发送列表里，指令与在途事实都看不到。
    /// 发送中与结果未知保护；已明确终态（已完成、失败、撤回、拒绝等）不保护。已有指令的记录由 commandStates 覆盖，这里不重复计数。
    public static func localSendUnresolved(_ phase: OutgoingPhase, hasCommand: Bool) -> Bool {
        !hasCommand && [OutgoingPhase.sending, .unknown, .nativePending].contains(phase)
    }

    /// 非终态的指令：排队、处理中、暂停、结果未知（终态 finished / rejected 不保护）。
    public static func unfinished(_ state: String) -> Bool {
        switch state {
        case "queued", "started", "paused", "unknown": true
        default: false
        }
    }
}

/// 一个目标在某次观察中的事实（由调用方从 state 或帧中取出）。
public struct ArchiveEvidence: Sendable, Equatable {
    /// 三态：true = 完整列表中在线；false = 明确离线（列表中标为离线，或完整观察中已不在列表）；nil = 未知（无登记事实、观察不完整或缺失）。
    /// 归档与删除只接受明确的 false；nil 不得当作离线（R4）。
    public var online: Bool?
    /// 有待答、在途、未确认发送或草稿等需要保留可见的工作。
    public var pendingWork: Bool
    /// 当前路由目标、正在查看或正在编辑的线程：不归档。
    public var protected: Bool
    public init(online: Bool?, pendingWork: Bool = false, protected: Bool = false) {
        self.online = online; self.pendingWork = pendingWork; self.protected = protected
    }
    public init(online: Bool?, facts: ArchiveWorkFacts, protected: Bool = false) {
        self.init(online: online, pendingWork: facts.pending, protected: protected)
    }
}

public enum ArchiveRules {
    public static let sevenDaysMs = 7 * 24 * 60 * 60 * 1000
    /// 早于已记录时刻的观察：不超过此差距视为陈旧帧（忽略），超过则视为回拨。
    public static let staleToleranceMs = 24 * 60 * 60 * 1000

    /// 用一次新观察推进整理记录。
    /// - 正证据（明确在线或有待处理工作）：不受观察门禁限制，立即清候选、恢复可见、清墓碑；同时间戳的新工作也照此处理。
    /// - 缺席计时只认完整、新鲜、且明确离线（ev.online == false）的观察；observation 为 nil（旧 Bridge）、complete=false、fresh 不为真、
    ///   online 为 nil（未知）时，不推进缺席证据，原样返回。
    /// - 观察时刻不晚于 lastObserved（重复或较早到达的陈旧帧）：不推进缺席证据，原样返回。
    /// - 时刻明显回拨（早于已记录时刻超过一天）：视为未知，清空候选并从新时刻重新计时（不把负间隔当作 7 天）。
    /// - 完整缺席：首次记录候选时刻；满 7 天、且仍无待处理工作、未受保护时自动归档。
    public static func observe(_ rec: ArchiveRecord, _ obs: BridgeObservation?, _ ev: ArchiveEvidence) -> ArchiveRecord {
        if ev.online == true || ev.pendingWork {
            guard rec.absentSince != nil || rec.archived != nil || rec.deleted else { return rec }
            var r = rec
            r.absentSince = nil
            r.archived = nil
            r.deleted = false
            return r
        }
        guard let obs, obs.complete, obs.fresh == true, ev.online == false else { return rec }
        var r = rec
        if let last = r.lastObserved {
            if obs.t == last { return rec }
            if obs.t < last {
                // 较早到达的陈旧帧（差距在一天之内）：忽略，不推进证据。
                // 差距超过一天：视为时钟回拨或 Bridge 重置，清空候选并从新时刻重新计时。
                guard last - obs.t > staleToleranceMs else { return rec }
                r.absentSince = nil
                r.lastObserved = obs.t
                return r
            }
        }
        r.lastObserved = obs.t
        if r.absentSince == nil { r.absentSince = obs.t }
        if r.archived == nil, let since = r.absentSince, obs.t - since >= sevenDaysMs, !ev.protected, !ev.pendingWork {
            r.archived = .auto
        }
        return r
    }

    /// 手动归档：只对明确离线、没有待处理工作、未受保护的条目可用（在线条目不能手动归档；未知状态不得当作离线）。
    public static func archiveManually(_ rec: ArchiveRecord, _ ev: ArchiveEvidence) -> ArchiveRecord? {
        guard ev.online == false, !ev.pendingWork, !ev.protected else { return nil }
        var r = rec
        r.archived = .manual
        return r
    }

    /// 手动恢复：取消归档，并从现在起重新计 7 天候选（不会下一帧再次自动归档）。
    public static func restore(_ rec: ArchiveRecord) -> ArchiveRecord {
        var r = rec
        r.archived = nil
        r.absentSince = nil
        return r
    }

    /// 删除（只清本机展示）：写入墓碑。调用方在保存成功后才隐藏条目（保存失败保留原列表）。
    public static func delete(_ rec: ArchiveRecord, _ ev: ArchiveEvidence) -> ArchiveRecord? {
        guard ev.online == false, !ev.pendingWork, !ev.protected else { return nil }
        var r = rec
        r.deleted = true
        r.archived = nil
        return r
    }

    /// 列表可见性：墓碑（且没有新的在线或待处理证据）与任何归档都不出现在主列表。
    public static func isHiddenFromMain(_ rec: ArchiveRecord?) -> Bool {
        guard let rec else { return false }
        return rec.archived != nil || rec.deleted
    }
}

/// 整理记录的本机存储（每台设备一份，UserDefaults，只存目录元数据与状态，不存正文）。
public final class ThreadArchiveStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()
    private var cache: [String: ArchiveRecord]

    public init(defaults: UserDefaults = .standard, storageKey: String = "palmhelm.threadArchive.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        cache = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: ArchiveRecord].self, from: $0) } ?? [:]
    }

    public static func key(bridgeId: String?, targetId: String) -> String { "\(bridgeId ?? "")|\(targetId)" }

    public func record(_ key: String) -> ArchiveRecord? { lock.withLock { cache[key] } }
    public var all: [String: ArchiveRecord] { lock.withLock { cache } }

    /// 在首次看到线程时登记目录（标题与最近活动），之后只在变化时写入。
    public func touch(_ key: String, title: String, lastActivity: Int) {
        update(key) { r in
            if r.title == nil || r.title != title { r.title = title }
            if r.lastActivity == nil || (r.lastActivity ?? 0) < lastActivity { r.lastActivity = lastActivity }
        }
    }

    /// 应用一次观察；只有记录真的改变时才写入。
    public func observe(_ key: String, _ obs: BridgeObservation?, _ ev: ArchiveEvidence) {
        update(key) { $0 = ArchiveRules.observe($0, obs, ev) }
    }

    /// 批量更新里的一条：对 key 应用一次观察，或登记目录（标题与最近活动）。按给定顺序依次应用。
    public enum Step: Sendable {
        case observe(key: String, observation: BridgeObservation?, evidence: ArchiveEvidence)
        case touch(key: String, title: String, lastActivity: Int, onlyIfUntitled: Bool = false)
    }
    public struct BatchResult: Sendable, Equatable {
        /// 展示 / 可见性 / 目录信息变了（archived、deleted、title、lastActivity、条目增删）：列表才需要重算。
        public var displayChanged: Bool
        /// 有任何记录变化（含 lastObserved / absentSince 这类只属于证据的字段）。
        public var changed: Bool
        /// 变化已写入存储；没有变化时为 true。
        public var persisted: Bool
    }

    /// 一次观察的整体更新：锁内在同一份记录上依次应用现有规则（ArchiveRules.observe / touch），整轮最多编码并保存一次。
    /// 证据字段仍完整比较并保存；展示是否变化单独报告，调用方据此决定是否让列表重算。
    @discardableResult
    public func apply(_ steps: [Step]) -> BatchResult {
        lock.withLock {
            var next = cache
            for step in steps {
                switch step {
                case let .observe(key, obs, ev):
                    var r = next[key] ?? ArchiveRecord()
                    let before = r
                    r = ArchiveRules.observe(r, obs, ev)
                    if r != before { next[key] = r }
                case let .touch(key, title, lastActivity, onlyIfUntitled):
                    var r = next[key] ?? ArchiveRecord()
                    if onlyIfUntitled, r.title != nil { continue }
                    let before = r
                    if r.title == nil || r.title != title { r.title = title }
                    if r.lastActivity == nil || (r.lastActivity ?? 0) < lastActivity { r.lastActivity = lastActivity }
                    if r != before { next[key] = r }
                }
            }
            guard next != cache else { return BatchResult(displayChanged: false, changed: false, persisted: true) }
            let displayChanged = Set(next.keys).symmetricDifference(cache.keys).isEmpty == false
                || next.contains { k, v in
                    guard let old = cache[k] else { return true }
                    return old.archived != v.archived || old.deleted != v.deleted || old.title != v.title || old.lastActivity != v.lastActivity
                }
            cache = next
            return BatchResult(displayChanged: displayChanged, changed: true, persisted: persist())
        }
    }

    /// 写入一条记录的变换（返回 false 时不写入）。保存失败时返回 false，调用方保留原列表。
    @discardableResult
    public func transform(_ key: String, _ change: (ArchiveRecord) -> ArchiveRecord?) -> Bool {
        lock.withLock {
            let old = cache[key] ?? ArchiveRecord()
            guard let new = change(old) else { return false }
            cache[key] = new
            return persist()
        }
    }

    private func update(_ key: String, _ change: (inout ArchiveRecord) -> Void) {
        lock.withLock {
            var r = cache[key] ?? ArchiveRecord()
            let before = r
            change(&r)
            guard r != before else { return }
            cache[key] = r
            _ = persist()
        }
    }

    private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(cache) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }
}
