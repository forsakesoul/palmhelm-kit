import Testing
import Foundation
@testable import PalmhelmKit

// t20：Bridge 修复后，已缓存的同代次页里会出现此前不可见的历史项（如立即发送的排队消息）。
// 新页顺序是权威的：重叠窗口按新页重排，不能把新出现的项追加到尾部。
@Suite struct TranscriptWarmPageTests {
    private func receipt(_ key: String) -> TranscriptReceipt {
        TranscriptReceipt(commandKey: "anonymous", origin: "api", receiptState: "unknown", eventKey: key)
    }

    @Test func alreadyLoadedPagePlacesNewlyVisibleHistoricalItemBetweenItsNeighbors() {
        let before = TranscriptItem(id: "before", role: "assistant", text: "before", t: 2000)
        let after = TranscriptItem(id: "after", role: "assistant", text: "after", t: 3000)
        let queue = TranscriptItem(id: "queue", role: "user", text: "queued input", t: 1000, receipt: receipt("ek1"))
        var thread = TranscriptThread()
        thread.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r1", items: [before, after]))
        thread.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r2", items: [before, queue, after]))
        #expect(thread.items.map(\.id) == ["before", "queue", "after"], "升级后的新页必须按其顺序插入，不能追加到 after 之后")
        #expect(thread.linkedEventKeys == ["ek1"])
    }

    @Test func warmPageKeepsOlderHistoryAndDropsNothingItStillReturns() {
        let older = TranscriptItem(id: "older", role: "assistant", text: "older", t: 500)
        let before = TranscriptItem(id: "before", role: "assistant", text: "before", t: 2000)
        let after = TranscriptItem(id: "after", role: "assistant", text: "after", t: 3000)
        let queue = TranscriptItem(id: "queue", role: "user", text: "queued input", t: 1000)
        var thread = TranscriptThread()
        thread.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r1", items: [before, after], nextBefore: "c", hasMore: true))
        thread.applyOlder(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r0", items: [older], nextBefore: nil, hasMore: false), snapshot: thread.snapshot)
        thread.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r2", items: [before, queue, after]))
        #expect(thread.items.map(\.id) == ["older", "before", "queue", "after"])
    }

    @Test func coldPageKeepsResponseOrderWithoutSortingByTimestamp() {
        let page = TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r1", items: [
            TranscriptItem(id: "before", role: "assistant", text: "before", t: 2000),
            TranscriptItem(id: "queue", role: "user", text: "queued input", t: 1000, receipt: receipt("ek1")),
            TranscriptItem(id: "after", role: "assistant", text: "after", t: 3000)])
        var thread = TranscriptThread()
        thread.applyLatest(page)
        #expect(thread.items.map(\.id) == ["before", "queue", "after"])
        #expect(thread.linkedEventKeys == ["ek1"])
    }

    @Test func sameTextUsersWithoutReceiptsStayAmbiguousOnWarmPage() {
        var thread = TranscriptThread()
        thread.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r1", items: [
            TranscriptItem(id: "q1", role: "user", text: "same", t: 1000)]))
        thread.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r2", items: [
            TranscriptItem(id: "q1", role: "user", text: "same", t: 1000),
            TranscriptItem(id: "q2", role: "user", text: "same", t: 1001)]))
        #expect(thread.items.map(\.id) == ["q1", "q2"])
        #expect(thread.linkedEventKeys.isEmpty, "同文两条不因重排而产生本地关联")
    }
}
