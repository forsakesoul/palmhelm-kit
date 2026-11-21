import Testing
import Foundation
@testable import PalmhelmKit

// #111：首页被大段工具输出占满（字节预算）时，Bridge 返回“2 条 partial → 0 条 partial → 20 条”。
// 首屏补齐决策在 TranscriptThread；两端 Session 按 wantsInitialFill 逐页请求。这里用假分页源按同样的方式驱动。
@Suite struct TranscriptInitialFillTests {
    private func page(_ ids: [String], before: String?, hasMore: Bool = true) -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: ids.map { TranscriptItem(id: $0, role: "assistant", text: $0) }, nextBefore: before, hasMore: hasMore)
    }
    private func ids(_ r: Range<Int>) -> [String] { r.map { "m\($0)" } }

    /// 与 Session 的接线同形：只要线程还想补齐就请求下一页并并入；返回请求次数（硬上限防止测试自身死循环）。
    private func drive(_ t: inout TranscriptThread, pages: [String: TranscriptPage]) -> Int {
        var requests = 0
        while t.wantsInitialFill, requests < 50, let before = t.nextBefore, let next = pages[before] {
            requests += 1
            t.loadingOlder = true
            t.applyOlder(next, snapshot: t.snapshot, cursor: before)
        }
        return requests
    }

    @Test func sparseFirstPageThenEmptyPartialThenFullPageFillsWithoutAnyInteraction() {
        var t = TranscriptThread()
        t.applyLatest(page(["m98", "m99"], before: "c1"))
        let requests = drive(&t, pages: ["c1": page([], before: "c2"), "c2": page(ids(78..<98), before: "c3")])
        #expect(requests == 2)
        #expect(t.items.count == 22)
        #expect(!t.wantsInitialFill)
    }

    @Test func exhaustedHistoryDoesNotSpin() {
        var t = TranscriptThread()
        t.applyLatest(page(["m1", "m2", "m3"], before: nil, hasMore: false))
        #expect(!t.wantsInitialFill)
        var u = TranscriptThread()
        u.applyLatest(page(["m2", "m3"], before: "c1"))
        let requests = drive(&u, pages: ["c1": page(["m1"], before: nil, hasMore: false)])
        #expect(requests == 1 && u.items.count == 3 && !u.wantsInitialFill, "取到开头就停，不空转")
    }

    @Test func aFullFirstPageNeverAsksForMore() {
        var t = TranscriptThread()
        t.applyLatest(page(ids(80..<100), before: "c1"))
        #expect(!t.wantsInitialFill)
    }

    @Test func capsConsecutivePagesWhenEveryPageIsEmpty() {
        var t = TranscriptThread()
        t.applyLatest(page(["m99"], before: "c1"))
        var all: [String: TranscriptPage] = [:]
        for i in 1..<20 { all["c\(i)"] = page([], before: "c\(i + 1)") }
        #expect(drive(&t, pages: all) == TranscriptThread.fillMaxPages)
        #expect(t.items.count == 1 && t.hasMore, "上限到了就交还给用户手动加载")
    }

    @Test func stopsWhenTheCursorDoesNotAdvance() {
        var t = TranscriptThread()
        t.applyLatest(page(["m99"], before: "c1"))
        #expect(drive(&t, pages: ["c1": page([], before: "c1")]) == 1)
        #expect(!t.wantsInitialFill)
    }

    @Test func stopsWhenTheUserLeavesTheLatestWindowOrTheSnapshotIsInvalidated() {
        var t = TranscriptThread()
        t.applyLatest(page(["m99"], before: "c1"))
        #expect(t.wantsInitialFill)
        t.invalidate()
        #expect(!t.wantsInitialFill, "游标作废：旧补齐不再继续")
        var u = TranscriptThread()
        u.applyLatest(page(["m99"], before: "c1"))
        let located = u.applyLocated(page(["m50", "m99"], before: "c0"), itemId: "m50")
        #expect(located)
        #expect(!u.wantsInitialFill, "定位视图不补齐")
    }

    @Test func laterLatestRefreshesDoNotRestartAFinishedFill() {
        var t = TranscriptThread()
        t.applyLatest(page(["m98", "m99"], before: "c1"))
        _ = drive(&t, pages: ["c1": page(ids(78..<98), before: "c2")])
        t.applyLatest(page(["m99", "m100"], before: "c1"))
        #expect(!t.wantsInitialFill)
    }

    @Test func aNewSessionEpochStartsAFreshFill() {
        var t = TranscriptThread()
        t.applyLatest(page(["m98", "m99"], before: "c1"))
        _ = drive(&t, pages: ["c1": page(ids(78..<98), before: nil, hasMore: false)])
        var other = page(["n1"], before: "d1"); other.sessionEpoch = "e2"
        t.applyLatest(other)
        #expect(t.wantsInitialFill, "换了原生会话：按首次打开处理")
    }
}

@Suite struct TranscriptInitialFillFollowTests {
    @Test func windowKeepsFollowingTheLatestRowsAfterTheFillPages() {
        var t = TranscriptThread()
        func p(_ ids: [String], _ before: String?) -> TranscriptPage {
            TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: ids.map { TranscriptItem(id: $0, role: "assistant", text: $0) }, nextBefore: before, hasMore: before != nil)
        }
        t.applyLatest(p(["m98", "m99"], "c1"))
        t.applyOlder(p((78..<98).map { "m\($0)" }, "c2"), snapshot: t.snapshot, cursor: "c1")
        t.applyLatest(p(["m98", "m99", "m100"], "c1"))
        #expect(t.visibleItems.last?.id == "m100", "补齐之后到达的新行仍然渲染")
    }
}
