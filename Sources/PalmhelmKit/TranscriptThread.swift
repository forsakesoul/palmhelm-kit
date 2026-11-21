import Foundation

/// 加载更早记录时的保位请求（显式 opt-in）：调用方捕获的阅读锚点及最后可见行；锚点可为 nil（没有有效几何）。
public struct KeepReading: Equatable, Sendable {
    public var anchorId: String?
    public var lastVisibleId: String?
    public init(anchorId: String?, lastVisibleId: String?) { self.anchorId = anchorId; self.lastVisibleId = lastVisibleId }
}

/// 更早页并入的结果：新增行数，以及渲染窗口的起点是否向更早方向移动（只有此时布局才会变化，需要位置补偿）。
public struct OlderMerge: Equatable, Sendable {
    public var added = 0
    public var windowMovedUp = false
    public init(added: Int = 0, windowMovedUp: Bool = false) { self.added = added; self.windowMovedUp = windowMovedUp }
}

/// 一个目标的会话记录线程状态（两端共用的纯状态机）：最新页 / 更早页如何并入、何时整体重来、请求如何协调。
/// 视图只渲染 `items`；网络由各端会话层负责。
public struct TranscriptThread: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case loading
        case ok
        /// Bridge 读不到这个目标的会话记录：客户端回退到自己的回执记录。
        case unavailable
        case failed(String)
    }

    public var status: Status = .loading
    /// 最近一次不可用页的原因（见 TranscriptPage.reason）；可读时为 nil。
    public private(set) var unavailableReason: String?
    public var sessionEpoch: String?
    public var revision: String?
    public var items: [TranscriptItem] = [] {
        // 任何并入 / 替换 / 截断都经这里：先记下出现过的回执，之后窗口或整页替换丢掉它也不影响（只增不减）。
        didSet { linkedEventKeys.formUnion(items.compactMap { $0.receipt?.eventKey }) }
    }
    /// 已关联到本机发送的回执 eventKey：同一原生代次内单调（一旦在已加载的项里出现过就不再复活）；原生代次切换时按新页重算（见 resetLinkedOnEpochChange）。
    public private(set) var linkedEventKeys: Set<String> = []
    /// 关联账本所属的原生代次（最近一次已知的非空代次），与展示用的 sessionEpoch 分开：暂不可读时 sessionEpoch 为 nil，但账本仍记得它。
    private var linkedEpoch: String?
    public var nextBefore: String?
    public var hasMore = false
    public var loadingOlder = false
    /// 最新页的 ETag（与 latestPage 同一次采纳）：只有这一页被接纳后才有；失效、清空、定位视图时清除（#88 S4 修复）。
    public private(set) var latestETag: String?
    /// latestETag 对应的后补声明形状（见 TranscriptReceiptRequest）：声明集合改变、清空时旧 validator 不复用。
    public private(set) var latestShape: TranscriptReceiptRequest?
    /// 临时失败（网络、可恢复的不可用）时保留已核验内容并置位：界面显示「显示的是上次内容」与重试。
    public private(set) var stale = false
    /// 内存超限时裁掉了渲染窗口之后的较新内容：不再自动应用最新页，只能由用户「回到最新」恢复（resumeFromLatest）。
    public private(set) var hasNewer = false
    /// 已加载的更早页（按加载顺序，最后一段是最旧的）：内存超限时整段淘汰，回看时用它的游标重取。
    private struct OlderChunk: Equatable { let ids: [String]; let cursor: String }
    private var olderChunks: [OlderChunk] = []
    /// 分页快照代次：整体替换 / 失效时递增；更早页只有仍属于同一快照才并入。
    public private(set) var snapshot = 0
    /// 快照已失效（reset 事件、410）：下一次最新页整体替换；期间保留旧内容显示，不冒充“已到开头”。
    public private(set) var needsReplace = false
    /// 定位视图（从搜索命中打开）：`items` 是命中所在的一页而非最新页。非 nil 时最新页不并入，新消息不自动跳到底；直到 invalidate（回到最新）。
    public private(set) var pinnedHit: String?
    /// 最新页在途（每线程单飞）；在途期间收到的通知记为 dirty，完成后再补拉一次。
    public var latestInFlight = false
    public var dirty = false
    /// 本连接代次内真实在途的 HTTP 请求数（最新页 + 更早页）：Bridge 每设备每目标最多 2 条；UI 的 busy 归还不等于请求结束。
    /// abandonRequests 只清本地计数，不取消已发出的 GET；只在 forget / 断开（换代次）时调用，普通 SSE 重连不走这里（A1-125 R1）。
    public var activeRequests = 0
    public static let maxActiveRequests = 2
    public var canStartRequest: Bool { activeRequests < Self.maxActiveRequests }

    /// 对话区最多渲染的行数（O1-341）：items 保留全部已加载的行，只有窗口内的行参与布局，内存与加载量无关。
    /// 40 行由测量定：每行约 2.8MB（含可选中文本），40 行约 140MB，100 行约 300MB。
    public static let renderLimit = 40
    /// 渲染窗口的末端（items 下标，不含）；nil 表示跟随最新（渲染最后 renderLimit 行）。
    public private(set) var windowEnd: Int? { didSet { windowFloor = nil } }
    /// 渲染窗口的下限（items 下标）：只用于保位的显式 opt-in，让窗口可以短于 renderLimit 而不被自动扩到更早的行。
    /// 任何其它窗口变化（windowEnd 被重新赋值）都会清掉它；追加在尾部的新行不影响它。
    public private(set) var windowFloor: Int?

    public init() {}

    /// 首屏补齐（#111）：首次采纳整页后，已加载条目不足 fillTarget 且还有更早历史时，由调用方继续取下一页（空页也算，只要游标在前进）。
    public static let fillTarget = 20
    public static let fillMaxPages = 4
    /// 补齐的进度（每次整页替换时重开）：已并入的更早页数；空页只推进游标，所以按页数而不是按条数封顶。
    private var fillOpen = false
    private var fillPages = 0
    /// 现在是否应继续取下一页：只在“跟随最新、可读、有游标、条目不足”时成立；用户翻到别处（窗口离开最新）、定位视图、快照作废都会让它变 false。
    public var wantsInitialFill: Bool {
        fillOpen && status == .ok && hasMore && nextBefore != nil && !loadingOlder && pinnedHit == nil && !needsReplace && !hasNewer
            && !hasRowsBelowWindow && items.count < Self.fillTarget && fillPages < Self.fillMaxPages
    }

    /// 窗口覆盖的 items 下标区间。
    public var windowRange: Range<Int> {
        let end = windowEnd.map { min($0, items.count) } ?? items.count
        var lower = max(0, end - Self.renderLimit)
        if let floor = windowFloor { lower = max(lower, min(floor, end)) }
        return lower..<end
    }
    /// 窗口内要渲染的行。
    public var visibleItems: ArraySlice<TranscriptItem> { items[windowRange] }
    /// 窗口之上还有已加载但未渲染的行（本地即可展开，不用请求）。
    public var hasRowsAboveWindow: Bool { windowRange.lowerBound > 0 }
    /// 窗口之下还有较新的行（窗口已离开最新）。
    public var hasRowsBelowWindow: Bool { windowRange.upperBound < items.count }

    /// 窗口整体上移一屏（只改渲染范围，行已在本地）：丢弃窗口外最新侧的行，它们仍保留在 items 里，「回到最新」可恢复。
    public mutating func showOlderRows() {
        let start = max(0, windowRange.lowerBound - Self.renderLimit)
        windowEnd = min(items.count, start + Self.renderLimit)
        if windowEnd == items.count { windowEnd = nil }
    }
    /// 向上加载更早记录时保留阅读位置（显式 opt-in，默认的 showOlderRows 不变）：
    /// 窗口向上前展最多 `olderStep` 行，同时保证锚点行与 `lastVisibleId` 之前的可见行仍在窗口内，窗口上限仍为 renderLimit。
    /// 锚点或可见末行不在当前窗口时不改动窗口并返回 false；没有可前展的本地行（已到窗口顶端）也返回 false。
    @discardableResult
    public mutating func showOlderRows(keeping anchorId: String, lastVisibleId: String?, olderStep: Int = 20) -> Bool {
        let range = windowRange
        guard let start = keepingWindowStart(anchorId: anchorId, lastVisibleId: lastVisibleId, current: range, olderStep: olderStep) else { return false }
        setWindow(start: start, upperLimit: range.upperBound)
        return true
    }

    /// 保锚窗口的起点：向上前展最多 olderStep 行；锚点与可见末行必须仍在 [start, start+renderLimit) 内。
    /// `current` 是窗口当前覆盖的区间（items 下标；调用方可能已并入新行，所以由调用方给出，不用 windowRange）。
    /// 返回 nil 表示无法保留（锚点不在窗口、已在顶端、可见区占满窗口）。
    private func keepingWindowStart(anchorId: String, lastVisibleId: String?, current range: Range<Int>, olderStep: Int) -> Int? {
        let lo = range.lowerBound
        // ArraySlice 的 firstIndex 返回 items 的绝对下标，不需要再加窗口起点。
        guard let a = items[range].firstIndex(where: { $0.id == anchorId }) else { return nil }
        let lastNeeded = lastVisibleId.flatMap { id in items[range].firstIndex(where: { $0.id == id }) } ?? a
        let lower = max(0, lastNeeded - (Self.renderLimit - 1))
        let start = max(lower, max(0, lo - olderStep))
        guard start < lo, start <= a else { return nil }
        return start
    }

    /// 把窗口设为从 start 开始、不超过 renderLimit 行、末端不越过 upperLimit。窗口短于 renderLimit 时记下下限，避免被自动扩到更早的行。
    private mutating func setWindow(start: Int, upperLimit: Int) {
        let end = min(upperLimit, start + Self.renderLimit)
        windowEnd = end >= items.count ? nil : end
        if end - start < Self.renderLimit { windowFloor = start }
    }
    /// 窗口整体下移一屏（与 showOlderRows 对称，行已在本地）：逐段向下展开，不一次渲染全部。
    /// 返回移窗前窗口之后的第一条未渲染行（阅读位置之后的下一条）作为锚点；没有更多本地行时返回 nil 且不改动窗口。
    /// 锚点必须在移窗前取：末段不足一屏时移窗后的第一行会倒退到已读行（A1-383 R1）。
    @discardableResult
    public mutating func showNewerRows() -> String? {
        let upper = windowRange.upperBound
        guard upper < items.count else { return nil }
        let anchor = items[upper].id
        let next = min(items.count, upper + Self.renderLimit)
        windowEnd = next == items.count ? nil : next
        return anchor
    }
    /// 回到最新：窗口跟随最新行。
    public mutating func showLatestRows() { windowEnd = nil }

    /// 已翻到本次会话开头。
    public var atStart: Bool { status == .ok && !hasMore && !needsReplace }

    /// 并入最新页。换了会话、第一次加载、快照已失效、或与已有内容接不上（最新页里一条都不认识）时整体替换；
    /// 否则刷新已知项（正文 / 回执可能变化，id 不变不代表没改）并只接上新增的尾部。
    /// 返回是否已采纳（只有采纳的页才能写入 ETag）。临时不可用保留已有内容并标记陈旧，不算采纳。
    /// `shape` 是发起时的后补声明：页带 receiptUpdates 时先更新已加载项（正文因定位视图 / 尾部裁剪被拒、或整页替换时仍成立），
    /// 页正文采纳后再补一次（同页里的该项没有 receipt 时不让页覆盖掉补丁）；ETag 绑定该形状。
    @discardableResult
    public mutating func applyLatest(_ page: TranscriptPage, snapshot requested: Int? = nil, etag: String? = nil, shape: TranscriptReceiptRequest? = nil) -> Bool {
        // 一次分类：冲突项在正文刷新前就被排除，刷新后只恢复已批准的项（页覆盖成空 receipt 的项不能在第二遍把冲突放行）。
        let approved = approvedReceiptUpdates(page, request: shape, snapshot: requested)
        writeReceipts(approved)
        let adopted = adoptLatest(page, snapshot: requested, etag: etag, shape: shape)
        if adopted { writeReceipts(approved, onlyIfEmpty: true) }
        return adopted
    }

    private mutating func adoptLatest(_ page: TranscriptPage, snapshot requested: Int?, etag: String?, shape: TranscriptReceiptRequest?) -> Bool {
        if let requested, requested != snapshot { dirty = true; return false } // 发起后快照已失效（reset / 410）：旧页不能消费失效标记，补拉一次
        guard pinnedHit == nil else { return false } // 定位视图：最新页不替换命中所在的页；回到最新会先 invalidate
        guard page.isAvailable else {
            if !TranscriptUnavailability.clearsContent(reason: page.reason) {
                if items.isEmpty { status = .unavailable; unavailableReason = page.reason } else { stale = true }
                return false
            }
            status = .unavailable; unavailableReason = page.reason; resetLinkedOnEpochChange(page.sessionEpoch); items = []; sessionEpoch = page.sessionEpoch; revision = page.revision; nextBefore = nil; hasMore = false
            needsReplace = false; loadingOlder = false; windowEnd = nil; snapshot += 1
            latestETag = nil; olderChunks = []; stale = false; hasNewer = false
            return true
        }
        // 身份未变的普通最新页：尾部已被裁掉时不替换阅读位置（只能由「回到最新」恢复）。身份变化（epoch）时强制替换。
        let identityChanged = page.sessionEpoch != sessionEpoch
        if hasNewer && !identityChanged { return false }
        status = .ok; unavailableReason = nil; stale = false
        let known = Set(items.map(\.id))
        let overlaps = page.items.contains { known.contains($0.id) }
        if needsReplace || items.isEmpty || identityChanged || !overlaps {
            resetLinkedOnEpochChange(page.sessionEpoch)
            items = page.items; nextBefore = page.nextBefore; hasMore = page.hasMore
            needsReplace = false; loadingOlder = false; windowEnd = nil; snapshot += 1
            olderChunks = []; hasNewer = false
            fillOpen = true; fillPages = 0
        } else {
            // 同代次的重叠窗口按新页顺序重排：已缓存的历史项可能因投影升级而新出现在中间（不能只追加尾部）。
            // 窗口之前的更早历史保留；窗口内不再由新页返回的项（已消失）保留在窗口末端；窗口之后的项不动。
            let pageIds = Set(page.items.map(\.id))
            let overlap = items.indices.filter { pageIds.contains(items[$0].id) }
            if let lo = overlap.first, let hi = overlap.last {
                let vanished = items[lo...hi].filter { !pageIds.contains($0.id) }
                // 新页之前、未被任何段记录的已加载历史（之前的最新页累积）：以新页的 nextBefore 为游标重取，成为最旧段之后的新段。
                let recorded = Set(olderChunks.flatMap(\.ids))
                let before = items[..<lo]
                let accumulated = before.filter { !recorded.contains($0.id) }.map(\.id)
                var kept = Array(before)
                // 没有游标时这些条目保留但不可淘汰（不能删除仍可能有效的历史）。
                if !accumulated.isEmpty, let cursor = page.nextBefore, page.hasMore {
                    olderChunks.insert(OlderChunk(ids: accumulated, cursor: cursor), at: 0)
                }
                // 段只允许覆盖新页之前的内容（不能指向可见的页内条目）
                let prefixIds = Set(kept.map(\.id))
                olderChunks = olderChunks.compactMap { c in
                    let ids = c.ids.filter { prefixIds.contains($0) }
                    return ids.isEmpty ? nil : OlderChunk(ids: ids, cursor: c.cursor)
                }
                items = kept + page.items + vanished + Array(items[(hi + 1)...])
            }
        }
        sessionEpoch = page.sessionEpoch; revision = page.revision
        latestETag = etag; latestShape = shape
        return true
    }

    /// 并入更早的一页（游标来自 `nextBefore`）。空的 partial 页也会前移游标，不能当成起点。
    /// `snapshot` 为发起请求时的快照代次：快照已换（整体替换 / 失效）则整页丢弃。
    /// `cursor` 是取得这一页所用的游标（淘汰后据此重取）；没有时这一页不参与淘汰。
    /// 更早页并入。`keeping` 为 nil（默认）保持原语义：窗口整体上移，新行在窗口顶部。
    /// 给出 `keeping`（显式 opt-in）：优先保留阅读位置——有有效锚点且可前展时，锚点与可见末行仍在窗口内，前展最多 `olderStep`（默认 20）行，
    /// 其余并入的行留在本地缓存，之后的本地前展（showOlderRows(keeping:)）逐段取用；
    /// 没有有效锚点或无法在不丢可见行的前提下前展时，窗口原样保持（仍是原来那些行，只是下标整体后移），绝不退回整体上移。
    /// 页被拒（旧快照、会话已换、不可用）、没有新增行、或窗口保持不变时 `windowMovedUp` 为 false，调用方不应做位置补偿。
    @discardableResult
    public mutating func applyOlder(_ page: TranscriptPage, snapshot requested: Int, cursor: String? = nil, keeping: KeepReading? = nil, olderStep: Int = 20) -> OlderMerge {
        guard requested == snapshot else { return OlderMerge() } // 旧快照的页：所属快照已不存在，busy 也已随替换归还
        loadingOlder = false
        guard page.isAvailable, page.sessionEpoch == sessionEpoch else { return OlderMerge() } // 会话已换：等最新页重来
        refreshKnownReceipts(from: page.items) // 已加载的项 Bridge 现已挂上 receipt：刷新元数据（不插行）
        let previousCursor = nextBefore
        fillPages += 1
        defer { if fillOpen, page.nextBefore == previousCursor || !page.hasMore { fillOpen = false } } // 游标不前进 / 到头：补齐结束
        let known = Set(items.map(\.id))
        let oldRange = windowRange
        let added = page.items.filter { !known.contains($0.id) }
        items.insert(contentsOf: added, at: 0)
        if !added.isEmpty, let cursor { olderChunks.append(OlderChunk(ids: added.map(\.id), cursor: cursor)) }
        nextBefore = page.nextBefore; hasMore = page.hasMore
        guard !added.isEmpty else { return OlderMerge() }
        let shifted = (oldRange.lowerBound + added.count)..<(oldRange.upperBound + added.count)
        guard let keeping else {
            // 更早的行并入后窗口整体上移：新行在窗口顶部，窗口外最新侧的行暂不渲染（O1-341）
            let end = min(items.count, oldRange.lowerBound + Self.renderLimit)
            windowEnd = end == items.count ? nil : end // 窗口仍覆盖最新行时继续跟随最新，否则之后到达的新行不渲染
            return OlderMerge(added: added.count, windowMovedUp: true)
        }
        if let anchorId = keeping.anchorId,
           let start = keepingWindowStart(anchorId: anchorId, lastVisibleId: keeping.lastVisibleId, current: shifted, olderStep: min(added.count, olderStep)) {
            setWindow(start: start, upperLimit: shifted.upperBound)
            return OlderMerge(added: added.count, windowMovedUp: true)
        }
        // 保持窗口：渲染的仍是原来那些行（窗口短于 renderLimit 时用下限挡住前插的行）。
        setWindow(start: shifted.lowerBound, upperLimit: shifted.upperBound)
        return OlderMerge(added: added.count, windowMovedUp: false)
    }

    /// 定位自读的一页成为新的最新页（调用方须已确认页可用，且线程未处于定位视图）：整体替换并推进快照，
    /// 使更早发起的普通最新页 / 更早页响应按快照规则丢弃，不覆盖这一页（R3）。
    public mutating func replaceWithLatest(_ page: TranscriptPage) {
        status = .ok; resetLinkedOnEpochChange(page.sessionEpoch); sessionEpoch = page.sessionEpoch; revision = page.revision
        items = page.items; nextBefore = page.nextBefore; hasMore = page.hasMore
        needsReplace = false; loadingOlder = false; windowEnd = nil; snapshot += 1
        latestETag = nil; olderChunks = []; stale = false
    }

    /// 以搜索命中所在的一页进入定位视图。页不可用，或页里没有 itemId（追加过多、已移动）时返回 false、内容不变，调用方退回最新页。
    @discardableResult
    public mutating func applyLocated(_ page: TranscriptPage, itemId: String) -> Bool {
        guard page.isAvailable, page.items.contains(where: { $0.id == itemId }) else { return false }
        status = .ok; resetLinkedOnEpochChange(page.sessionEpoch); sessionEpoch = page.sessionEpoch; revision = page.revision
        items = page.items; nextBefore = page.nextBefore; hasMore = page.hasMore
        needsReplace = false; loadingOlder = false; pinnedHit = itemId; windowEnd = nil; snapshot += 1
        latestETag = nil; olderChunks = []
        return true
    }

    /// 游标失效（reset 事件、410）、Bridge 重启或“回到最新”：旧分页作废并退出定位视图，由调用方重新拉最新页；保留已显示内容直到新页到达。
    public mutating func invalidate() { fillOpen = false; needsReplace = true; nextBefore = nil; hasMore = false; loadingOlder = false; pinnedHit = nil; windowEnd = nil; snapshot += 1; latestETag = nil; olderChunks = []; hasNewer = false }

    /// 释放正文并作废本线程发出的在途票据（快照推进，迟到应答不再采纳）。请求计数与在途标记保留，
    /// 由票据归还时扣减（不能在淘汰时直接清计数，否则旧响应会误归还新请求）。返回释放的估算字节。
    @discardableResult
    public mutating func evictBody() -> Int {
        let freed = footprintBytes
        items = []; olderChunks = []; nextBefore = nil; hasMore = false
        windowEnd = nil; latestETag = nil; hasNewer = false; pinnedHit = nil
        needsReplace = true; snapshot += 1; stale = false; status = .loading
        return freed
    }

    /// 更早页请求失败：归还 busy（只对同一快照）。
    public mutating func olderFailed(snapshot requested: Int) { if requested == snapshot { loadingOlder = false } }

    /// 原生代次有证据地切换（新页带有不同的代次）：已关联集合不跨会话，清空后由随后赋值的 items 重新收集。
    /// 整体替换的入口都调用它；同代次时为空操作，窗口滚动与更早页并入不经过这里，保持单调。
    /// 无代次的页（暂不可读）不是换代证据，不清账本；首次取得代次时没有旧账本可清。
    private mutating func resetLinkedOnEpochChange(_ epoch: String?) {
        guard let epoch else { return }
        if let linkedEpoch, epoch != linkedEpoch { linkedEventKeys = [] }
        linkedEpoch = epoch
    }

    /// 连接代次结束（断流 / 换连接）：归还本代次的在途标记，旧请求的结果不再写入。
    public mutating func abandonRequests() { latestInFlight = false; loadingOlder = false; dirty = false; activeRequests = 0 }

    /// 条件读取的 If-None-Match：只对当前已采纳、可见的最新页给出（失效、清空、定位视图时为 nil）。
    public var validator: String? { validator(for: nil) }
    /// 带后补声明的条件读取：只有请求形状与该 ETag 取得时相同才复用（Body 随声明集合变化）。
    public func validator(for shape: TranscriptReceiptRequest?) -> String? { status == .ok && !needsReplace && pinnedHit == nil && !items.isEmpty && latestShape == shape ? latestETag : nil }

    /// 内存中已加载条目的估算字节（正文与标识，加固定开销）。展开的正文由调用方另计。
    public var footprintBytes: Int { items.reduce(0) { $0 + Self.bytes($1) } }

    static func bytes(_ item: TranscriptItem) -> Int { item.id.utf8.count + item.role.utf8.count + item.text.utf8.count + 64 }

    /// 淘汰最旧的一段已加载的更早页：只淘汰整段且不在渲染窗口内的，淘汰后 `nextBefore` 指向它，回看时按需重取。
    /// 返回释放的估算字节；0 表示没有可淘汰的段。
    @discardableResult
    public mutating func evictOldestChunk() -> Int {
        guard let chunk = olderChunks.last else { return 0 }
        let ids = Set(chunk.ids)
        let range = windowRange
        guard ids.isDisjoint(with: items[range].map(\.id)) else { return 0 }
        let doomed = items.filter { ids.contains($0.id) }
        let freed = doomed.reduce(0) { $0 + Self.bytes($1) }
        // 窗口与被淘汰段不相交：窗口前面被删掉几行，两端与下限就整体前移几行，窗口里的行不变。
        let before = items[..<range.lowerBound].reduce(0) { $0 + (ids.contains($1.id) ? 1 : 0) }
        items.removeAll { ids.contains($0.id) }
        setWindow(start: range.lowerBound - before, upperLimit: range.upperBound - before)
        nextBefore = chunk.cursor; hasMore = true; loadingOlder = false
        olderChunks.removeLast()
        return freed
    }

    /// 临时失败：保留已核验的内容，标记陈旧（界面显示「显示的是上次内容」与重试）。
    public mutating func markStale() { stale = true }

    /// 合法的 304（ETag 与当前采纳的页一致）：确认内容已与服务端同步，清除陈旧标记（F4）。
    public mutating func markFresh() { stale = false }

    /// 内存超限：裁掉渲染窗口之后的较新内容（阅读位置之上的内容保留）。返回释放的估算字节；窗口已到最新处时为 0。
    @discardableResult
    public mutating func trimNewest() -> Int {
        let start = windowRange.lowerBound, end = windowRange.upperBound
        guard end < items.count else { return 0 }
        let doomed = items[end...]
        let freed = doomed.reduce(0) { $0 + Self.bytes($1) }
        items.removeSubrange(end...)
        setWindow(start: start, upperLimit: end)  // 窗口行不变，短窗口的下限保留
        hasNewer = true
        latestETag = nil
        return freed
    }

    /// 用户点「回到最新」：清除裁剪标记，下一次最新页整体替换。
    public mutating func resumeFromLatest() {
        hasNewer = false
        needsReplace = true
        windowEnd = nil
        latestETag = nil
    }
}
