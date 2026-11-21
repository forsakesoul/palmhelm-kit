import Foundation

/// 目标账本历史的一条（#97，h56 契约）。`id` 是稳定展示标识：outbox 为 `outbox:<uuid>`，inbox 为 `inbox:<event_key>`；
/// 游标与 rowid 不出现在条目里。`t` 是创建时间（毫秒）：outbox 的 t 或 inbox 的 createdT。
public struct TargetHistoryRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: String
    public var text: String
    public var t: Int?
    public var kind: String?
    public var replyTo: String?
    public var targetId: String?
    public var state: String?
    /// source == inbox 且对象带完整指令字段时保存同一 ApiCommand（阶段、暂停分类、期限同义）；outbox / 旧缺字段行为 nil，不伪造 eventKey。
    public var command: ApiCommand?

    private enum CodingKeys: String, CodingKey { case id, source, text, t, createdT, kind, replyTo, targetId, state }

    public init(id: String, source: String, text: String, t: Int? = nil, kind: String? = nil, replyTo: String? = nil, targetId: String? = nil, state: String? = nil, command: ApiCommand? = nil) {
        self.id = id; self.source = source; self.text = text; self.t = t; self.kind = kind; self.replyTo = replyTo; self.targetId = targetId; self.state = state; self.command = command
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        text = try c.decode(String.self, forKey: .text)
        t = try c.decodeIfPresent(Int.self, forKey: .t) ?? c.decodeIfPresent(Int.self, forKey: .createdT)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        targetId = try c.decodeIfPresent(String.self, forKey: .targetId)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        // 部分 / 旧行缺指令必需字段时不失败：沿原正文与时间。
        command = source == "inbox" ? try? ApiCommand(from: decoder) : nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source, forKey: .source)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(t, forKey: .t)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(replyTo, forKey: .replyTo)
        try c.encodeIfPresent(targetId, forKey: .targetId)
        try c.encodeIfPresent(state, forKey: .state)
        // 指令字段与行字段同层（与线上形状一致）；text / state / targetId 行内已写，值相同。
        try command?.encode(to: encoder)
    }
}

/// `GET /v1/targets/{id}/history` 的一页。`nextBefore` 不透明：只能原样回传；`hasMore == false` 才是结束（空页可能仍有更多）。
/// `partial` 且 `items` 为空 = 服务端扫描有进展但没凑满，应以 `nextBefore` 继续，而不是当作“没有历史”。
public struct TargetHistoryPage: Codable, Sendable, Equatable {
    public var items: [TargetHistoryRow]
    public var nextBefore: String?
    public var hasMore: Bool
    public var partial: Bool
    public init(items: [TargetHistoryRow], nextBefore: String?, hasMore: Bool, partial: Bool) {
        self.items = items; self.nextBefore = nextBefore; self.hasMore = hasMore; self.partial = partial
    }
}

/// 一个目标的历史请求槽（#110）：首载、续页、刷新共用，物理串行——旧调用退出（释放）之前，新请求排队等待。
/// 刷新请求用序号合并：排队期间的多次激活，只要有一次刷新在它们登记之后开始并成功完成，其余即视为已满足（最多一次尾随）；
/// 排队者被取消则不运行，由下一个排队者顶上，所以取消旧路由不会吞掉新路由的刷新。不可观察（视图不读它）。
@MainActor
public final class HistoryRequestSlot: Equatable {
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var requestSeq = 0
    private var doneStart = 0

    nonisolated public init() {}

    nonisolated public static func == (a: HistoryRequestSlot, b: HistoryRequestSlot) -> Bool { a === b }

    /// 取得槽：空闲立即返回，否则按到达顺序等待上一个持有者 `release`。
    public func acquire() async {
        if !running { running = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty { running = false } else { waiters.removeFirst().resume() }
    }

    /// 登记一次刷新请求，返回其序号。
    public func registerRefresh() -> Int { requestSeq += 1; return requestSeq }

    /// 已有一次刷新在该请求登记之后开始并成功完成：本请求无需再跑。
    public func refreshSatisfied(_ seq: Int) -> Bool { seq <= doneStart }

    /// 开始跑一次刷新：返回此刻已登记的序号上限，成功完成后交给 `refreshSucceeded`。
    public func refreshStarted() -> Int { requestSeq }

    public func refreshSucceeded(startedAt: Int) { doneStart = max(doneStart, startedAt) }
}

/// 归档线程的历史分页状态（纯状态机，两端共用）：从最新一页起向更旧翻页，按 id 去重，按时间（再按 id）升序保存。
public struct TargetHistoryPaging: Sendable, Equatable {
    /// 连续空的部分页超过此次数就停止自动继续，交给用户再次操作。
    public static let maxEmptyPartials = 5

    public private(set) var items: [TargetHistoryRow] = []
    public private(set) var nextBefore: String?
    public private(set) var hasMore = true
    public private(set) var loading = false
    public private(set) var emptyPartials = 0
    public private(set) var failed = false
    /// 正在做“刷新已加载范围”（#110）：不改 items 与底部游标；与首载 / 续页同属一个请求槽（见 `slot`）。
    public private(set) var refreshing = false
    /// 已成功应用过至少一页（首载完成）。首载失败时仍为假，可以原样重试。
    public private(set) var loaded = false
    /// 本目标的请求槽：随分页状态一起创建与清除（断开 / 删除后旧调用持有旧槽，按代次与范围守卫零写退出）。
    public let slot = HistoryRequestSlot()

    public init() {}

