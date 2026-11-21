import Testing
import Foundation
@testable import PalmhelmKit

// O1-341：对话区只渲染窗口内的最近 renderLimit 行；数据保留在 items 里。更早页并入或本地展开时窗口整体上移，回到最新时恢复。
@Suite struct TranscriptWindowTests {
    private let n = TranscriptThread.renderLimit
    private func page(_ ids: [String], before: String? = nil, hasMore: Bool = false) -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: ids.map { TranscriptItem(id: $0, role: "user", text: $0) }, nextBefore: before, hasMore: hasMore)
    }
    private func ids(_ r: ArraySlice<TranscriptItem>) -> [String] { r.map(\.id) }
    private func numbered(_ range: Range<Int>) -> [String] { range.map { "m\($0)" } }

    @Test func rendersOnlyTheLatestWindowOfAvailableRows() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<(n + 25)), before: "c1", hasMore: true))
        #expect(t.items.count == n + 25, "数据不丢")
        #expect(ids(t.visibleItems) == numbered(25..<(n + 25)), "只渲染最近 \(n) 行")
        #expect(t.hasRowsAboveWindow && !t.hasRowsBelowWindow)
    }

    @Test func olderPageMovesTheWindowUpAndHidesTheNewestRows() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(60..<100), before: "c1", hasMore: true))  // 40 行，窗口即全部
        let snap = t.snapshot
        t.applyOlder(page(numbered(40..<60), before: "c2", hasMore: true), snapshot: snap)
        #expect(t.items.count == 60)
        #expect(ids(t.visibleItems) == numbered(40..<80), "窗口整体上移 20 行，窗口外最新侧的行暂不渲染")
        #expect(t.hasRowsBelowWindow, "离开最新：显示「回到最新」入口")
    }

    @Test func localRevealMovesUpWithoutLoadingAndBackToLatestRestores() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<(2 * n)), before: "c1", hasMore: true))
        #expect(ids(t.visibleItems) == numbered(n..<(2 * n)))
        t.showOlderRows()
        #expect(ids(t.visibleItems) == numbered(0..<n), "已加载的更早行本地展开")
        #expect(!t.hasRowsAboveWindow && t.hasRowsBelowWindow)
        t.showLatestRows()
        #expect(ids(t.visibleItems) == numbered(n..<(2 * n)), "回到最新恢复")
        #expect(!t.hasRowsBelowWindow)
    }

    @Test func keepingAnchorPrependsUpToTwentyOlderRowsAndKeepsTheVisibleRows() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<(2 * n)), before: "c1", hasMore: true))  // 窗口 40..<80 已在最新侧之前，这里取 40..<80 为可见窗口
        t.showOlderRows()                                  // 窗口 0..<40
        t.showLatestRows()                                 // 窗口 40..<80
        #expect(ids(t.visibleItems) == numbered(40..<80))
        // 锚点在窗口中部，可见末行也在窗口内：前展 20 行，锚点与可见行都保留，窗口仍是 40 行。
        let added = t.showOlderRows(keeping: "m50", lastVisibleId: "m59")
        #expect(added)
        #expect(ids(t.visibleItems) == numbered(20..<60), "锚点与可见行保留，前展 20 行")
        #expect(ids(t.visibleItems).count == n, "窗口上限不变")
        #expect(t.hasRowsBelowWindow, "窗口之下仍有较新行，回到最新入口保留")
    }

    @Test func keepingAnchorShrinksTheBatchSoTheVisibleRowsStayInTheWindow() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<(2 * n)), before: "c1", hasMore: true))
        t.showOlderRows(); t.showLatestRows()              // 窗口 40..<80
        // 可见区一直延伸到 m75：窗口起点不能低于 75-39=36，所以只能前展到 36 而不是 20 行。
        let kept = t.showOlderRows(keeping: "m44", lastVisibleId: "m75")
        #expect(kept)
        #expect(ids(t.visibleItems) == numbered(36..<76))
        #expect(ids(t.visibleItems).contains("m75") && ids(t.visibleItems).contains("m44"))
    }

    @Test func keepingAnchorIsANoOpWhenNothingCanBeKept() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<(2 * n)), before: "c1", hasMore: true))
        t.showOlderRows(); t.showLatestRows()              // 窗口 40..<80
        let before = ids(t.visibleItems)
        let blocked = t.showOlderRows(keeping: "m79", lastVisibleId: "m79")
        #expect(!blocked, "锚点在窗口底部时无法前展而保留可见行")
        #expect(ids(t.visibleItems) == before, "不改窗口")
        let missing = t.showOlderRows(keeping: "m10", lastVisibleId: nil)
        #expect(!missing, "锚点不在当前窗口")
        #expect(ids(t.visibleItems) == before)
    }

    @Test func keepingAnchorReturnsFalseAtTheStartOfTheLocalRows() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<n), before: "c1", hasMore: true))  // 本地只有 40 行，窗口即全部
        let none = t.showOlderRows(keeping: "m5", lastVisibleId: "m10")
        #expect(!none, "没有可前展的本地行")
        #expect(ids(t.visibleItems) == numbered(0..<n))
    }

    @Test func slideAnchorIsTheFirstUnrenderedRowBeforeTheSlide() {
        // A1-383 R1 反例：最新 m60…m99，加载更早 m40…m59 后渲染 m40…m79；读到 m79 后下一条必须是 m80，而不是移窗后的 first（m60）
        var t = TranscriptThread()
        t.applyLatest(page(numbered(60..<100), before: "c1", hasMore: true))
        let snap = t.snapshot
        t.applyOlder(page(numbered(40..<60), before: "c2", hasMore: true), snapshot: snap)
        #expect(ids(t.visibleItems) == numbered(40..<80))
        #expect(t.showNewerRows() == "m80")
        #expect(ids(t.visibleItems).contains("m80"), "锚点仍在窗口内")
    }

    @Test func slideAnchorTableCoversPartialFinalWindows() {
        // 窗口顶端在 0、渲染 40 行；剩余未渲染行数为 k：锚点都是第 40 条，与末段长度无关（k = 1、20、40）
        for k in [1, 20, 40] {
            var t = TranscriptThread()
            t.applyLatest(page(numbered(0..<(n + k)), before: "c1", hasMore: true))
            t.showOlderRows()
            #expect(ids(t.visibleItems) == numbered(0..<n), "k=\(k)：窗口在顶端")
            #expect(t.showNewerRows() == "m\(n)", "k=\(k)：锚点为第 \(n) 条")
            #expect(ids(t.visibleItems).contains("m\(n)"), "k=\(k)：锚点仍可见")
        }
    }

    @Test func showNewerRowsWithoutLocalRowsReturnsNilAndKeepsTheWindow() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<(2 * n)), before: "c1", hasMore: true))
        let before = ids(t.visibleItems)
        #expect(t.showNewerRows() == nil)
        #expect(ids(t.visibleItems) == before)
    }

    @Test func windowSlidesDownOneSegmentAtATimeAndStopsAtLatest() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<(3 * n)), before: "c1", hasMore: true))
        t.showOlderRows()
        #expect(ids(t.visibleItems) == numbered(n..<(2 * n)))
        t.showNewerRows()
        #expect(ids(t.visibleItems) == numbered(2 * n..<(3 * n)), "向下只展开一段，到达末尾即跟随最新")
        #expect(!t.hasRowsBelowWindow)
        t.showNewerRows()
        #expect(ids(t.visibleItems) == numbered(2 * n..<(3 * n)), "已跟随最新：无事可做")
    }

    @Test func newMessagesAppendWithoutDisturbingAWindowAwayFromLatest() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<(2 * n)), before: "c1", hasMore: true))
        t.showOlderRows()
        t.applyLatest(page(numbered(n..<(2 * n + 3)), before: "c1", hasMore: true))  // 新消息
        #expect(ids(t.visibleItems) == numbered(0..<n), "窗口位置不因新消息跳动")
        #expect(t.hasRowsBelowWindow)
    }

    @Test func replacementAndInvalidationReturnToFollowingLatest() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<(2 * n)), before: "c1", hasMore: true))
        t.showOlderRows()
        t.invalidate()
        #expect(t.windowEnd == nil, "回到最新 / 游标失效：跟随最新")
        t.applyLatest(page(numbered(500..<(500 + 2 * n)), before: "c9", hasMore: true))
        #expect(ids(t.visibleItems) == numbered((500 + n)..<(500 + 2 * n)))
    }

    @Test func emptyOlderPageKeepsTheWindow() {
        var t = TranscriptThread()
        t.applyLatest(page(numbered(0..<(2 * n)), before: "c1", hasMore: true))
        let before = t.visibleItems.map(\.id)
        t.applyOlder(page([], before: "c2", hasMore: true), snapshot: t.snapshot)
        #expect(t.visibleItems.map(\.id) == before, "空的 partial 页不移动窗口")
    }
}

