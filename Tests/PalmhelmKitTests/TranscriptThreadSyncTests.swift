import Foundation
import Testing
@testable import PalmhelmKit

// #88 S4 修复：ETag 归属于线程状态（只有采纳的页才有）、临时不可用保留内容、超限时整段淘汰（窗口外、可回看重取）。

private func row(_ id: String) -> TranscriptItem { TranscriptItem(id: id, role: "user", text: "正文 \(id)") }
private func page(_ ids: [String], epoch: String = "e1") -> TranscriptPage {
    TranscriptPage(status: "ok", sessionEpoch: epoch, revision: "r", items: ids.map(row), nextBefore: nil, hasMore: false, partial: false)
}

@Suite struct TranscriptThreadSyncTests {
    @Test func acceptedPageOwnsItsValidatorAndAStaleSnapshotDoesNot() {
        var t = TranscriptThread()
        let accepted = t.applyLatest(page(["a"]), snapshot: t.snapshot, etag: "\"v1\"")
        #expect(accepted)
        #expect(t.validator == "\"v1\"")
        t.invalidate()
        #expect(t.validator == nil, "an invalidated thread must not offer a validator")
        let rejected = t.applyLatest(page(["b"]), snapshot: t.snapshot - 1, etag: "\"v2\"")
        #expect(!rejected)
        #expect(t.latestETag == nil, "a page that the thread refused must not leave a validator behind")
    }

    @Test func transientUnavailableKeepsVerifiedContentAndMarksStale() {
        var t = TranscriptThread()
        t.applyLatest(page(["a"]), snapshot: t.snapshot, etag: "\"v1\"")
        let transient = TranscriptPage(status: "unavailable", sessionEpoch: "e1", revision: nil, items: [], nextBefore: nil, hasMore: false, partial: true, reason: "budget_exceeded")
        let kept = t.applyLatest(transient, snapshot: t.snapshot)
        #expect(!kept)
        #expect(t.items.map(\.id) == ["a"], "a temporary failure must keep the verified content")
        #expect(t.stale)
        let definitive = TranscriptPage(status: "unavailable", sessionEpoch: "e2", revision: nil, items: [], nextBefore: nil, hasMore: false, partial: true, reason: "identity_changed")
        let cleared = t.applyLatest(definitive, snapshot: t.snapshot)
        #expect(cleared)
        #expect(t.items.isEmpty && !t.stale && t.validator == nil)
    }

    // 超限淘汰：最旧的整段（不在窗口内）被移除，并以它的游标指回，回看时可重取。
    @Test func evictionRemovesTheOldestChunkOutsideTheWindowAndKeepsACursor() {
        var t = TranscriptThread()
        t.applyLatest(page((0..<20).map { "h\($0)" }), snapshot: t.snapshot, etag: nil)
        t.applyOlder(page((0..<20).map { "a\($0)" }), snapshot: t.snapshot, cursor: "cursor-a")
        t.applyOlder(page((0..<20).map { "b\($0)" }), snapshot: t.snapshot, cursor: "cursor-b")
        #expect(t.items.count == 60)
        t.showLatestRows() // 载入更早页后窗口会上移到它们；回到最新后最旧的段才在窗口之外
        let freed = t.evictOldestChunk()
        #expect(freed > 0)
        #expect(t.items.count == 40 && t.items.first?.id == "a0")
        #expect(t.nextBefore == "cursor-b" && t.hasMore, "the evicted chunk must be refetchable from its cursor")
        let second = t.evictOldestChunk()
        #expect(second == 0, "a chunk inside the render window must not be evicted")
    }

    // F4：合法 304 清除陈旧标记。
    @Test func markFreshClearsStaleContent() {
        var t = TranscriptThread()
        t.applyLatest(page(["a"]), snapshot: t.snapshot, etag: "\"v1\"")
        t.markStale()
        #expect(t.stale)
        t.markFresh()
        #expect(!t.stale && t.items.map(\.id) == ["a"])
    }