    /// 已到最旧：首载已完成、不再有更多、且不在加载中。
    public var exhausted: Bool { loaded && !hasMore && !loading }

    /// 应当自动继续请求下一页：空的部分页、仍有更多、未超过上限。
    public var shouldContinue: Bool { loaded && hasMore && nextBefore != nil && emptyPartials > 0 && emptyPartials <= Self.maxEmptyPartials && !loading }

    /// 首载（不带游标）：尚未成功加载过，且不在加载中。失败后仍可用于重试。
    public var canLoadInitial: Bool { !loaded && !loading }

    /// 续页（带不透明游标）：首载已完成、仍有更多、不在加载中。
    public var canLoadMore: Bool { loaded && hasMore && nextBefore != nil && !loading }

    public mutating func beginLoad() { loading = true; failed = false }

    public mutating func failLoad() { loading = false; failed = true }

    /// 本人的首载 / 续页被取消或失效：只清在途标志，不写失败也不动数据。
    public mutating func abandonLoad() { loading = false }

    public mutating func beginRefresh() { refreshing = true }

    /// 结束刷新。`complete` 为假（失败、游标异常、空 partial 超限）保留失败标记，可由再次激活重试；取消不算失败（调用方传 true）。
    public mutating func endRefresh(complete: Bool) {
        refreshing = false
        failed = !complete
    }

    /// 同 id 行的元数据合并（首载 / 续页 / 刷新共用这一份）：只更新 `state` 与 `command`，成对替换；
    /// 来源、正文、时间、目标、种类、回复关系任一冲突，或新行缺指令而旧行已有，则整条跳过。排序与正文保持原样。
    private mutating func absorbKnown(_ row: TargetHistoryRow, at i: Int) {
        let old = items[i]
        guard old.source == row.source, old.text == row.text, old.t == row.t, old.targetId == row.targetId, old.kind == row.kind, old.replyTo == row.replyTo,
              row.command != nil || old.command == nil else { return }
        if old.state != row.state || old.command != row.command { items[i].state = row.state; items[i].command = row.command }
    }

    private mutating func sortItems() {
        items.sort { a, b in
            let ta = a.t ?? 0, tb = b.t ?? 0
            return ta != tb ? ta < tb : a.id < b.id
        }
    }

    /// 刷新合并一页（#110）：已有 id 按 `absorbKnown` 更新；新 id 只在 `anchorID` 所在页的锚及其后（**服务端页序为时间正序，旧→新**）接纳，
    /// 锚之前更旧的新 id 不加入，保证底部游标之后没有跳读缺口。无锚页整页合并。`nextBefore` / `hasMore` / `emptyPartials` / `loaded` 不变。返回本页是否含锚。
    @discardableResult
    public mutating func mergeRefresh(_ page: TargetHistoryPage, anchorID: String?) -> Bool {
        let anchorAt = anchorID.flatMap { a in page.items.firstIndex { $0.id == a } }
        let newFrom = anchorAt ?? 0
        var index: [String: Int] = [:]
        for (i, r) in items.enumerated() { index[r.id] = i }
        var added = false
        for (n, row) in page.items.enumerated() {
            if let i = index[row.id] {
                absorbKnown(row, at: i)
            } else if n >= newFrom {
                items.append(row); index[row.id] = items.count - 1; added = true
            }
        }
        if added { sortItems() }
        return anchorAt != nil
    }

    /// 应用一页：`older` 为真时更旧的内容接在前面；按 id 去重，重叠行的状态按 `absorbKnown` 更新；结果按 (t, id) 升序。
    public mutating func apply(_ page: TargetHistoryPage, older: Bool) {
        loading = false
        failed = false
        loaded = true
        if page.items.isEmpty && page.partial && page.hasMore { emptyPartials += 1 } else { emptyPartials = 0 }
        var index: [String: Int] = [:]
        for (i, r) in items.enumerated() { index[r.id] = i }
        var fresh: [TargetHistoryRow] = []
        for row in page.items {
            if let i = index[row.id] { absorbKnown(row, at: i) } else { fresh.append(row) }
        }
        items = older ? fresh + items : items + fresh
        sortItems()
        nextBefore = page.nextBefore
        hasMore = page.hasMore && page.nextBefore != nil
    }
}

/// 一次“刷新已加载范围”的遍历状态（#110）：从最新页起按服务端 nextBefore 向旧读，直到页内含截止锚或服务端 hasMore 为假。
/// 不解析游标、不按时间猜停止位置；游标与本次请求相同或重复出现（服务端异常循环）、连续空 partial 超限均停止并报未完成。
public struct TargetHistoryRefresh: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case more(before: String)
        case complete
        case incomplete
    }

    public let anchorID: String
    private var seen: Set<String> = []
    private var emptyPartials = 0

    public init(anchorID: String) { self.anchorID = anchorID }

    /// 应用一页并给出下一步；`requestedBefore` 是本页请求所带的游标（首页为 nil）。
    public mutating func accept(_ page: TargetHistoryPage, requestedBefore: String?, into paging: inout TargetHistoryPaging) -> Outcome {
        if let b = requestedBefore { seen.insert(b) }
        if paging.mergeRefresh(page, anchorID: anchorID) { return .complete }
        guard page.hasMore else { return .complete }
        guard let next = page.nextBefore, !next.isEmpty, !seen.contains(next) else { return .incomplete }
        if page.items.isEmpty && page.partial {
            emptyPartials += 1
            if emptyPartials > TargetHistoryPaging.maxEmptyPartials { return .incomplete }
        } else {
            emptyPartials = 0
        }
        return .more(before: next)
    }
}