extension TranscriptWindowTests {
    @Test func networkOlderPageKeepsTheAnchorAndTheVisibleRows() {
        var t = TranscriptThread()
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: (60..<100).map { TranscriptItem(id: "m\($0)", role: "user", text: "m\($0)") }, nextBefore: "c1", hasMore: true))
        let snap = t.snapshot
        // 旧窗口 60..<100；更早页给 40..<60。锚 m70，可见末行 m79：前展 20，窗口 40..<80，锚与可见行都保留。
        let older = TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: (40..<60).map { TranscriptItem(id: "m\($0)", role: "user", text: "m\($0)") }, nextBefore: "c2", hasMore: true)
        let merge = t.applyOlder(older, snapshot: snap, cursor: "c1", keeping: KeepReading(anchorId: "m70", lastVisibleId: "m79"))
        #expect(merge == OlderMerge(added: 20, windowMovedUp: true))
        #expect(t.items.count == 60)
        #expect(ids(t.visibleItems) == numbered(40..<80))
        #expect(ids(t.visibleItems).contains("m70") && ids(t.visibleItems).contains("m79"))
    }

    @Test func networkOlderPageWithoutAnchorKeepsTheOriginalSlide() {
        var t = TranscriptThread()
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: (60..<100).map { TranscriptItem(id: "m\($0)", role: "user", text: "m\($0)") }, nextBefore: "c1", hasMore: true))
        let snap = t.snapshot
        let older = TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: (40..<60).map { TranscriptItem(id: "m\($0)", role: "user", text: "m\($0)") }, nextBefore: "c2", hasMore: true)
        t.applyOlder(older, snapshot: snap, cursor: "c1")
        #expect(ids(t.visibleItems) == numbered(40..<80), "无锚时保持原来的整体上移")
    }
}

