import Testing
@testable import PalmhelmKit

@Suite struct TranscriptLocateTests {
    private func page(_ ids: [String], before: String? = nil, hasMore: Bool = false, status: String = "ok", epoch: String = "e1") -> TranscriptPage {
        TranscriptPage(status: status, sessionEpoch: epoch, revision: "r", items: ids.map { TranscriptItem(id: $0, role: "user", text: $0) }, nextBefore: before, hasMore: hasMore)
    }

    /// 最新页 [m5, m6]，已向上翻过一页 [m3, m4]。
    private func loadedLatest() -> TranscriptThread {
        var t = TranscriptThread()
        t.applyLatest(page(["m5", "m6"], before: "c-latest", hasMore: true))
        t.applyOlder(page(["m3", "m4"], before: "c-3", hasMore: true), snapshot: t.snapshot)
        return t
    }

    @Test func locatedPageReplacesItemsAndPins() {
        var t = loadedLatest()
        let ok = t.applyLocated(page(["x1", "x2", "x3"], before: "c-x", hasMore: true), itemId: "x2")
        #expect(ok)
        #expect(t.items.map(\.id) == ["x1", "x2", "x3"])
        #expect(t.pinnedHit == "x2")
        #expect(t.nextBefore == "c-x" && t.hasMore)
        #expect(t.status == .ok)
    }

    @Test func locatedPageWithoutItemFailsAndKeepsContent() {
        var t = loadedLatest()
        let before = t
        let ok = t.applyLocated(page(["x1"]), itemId: "gone")
        #expect(!ok)
        #expect(t == before)
        #expect(t.pinnedHit == nil)
    }

    @Test func unavailableLocatedPageFails() {
        var t = loadedLatest()
        let ok = t.applyLocated(page([], status: "unavailable"), itemId: "x1")
        #expect(!ok)
        #expect(t.pinnedHit == nil && t.items.map(\.id) == ["m3", "m4", "m5", "m6"])
    }

    @Test func latestPagesDoNotReplaceLocatedView() {
        var t = loadedLatest()
        t.applyLocated(page(["x1", "x2"], before: "c-x", hasMore: true), itemId: "x1")
        let located = t.items
        t.applyLatest(page(["m7", "m8"], before: "c-7", hasMore: false), snapshot: t.snapshot)
        t.applyLatest(page(["m9"], before: nil, hasMore: false))
        #expect(t.items == located)
        #expect(t.pinnedHit == "x1")
    }

    @Test func olderPagesStillExtendTheLocatedView() {
        var t = loadedLatest()
        t.applyLocated(page(["x2", "x3"], before: "c-x", hasMore: true), itemId: "x2")
        t.applyOlder(page(["x0", "x1"], before: "c-0", hasMore: false), snapshot: t.snapshot)
        #expect(t.items.map(\.id) == ["x0", "x1", "x2", "x3"])
        #expect(t.hasMore == false && t.nextBefore == "c-0")
    }

    @Test func olderPageFromBeforeLocateIsDropped() {
        var t = loadedLatest()
        let stale = t.snapshot
        t.applyLocated(page(["x2"], before: "c-x", hasMore: true), itemId: "x2")
        t.applyOlder(page(["m2"], before: "c-2", hasMore: true), snapshot: stale)
        #expect(t.items.map(\.id) == ["x2"])
    }

    @Test func backToLatestClearsPinAndReplacesOnNextLatest() {
        var t = loadedLatest()
        t.applyLocated(page(["x1"], before: "c-x", hasMore: true), itemId: "x1")
        t.invalidate()
        #expect(t.pinnedHit == nil)
        #expect(t.needsReplace)
        t.applyLatest(page(["m7", "m8"], before: "c-7", hasMore: true))
        #expect(t.items.map(\.id) == ["m7", "m8"])
        #expect(!t.needsReplace && t.pinnedHit == nil)
    }

    private func hit(_ item: String, before: String?) -> SearchHit {
        SearchHit(targetId: "t1", itemId: item, sessionEpoch: "e1", pageBefore: before, role: "user", snippet: "s", ranges: [])
    }

    @Test func hitPageLocatesOrReportsMoved() {
        var t = loadedLatest()
        #expect(SearchLocate.apply(page: page(["x1", "x2"], before: "c-x"), hit: hit("x2", before: "c-x"), to: &t) == nil)
        #expect(t.pinnedHit == "x2")
        var u = loadedLatest()
        let before = u
        #expect(SearchLocate.apply(page: page(["x1"]), hit: hit("gone", before: "c-x"), to: &u) == "这条记录已移动，请重新搜索")
        #expect(u == before)
    }

    @Test func latestHitRequiresItemInLatestPage() {
        let t = loadedLatest()
        #expect(SearchLocate.inLatest(hit("m6", before: nil), t) == nil)
        #expect(SearchLocate.inLatest(hit("m3", before: nil), t) == nil)
        #expect(SearchLocate.inLatest(hit("zz", before: nil), t) == "这条记录已移动，请重新搜索")
    }

    @Test func gone410IsMovedAndOtherErrorsAreOpenFailure() {
        #expect(SearchLocate.failure(BridgeError.http(status: 410)) == "这条记录已移动，请重新搜索")
        #expect(SearchLocate.failure(BridgeError.http(status: 500)) == "打开这条记录失败，请稍后再试")
        #expect(SearchLocate.failure(BridgeError.decoding) == "打开这条记录失败，请稍后再试")
    }

    @Test func searchLocationSerialAndHighlightScope() {
        let first = SearchLocation.opened(after: 0, threadId: "t1", itemId: "i1", query: "zeta")
        let again = SearchLocation.opened(after: first.serial, threadId: "t1", itemId: "i1", query: "zeta")
        #expect(first.serial == 1 && again.serial == 2 && again != first)
        #expect(again.highlight(for: "t1") == "zeta")
        #expect(again.highlight(for: "t2") == nil)
    }

    @Test func replaceWithLatestAdvancesSnapshotSoOlderLatestIsDropped() {
        var t = loadedLatest()
        let snap = t.snapshot
        t.replaceWithLatest(page(["m5", "needle"], before: "c-n", hasMore: true))
        #expect(t.snapshot == snap + 1)
        #expect(t.items.map(\.id) == ["m5", "needle"])
        t.applyLatest(page(["m5", "old"]), snapshot: snap) // 发起于替换之前的普通最新页
        #expect(t.items.map(\.id) == ["m5", "needle"])
        #expect(t.dirty)
    }
}