    // 裁剪后的较新内容：自动刷新不替换；回到最新后下一页整体替换。
    @Test func resumeFromLatestRestoresAfterTrim() {
        var t = TranscriptThread()
        t.applyLatest(page((0..<20).map { "h\($0)" }), snapshot: t.snapshot, etag: nil)
        t.applyOlder(page((0..<20).map { "a\($0)" }), snapshot: t.snapshot, cursor: "c-a")
        t.applyOlder(page((0..<20).map { "b\($0)" }), snapshot: t.snapshot, cursor: "c-b")
        #expect(t.trimNewest() > 0 && t.hasNewer)
        let blocked = t.applyLatest(page(["fresh"]), snapshot: t.snapshot)
        #expect(!blocked)
        t.resumeFromLatest()
        let applied = t.applyLatest(page(["fresh"]), snapshot: t.snapshot)
        #expect(applied && !t.hasNewer && t.items.map(\.id) == ["fresh"])
    }

    // R2：裁剪尾部后，身份失效必须清空旧正文（不被 hasNewer 挡住）。
    @Test func identityInvalidationClearsTrimmedHistory() {
        var t = trimmedThread()
        let invalid = TranscriptPage(status: "unavailable", sessionEpoch: nil, revision: nil, items: [], nextBefore: nil, hasMore: false, partial: false, reason: "identity_changed")
        let applied = t.applyLatest(invalid)
        #expect(applied && t.items.isEmpty && !t.hasNewer, "identity invalidation must supersede reading-position preservation")
    }

    // R2：同身份的普通新内容不替换阅读位置；新身份（epoch 变化）的可读页则替换并清除 hasNewer。
    @Test func sameIdentityKeepsPositionButNewIdentityReplaces() {
        var same = trimmedThread()
        #expect(same.applyLatest(page(["fresh"]), snapshot: same.snapshot) == false)
        #expect(same.hasNewer)
        var renamed = trimmedThread()
        let newEpoch = TranscriptPage(status: "ok", sessionEpoch: "e2", revision: "r", items: [TranscriptItem(id: "n", role: "user", text: "新")], nextBefore: nil, hasMore: false, partial: false)
        #expect(renamed.applyLatest(newEpoch) && renamed.items.map(\.id) == ["n"] && !renamed.hasNewer)
    }

    @Test func invalidateClearsTheTrimMarker() {
        var t = trimmedThread()
        t.invalidate()
        #expect(!t.hasNewer)
    }

    // R1 的契约：释放正文会作废本线程发出的票据（快照推进），请求计数保留，由票据归还时扣减。
    @Test func evictingABodyRevokesTicketsAndKeepsCounters() {
        var t = TranscriptThread()
        t.applyLatest(page(["a", "b"]), snapshot: t.snapshot, etag: "\"v\"")
        t.latestInFlight = true
        t.activeRequests = 1
        let ticketSnapshot = t.snapshot
        let freed = t.evictBody()
        #expect(freed > 0 && t.footprintBytes == 0)
        #expect(t.snapshot != ticketSnapshot, "the in-flight ticket must no longer match")
        #expect(t.latestInFlight && t.activeRequests == 1, "counters are returned by the ticket, not cleared by eviction")
    }

    private func page(_ ids: [String]) -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: ids.map { TranscriptItem(id: $0, role: "user", text: $0) }, nextBefore: "c", hasMore: true, partial: false)
    }

    // 4 页，上翻后裁掉尾部：hasNewer 为真。
    private func trimmedThread() -> TranscriptThread {
        var t = TranscriptThread()
        t.applyLatest(page((0..<20).map { "h\($0)" }), snapshot: t.snapshot)
        for i in 0..<3 { t.applyOlder(page((0..<20).map { "o\(i)-\($0)" }), snapshot: t.snapshot, cursor: "c\(i)") }
        t.showOlderRows()
        t.trimNewest()
        return t
    }
}