// A1-001 R2/R3：opt-in 的网络保位不能删掉可见行；没有可采纳的页或没有新增行时不报告窗口移动。
extension TranscriptWindowTests {
    private func older(_ range: Range<Int>, epoch: String? = "e1", before: String? = "c2", hasMore: Bool = true) -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: epoch, revision: "r", items: range.map { TranscriptItem(id: "m\($0)", role: "user", text: "m\($0)") }, nextBefore: before, hasMore: hasMore)
    }
    private func latest(_ range: Range<Int>) -> TranscriptThread {
        var t = TranscriptThread()
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: range.map { TranscriptItem(id: "m\($0)", role: "user", text: "m\($0)") }, nextBefore: "c1", hasMore: true))
        return t
    }

    /// 反例：窗口 m40…m79，等待期间用户读到末行 m79；更早页 m0…m39 到达。保留 m79，窗口仍是原来的行。
    @Test func networkKeepNeverDropsTheLastVisibleRow() {
        var t = latest(40..<80)
        let snap = t.snapshot
        let merge = t.applyOlder(older(0..<40), snapshot: snap, cursor: "c1", keeping: KeepReading(anchorId: "m79", lastVisibleId: "m79"))
        #expect(merge == OlderMerge(added: 40, windowMovedUp: false), "无法前展：窗口保持，不报告移动")
        #expect(ids(t.visibleItems) == numbered(40..<80), "仍渲染原来的 40 行")
        #expect(ids(t.visibleItems).contains("m79"))
        #expect(t.items.count == 80 && t.nextBefore == "c2" && t.hasMore, "缓存与游标照常并入")
        #expect(t.hasRowsAboveWindow && !t.hasRowsBelowWindow)
    }

    /// 已 opt-in 但没有有效几何锚点：同样保持原窗口，而不是整体上移。
    @Test func networkKeepWithoutAnAnchorHoldsTheWindow() {
        var t = latest(40..<80)
        let snap = t.snapshot
        let merge = t.applyOlder(older(20..<40), snapshot: snap, cursor: "c1", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        #expect(merge == OlderMerge(added: 20, windowMovedUp: false))
        #expect(ids(t.visibleItems) == numbered(40..<80))
    }

    /// 窗口不跟随最新时，保持窗口也只是下标整体后移，渲染内容不变。
    @Test func holdingKeepsAWindowThatIsNotAtLatest() {
        var t = latest(0..<100)                      // 窗口 60..<100
        let snap = t.snapshot
        t.showOlderRows()                            // 窗口 20..<60
        let before = ids(t.visibleItems)
        let page = TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: (-10..<0).map { TranscriptItem(id: "n\($0)", role: "user", text: "n") }, nextBefore: "c3", hasMore: true)
        let merge = t.applyOlder(page, snapshot: snap, cursor: "c9", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        #expect(merge.windowMovedUp == false)
        #expect(ids(t.visibleItems) == before, "渲染的仍是同一批行")
        #expect(t.hasRowsBelowWindow, "窗口之下仍有较新行，回到最新入口保留")
    }

    /// 默认调用（不 opt-in）保持原语义：整体上移，且报告窗口移动。
    @Test func defaultApplyOlderStillSlidesTheWindowAndReportsIt() {
        var t = latest(60..<100)
        let snap = t.snapshot
        let merge = t.applyOlder(older(40..<60), snapshot: snap, cursor: "c1")
        #expect(merge == OlderMerge(added: 20, windowMovedUp: true))
        #expect(ids(t.visibleItems) == numbered(40..<80))
    }

    /// R3：空页、全重复页、会话已换、旧快照都不新增行，不报告窗口移动，窗口不变；游标按原规则推进（仅可采纳的页）。
    @Test func rejectedOrEmptyPagesDoNotReportAMove() {
        var t = latest(40..<80)
        let snap = t.snapshot
        let keep = KeepReading(anchorId: "m50", lastVisibleId: "m55")
        let window = ids(t.visibleItems)

        let empty = t.applyOlder(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: [], nextBefore: "c-empty", hasMore: false, partial: true), snapshot: snap, cursor: "c1", keeping: keep)
        #expect(empty == OlderMerge() && ids(t.visibleItems) == window)
        #expect(t.nextBefore == "c-empty" && !t.hasMore, "可采纳的空 partial 页照常推进游标")

        var d = latest(40..<80)
        let dup = d.applyOlder(older(60..<80), snapshot: d.snapshot, cursor: "c1", keeping: keep)
        #expect(dup == OlderMerge() && ids(d.visibleItems) == numbered(40..<80), "全重复页")

        var e = latest(40..<80)
        let mismatch = e.applyOlder(older(0..<40, epoch: "other"), snapshot: e.snapshot, cursor: "c1", keeping: keep)
        #expect(mismatch == OlderMerge() && e.items.count == 40, "会话已换：页被拒")

        var stale = latest(40..<80)
        let old = stale.applyOlder(older(0..<40), snapshot: stale.snapshot + 1, cursor: "c1", keeping: keep)
        #expect(old == OlderMerge() && stale.items.count == 40, "旧快照的页被拒")
    }
}

// A1-002 F2：不足 renderLimit 行的窗口——保持就是原来那些行，保锚前展 <=20 行、<=40 行，结果与实际窗口一致。
extension TranscriptWindowTests {
    private func shortThread(_ range: Range<Int>) -> TranscriptThread {
        var t = TranscriptThread()
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: range.map { TranscriptItem(id: "m\($0)", role: "user", text: "m\($0)") }, nextBefore: "c1", hasMore: true))
        return t
    }
    private func olderPage(_ range: Range<Int>) -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: range.map { TranscriptItem(id: "m\($0)", role: "user", text: "m\($0)") }, nextBefore: "c2", hasMore: true)
    }

    /// 探针反例：10 行窗口 + 40 行更早页，无锚点：窗口仍是原来的 10 行，不报告移动。
    @Test func tenRowWindowHoldsExactlyTheOldRows() {
        var t = shortThread(40..<50)
        let merge = t.applyOlder(olderPage(0..<40), snapshot: t.snapshot, cursor: "c1", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        #expect(merge == OlderMerge(added: 40, windowMovedUp: false))
        #expect(ids(t.visibleItems) == numbered(40..<50), "渲染的仍是原来的 10 行")
        #expect(t.items.count == 50 && t.hasRowsAboveWindow)
    }

    /// 探针反例：10 行窗口、有效锚点：前展至多 20（不是 30），窗口 <=40。
    @Test func tenRowWindowWithAnAnchorPrependsAtMostTwenty() {
        var t = shortThread(40..<50)
        let merge = t.applyOlder(olderPage(0..<40), snapshot: t.snapshot, cursor: "c1", keeping: KeepReading(anchorId: "m40", lastVisibleId: "m49"))
        #expect(merge == OlderMerge(added: 40, windowMovedUp: true))
        #expect(ids(t.visibleItems) == numbered(20..<50), "前展 20 行：m20…m49，共 30 行")
        #expect(ids(t.visibleItems).count <= TranscriptThread.renderLimit)
    }

    /// 临界：39 行窗口。无锚点保持 39 行；有锚点前展 <=20 且总数 <=40。
    @Test func thirtyNineRowWindowAtTheBoundary() {
        var held = shortThread(41..<80)
        let m1 = held.applyOlder(olderPage(0..<41), snapshot: held.snapshot, cursor: "c1", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        #expect(m1.windowMovedUp == false && ids(held.visibleItems) == numbered(41..<80))
        var kept = shortThread(41..<80)
        let m2 = kept.applyOlder(olderPage(0..<41), snapshot: kept.snapshot, cursor: "c1", keeping: KeepReading(anchorId: "m41", lastVisibleId: "m45"))
        #expect(m2.windowMovedUp)
        let visible = ids(kept.visibleItems)
        #expect(visible.count <= TranscriptThread.renderLimit)
        #expect(visible.contains("m41") && visible.contains("m45"))
        #expect(visible.first == "m21", "前展 20 行")
    }

    /// 39 行窗口、可见区一直到末行：还能前展 1 行（总数到 40），不能更多；40 行窗口则完全无法前展，保持。
    @Test func aVisibleRegionThatFillsTheWindowOnlyAllowsWhatFits() {
        var t = shortThread(41..<80)
        let merge = t.applyOlder(olderPage(0..<41), snapshot: t.snapshot, cursor: "c1", keeping: KeepReading(anchorId: "m41", lastVisibleId: "m79"))
        #expect(merge.windowMovedUp)
        #expect(ids(t.visibleItems) == numbered(40..<80), "只前展到 40 行上限")
        var full = shortThread(40..<80)
        let held = full.applyOlder(olderPage(0..<40), snapshot: full.snapshot, cursor: "c1", keeping: KeepReading(anchorId: "m40", lastVisibleId: "m79"))
        #expect(held.windowMovedUp == false)
        #expect(ids(full.visibleItems) == numbered(40..<80))
    }

    /// 下限只属于这次保位：之后任何窗口变化（本地上移、回到最新）都清掉它，默认窗口语义不变。
    @Test func theFloorIsClearedByAnyOtherWindowChange() {
        var t = shortThread(40..<50)
        t.applyOlder(olderPage(0..<40), snapshot: t.snapshot, cursor: "c1", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        #expect(t.windowFloor == 40)
        t.showOlderRows()
        #expect(t.windowFloor == nil)
        #expect(ids(t.visibleItems) == numbered(0..<40), "默认本地上移：上一个 40 行窗口")
        var u = shortThread(40..<50)
        u.applyOlder(olderPage(0..<40), snapshot: u.snapshot, cursor: "c1", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        u.showLatestRows()
        #expect(u.windowFloor == nil)
        #expect(ids(u.visibleItems) == numbered(10..<50))
    }

    /// 窗口跟随最新时，新消息追加在尾部：下限仍有效，窗口随新行增长直到 renderLimit。
    @Test func appendedMessagesGrowAFloorLimitedWindow() {
        var t = shortThread(40..<50)
        t.applyOlder(olderPage(0..<40), snapshot: t.snapshot, cursor: "c1", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r2", items: (40..<52).map { TranscriptItem(id: "m\($0)", role: "user", text: "m\($0)") }, nextBefore: "c1", hasMore: true))
        #expect(ids(t.visibleItems).first == "m40" && ids(t.visibleItems).last == "m51", "老行与新消息都在，窗口增长")
    }

    /// A1-003 F4：淘汰整段更早页后，短窗口的下限随之前移，窗口里的行不变（此前可见行变成 0）。
    @Test func evictingTheOnlyOlderChunkKeepsTheShortWindow() {
        var t = shortThread(40..<50)
        t.applyOlder(olderPage(0..<40), snapshot: t.snapshot, cursor: "c1", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        #expect(t.evictOldestChunk() > 0)
        #expect(t.items.count == 10)
        #expect(ids(t.visibleItems) == numbered(40..<50), "淘汰后仍渲染原来的 10 行")
        #expect(t.windowRange == 0..<10 && !t.hasRowsAboveWindow)
    }

    /// 正例对照：淘汰后前面仍有未淘汰的缓存行，窗口不能被自动扩到那些行里。
    @Test func evictingOneChunkKeepsTheFloorWhenAnotherPrefixRemains() {
        var t = shortThread(40..<50)
        t.applyOlder(olderPage(20..<40), snapshot: t.snapshot, cursor: "c1", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        t.applyOlder(olderPage(0..<20), snapshot: t.snapshot, cursor: "c2", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        #expect(t.evictOldestChunk() > 0)
        #expect(ids(t.visibleItems) == numbered(40..<50), "仍是原来的 10 行，不扩到 m20…m39")
        #expect(t.windowRange == 20..<30 && t.hasRowsAboveWindow)
    }

    /// 审计：trimNewest 之后短窗口同样不被扩到更早的缓存行。
    @Test func trimNewestKeepsAShortWindow() {
        var t = shortThread(20..<60)
        t.applyOlder(olderPage(0..<20), snapshot: t.snapshot, cursor: "c1", keeping: KeepReading(anchorId: nil, lastVisibleId: nil))
        t.showOlderRows(keeping: "m25", lastVisibleId: "m30")  // 窗口 0..<40 之内的短窗口
        let before = ids(t.visibleItems)
        #expect(t.trimNewest() >= 0)
        #expect(ids(t.visibleItems) == before)
    }
}

/// C4：一次前展预算（olderStep）。网络页仍取 20，窗口一次只前展预算内的行，其余留在本地缓存供后续本地前展；默认 20 的旧行为不变。
@Suite struct OlderStepBudgetTests {
    private func numbered(_ range: Range<Int>) -> [String] { range.map { "m\($0)" } }
    private func page(_ range: Range<Int>, before: String? = "c2", hasMore: Bool = true) -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: range.map { TranscriptItem(id: "m\($0)", role: "user", text: "m\($0)") }, nextBefore: before, hasMore: hasMore)
    }
    private func fullWindow() -> TranscriptThread {
        var t = TranscriptThread()
        t.applyLatest(page(60..<100, before: "c1")) // 40 行，窗口即全部
        return t
    }
    private func visibleIds(_ t: TranscriptThread) -> [String] { t.visibleItems.map(\.id) }
    private let keep = KeepReading(anchorId: "m60", lastVisibleId: "m65")

    private func newlyRendered(_ before: [String], _ t: TranscriptThread) -> [String] { visibleIds(t).filter { !before.contains($0) } }

    @Test func networkPageWithBudgetFourRendersFourNewRowsAndKeepsTheRestLocal() {
        var t = fullWindow()
        let before = visibleIds(t)
        let merge = t.applyOlder(page(40..<60), snapshot: t.snapshot, cursor: "c1", keeping: keep, olderStep: 4)
        #expect(merge.added == 20 && merge.windowMovedUp)
        #expect(newlyRendered(before, t) == numbered(56..<60), "只新增 4 条进入渲染窗口")
        #expect(visibleIds(t).contains("m60") && visibleIds(t).contains("m65"), "锚点与可见末行保留")
        #expect(t.items.count == 60 && t.windowRange.count == TranscriptThread.renderLimit, "20 条缓存完整并入，窗口仍是 40 行")
        #expect(t.hasRowsAboveWindow, "其余 16 条在窗口之上的本地缓存里")
    }

    @Test func budgetEightAndTheDefaultTwentyBehaveAsBefore() {
        for (step, expected) in [(8, 8), (20, 20)] {
            var t = fullWindow()
            let before = visibleIds(t)
            t.applyOlder(page(40..<60), snapshot: t.snapshot, cursor: "c1", keeping: keep, olderStep: step)
            #expect(newlyRendered(before, t).count == expected, "预算 \(step)")
        }
        var legacy = fullWindow()
        let before = visibleIds(legacy)
        legacy.applyOlder(page(40..<60), snapshot: legacy.snapshot, cursor: "c1", keeping: keep) // 不传预算：默认 20
        #expect(newlyRendered(before, legacy) == numbered(40..<60), "未 opt-in 的调用方仍是 20")
    }

    /// 网络取到的 20 条：第一次提交 4 条，之后 4 次本地前展各 4 条，顺序无缺失 / 重复 / 多余，第 5 次没有可前展的行。
    @Test func fiveStepsOfFourWalkThroughTheTwentyCachedRowsInOrder() {
        var t = fullWindow()
        t.applyOlder(page(40..<60), snapshot: t.snapshot, cursor: "c1", keeping: keep, olderStep: 4)
        var seen = numbered(56..<60)
        for _ in 0..<4 {
            let before = visibleIds(t)
            let top = before[0]
            let lastVisible = before[5]
            let moved = t.showOlderRows(keeping: top, lastVisibleId: lastVisible, olderStep: 4)
            #expect(moved)
            let added = newlyRendered(before, t)
            #expect(added.count == 4)
            seen = added + seen
        }
        #expect(seen == numbered(40..<60), "20 条按顺序各出现一次")
        #expect(!t.hasRowsAboveWindow)
        let before = visibleIds(t)
        let fifth = t.showOlderRows(keeping: before[0], lastVisibleId: before[5], olderStep: 4)
        #expect(!fifth, "没有更早的本地行：窗口不动")
        #expect(visibleIds(t) == before)
    }

    @Test func emptyDuplicateRejectedAndAnchorlessPagesNeverMoveTheWindowWithABudget() {
        var empty = fullWindow()
        let w = empty.windowRange
        _ = empty.applyOlder(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: [], nextBefore: "c-x", hasMore: false, partial: true), snapshot: empty.snapshot, cursor: "c1", keeping: keep, olderStep: 4)
        #expect(empty.windowRange == w)
        var dup = fullWindow()
        let dupMerge = dup.applyOlder(page(60..<80), snapshot: dup.snapshot, cursor: "c1", keeping: keep, olderStep: 4)
        #expect(dupMerge.added == 0)
        var stale = fullWindow()
        let staleMerge = stale.applyOlder(page(40..<60), snapshot: stale.snapshot + 1, cursor: "c1", keeping: keep, olderStep: 4)
        #expect(!staleMerge.windowMovedUp)
        var noAnchor = fullWindow()
        let before = visibleIds(noAnchor)
        let merge = noAnchor.applyOlder(page(40..<60), snapshot: noAnchor.snapshot, cursor: "c1", keeping: KeepReading(anchorId: nil, lastVisibleId: nil), olderStep: 4)
        #expect(!merge.windowMovedUp && visibleIds(noAnchor) == before, "没有几何锚点：窗口保持，预算不改变这一点")
    }
}
