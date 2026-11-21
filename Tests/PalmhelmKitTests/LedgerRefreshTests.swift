import Foundation
import Testing
@testable import PalmhelmKit

// #110 A：账本已加载范围的刷新合并；B：账本行与对话页共用当前指令事实。合成数据。

private func cmd(_ key: String, state: String, reason: String? = nil, target: String = "T") -> ApiCommand {
    ApiCommand(key: key, inboxSeq: 1, text: "msg-\(key)", origin: "api", targetId: target, state: state, reason: reason)
}

private func row(_ n: Int, state: String? = nil, source: String = "inbox", target: String = "T") -> TargetHistoryRow {
    let key = "api:d:\(n)"
    let c = source == "inbox" ? cmd(key, state: state ?? "finished", target: target) : nil
    return TargetHistoryRow(id: "\(source):\(key)", source: source, text: "text\(n)", t: n * 10, targetId: source == "inbox" ? target : nil, state: state, command: c)
}

private func page(_ rows: [TargetHistoryRow], next: String? = nil, more: Bool = false, partial: Bool = false) -> TargetHistoryPage {
    TargetHistoryPage(items: rows, nextBefore: next, hasMore: more, partial: partial)
}

/// 已加载三页（服务端页内为时间正序，旧→新）：最新页 [7,8,9]（游标 c1）→ [4,5,6]（c2）→ [1,2,3]（c3，仍有更多）。底部游标 c3。
private func loaded() -> TargetHistoryPaging {
    var p = TargetHistoryPaging()
    p.beginLoad(); p.apply(page([7, 8, 9].map { row($0, state: "started") }, next: "c1", more: true), older: false)
    p.beginLoad(); p.apply(page([4, 5, 6].map { row($0, state: "started") }, next: "c2", more: true), older: true)
    p.beginLoad(); p.apply(page([1, 2, 3].map { row($0, state: "started") }, next: "c3", more: true), older: true)
    return p
}

@Suite struct LedgerRefreshTests {
    @Test func sameIdStateAndCommandUpdateTogetherWithoutMovingTheRow() {
        var p = loaded()
        let before = p.items.map(\.id)
        let page = page([row(7, state: "started"), row(8, state: "started"), row(9, state: "unknown")], next: "x", more: true)
        p.mergeRefresh(page, anchorID: "inbox:api:d:1")
        let r9 = p.items.first { $0.id == "inbox:api:d:9" }!
        #expect(r9.state == "unknown" && r9.command?.state == "unknown", "state and command are replaced as one pair")
        #expect(p.items.map(\.id) == before, "order and membership stay put")
        #expect(r9.text == "text9" && r9.t == 90)
        #expect(p.nextBefore == "c3" && p.hasMore, "the bottom cursor survives the refresh")
    }

    @Test func repeatedIdenticalPageIsAnIdempotentNoOp() {
        var p = loaded()
        let pg = page([row(9, state: "unknown")], next: "x", more: true)
        p.mergeRefresh(pg, anchorID: "inbox:api:d:1")
        let once = p
        p.mergeRefresh(pg, anchorID: "inbox:api:d:1")
        #expect(p == once)
    }

    @Test func identityConflictKeepsTheOriginalRow() {
        var p = loaded()
        var changed = row(9, state: "unknown")
        changed.text = "different body"
        var moved = row(8, state: "unknown")
        moved.t = 999
        var other = row(7, state: "unknown")
        other.targetId = "other"
        p.mergeRefresh(page([changed, moved, other], next: "x", more: true), anchorID: "inbox:api:d:1")
        #expect(p.items.filter { ["inbox:api:d:9", "inbox:api:d:8", "inbox:api:d:7"].contains($0.id) }.allSatisfy { $0.state == "started" && $0.command?.state == "started" })
        #expect(p.items.first { $0.id == "inbox:api:d:9" }?.text == "text9")
    }

    @Test func rowWithoutCommandDoesNotEraseAKnownOne() {
        var p = loaded()
        var stripped = row(9, state: "unknown")
        stripped.command = nil
        p.mergeRefresh(page([stripped], next: "x", more: true), anchorID: "inbox:api:d:1")
        let r = p.items.first { $0.id == "inbox:api:d:9" }!
        #expect(r.state == "started" && r.command?.state == "started", "state and command stay a consistent pair")
    }

    @Test func newRowsAboveTheCachedRangeAreAddedInTimeOrder() {
        var p = loaded()
        // 头部新增 12、11、10 与已缓存的 9：新行进入，已缓存的更新。
        p.mergeRefresh(page([row(9, state: "unknown"), row(10), row(11), row(12)], next: "n1", more: true), anchorID: "inbox:api:d:1")
        #expect(p.items.map(\.id).suffix(4) == ["inbox:api:d:9", "inbox:api:d:10", "inbox:api:d:11", "inbox:api:d:12"])
        #expect(p.items.count == 12)
    }

    @Test func anchorPageAddsNothingOlderThanTheAnchorButStillRefreshesCachedRows() {
        var p = loaded()
        // 锚 = 最旧缓存行 1。真实 wire 页序（时间正序，旧→新）：[0(更旧的新行), 1(锚), 2(已缓存)]
        let anchorPage = page([row(0), row(1, state: "unknown"), row(2, state: "unknown")], next: "c4", more: true)
        let hit = p.mergeRefresh(anchorPage, anchorID: "inbox:api:d:1")
        #expect(hit)
        #expect(!p.items.contains { $0.id == "inbox:api:d:0" }, "nothing older than the anchor is added")
        #expect(p.items.first?.id == "inbox:api:d:1" && p.items.first?.state == "unknown")
        #expect(p.nextBefore == "c3", "the original bottom cursor is kept so no history is skipped")
    }

    // R1 反例：缓存 [r1, r3]、截止锚 r1；真实升序页 [r0, r1, r2]：只应新增较新的 r2，不能收进更旧的 r0。
    @Test func anchorInTheMiddleAddsTheNewerMissingRowAndNotTheOlderOne() {
        var p = TargetHistoryPaging()
        p.beginLoad()
        p.apply(page([row(1), row(3)], next: "c", more: true), older: false)
        let hit = p.mergeRefresh(page([row(0), row(1), row(2)], next: "d", more: true), anchorID: "inbox:api:d:1")
        #expect(hit)
        #expect(p.items.map(\.id) == ["inbox:api:d:1", "inbox:api:d:2", "inbox:api:d:3"])
        #expect(p.nextBefore == "c")
    }

    // 同时间戳的行按 wire 位置判方向，不按自行排序的时间：r2 与锚同 t，位于锚之后 → 接纳；r0 同 t 位于锚之前 → 不接纳。
    @Test func sameTimestampRowsFollowTheirWirePositionRelativeToTheAnchor() {
        func same(_ n: Int) -> TargetHistoryRow { var r = row(n); r.t = 500; return r }
        var p = TargetHistoryPaging()
        p.beginLoad()
        p.apply(page([same(1)], next: "c", more: true), older: false)
        p.mergeRefresh(page([same(0), same(1), same(2)], next: "d", more: true), anchorID: "inbox:api:d:1")
        #expect(p.items.map(\.id) == ["inbox:api:d:1", "inbox:api:d:2"])
    }

    // R3：普通续页（older apply）也更新重叠行的状态，保留游标 / partial 语义；冲突与缺 command 规则与刷新同一份。
    @Test func olderPageUpdatesOverlappingRowsAndKeepsCursorSemantics() {
        var p = loaded()
        p.beginLoad()
        var conflict = row(5, state: "unknown")
        conflict.text = "changed body"
        p.apply(page([row(3, state: "unknown"), conflict, row(0)], next: "c4", more: true), older: true)
        #expect(p.items.first { $0.id == "inbox:api:d:3" }?.command?.state == "unknown", "an overlapping row takes the fresher state")
        #expect(p.items.first { $0.id == "inbox:api:d:5" }?.state == "started" && p.items.first { $0.id == "inbox:api:d:5" }?.text == "text5", "identity conflict is not overwritten")
        #expect(p.items.first?.id == "inbox:api:d:0")
        #expect(p.nextBefore == "c4" && p.hasMore && p.loaded && !p.loading)
        var stripped = row(2, state: "unknown")
        stripped.command = nil
        p.beginLoad()
        p.apply(page([stripped], next: "c5", more: true), older: true)
        #expect(p.items.first { $0.id == "inbox:api:d:2" }?.command?.state == "started", "a row without command never clears a known command")
        // 空 partial 计数仍按原语义推进。
        p.beginLoad()
        p.apply(page([], next: "c6", more: true, partial: true), older: true)
        #expect(p.shouldContinue)
    }

    @Test func refreshWalksUntilTheAnchorPageAndFillsAGapOfMoreThanOnePage() {
        var p = loaded()
        var run = TargetHistoryRefresh(anchorID: "inbox:api:d:1")
        let pages: [String?: TargetHistoryPage] = [
            nil: page([row(13), row(14), row(15)], next: "n1", more: true),
            "n1": page([row(10), row(11), row(12)], next: "n2", more: true),
            "n2": page([row(7), row(8), row(9, state: "unknown")], next: "n3", more: true),
            "n3": page([row(4), row(5), row(6)], next: "n4", more: true),
            "n4": page([row(1, state: "unknown"), row(2), row(3)], next: "n5", more: true),
        ]
        var before: String? = nil
        var requests: [String?] = []
        while true {
            requests.append(before)
            let out = run.accept(pages[before]!, requestedBefore: before, into: &p)
            if case .more(let next) = out { before = next } else { #expect(out == .complete); break }
        }
        #expect(requests == [nil, "n1", "n2", "n3", "n4"])
        #expect(p.items.count == 15 && p.items.compactMap(\.t) == p.items.compactMap(\.t).sorted(), "no gap between the new head and the cache")
        #expect(p.items.first { $0.id == "inbox:api:d:9" }?.state == "unknown")
        #expect(p.nextBefore == "c3" && p.hasMore)
    }

    @Test func missingAnchorEndsOnlyWhenTheServerIsExhaustedAndKeepsCachedRows() {
        var p = loaded()
        var run = TargetHistoryRefresh(anchorID: "inbox:api:d:1")
        _ = run.accept(page([row(8), row(9)], next: "n1", more: true), requestedBefore: nil, into: &p)
        let out = run.accept(page([row(7)], next: nil, more: false), requestedBefore: "n1", into: &p)
        #expect(out == .complete)
        #expect(p.items.count == 9, "cached rows are never removed")
    }

    @Test func repeatedOrEchoedCursorStopsTheRound() {
        var p = loaded()
        var run = TargetHistoryRefresh(anchorID: "inbox:api:d:1")
        #expect(run.accept(page([row(9)], next: "n1", more: true), requestedBefore: nil, into: &p) == .more(before: "n1"))
        #expect(run.accept(page([row(8)], next: "n1", more: true), requestedBefore: "n1", into: &p) == .incomplete, "same cursor as the request")
        var run2 = TargetHistoryRefresh(anchorID: "inbox:api:d:1")
        _ = run2.accept(page([row(9)], next: "a", more: true), requestedBefore: nil, into: &p)
        _ = run2.accept(page([row(8)], next: "b", more: true), requestedBefore: "a", into: &p)
        #expect(run2.accept(page([row(7)], next: "a", more: true), requestedBefore: "b", into: &p) == .incomplete, "an earlier cursor reappearing")
        var run3 = TargetHistoryRefresh(anchorID: "inbox:api:d:1")
        #expect(run3.accept(page([row(9)], next: nil, more: true), requestedBefore: nil, into: &p) == .incomplete, "hasMore without a cursor")
    }

    @Test func consecutiveEmptyPartialsStopAtTheCap() {
        var p = loaded()
        var run = TargetHistoryRefresh(anchorID: "inbox:api:d:1")
        var before: String? = nil
        var last = TargetHistoryRefresh.Outcome.complete
        for i in 0...TargetHistoryPaging.maxEmptyPartials {
            last = run.accept(page([], next: "p\(i)", more: true, partial: true), requestedBefore: before, into: &p)
            before = "p\(i)"
            if i < TargetHistoryPaging.maxEmptyPartials { #expect(last == .more(before: "p\(i)")) }
        }
        #expect(last == .incomplete)
    }

    // B：账本行状态

    private func live(_ c: ApiCommand) -> MessageStatus { MessageStatusRules.status(for: c, phase: .unknown) }

    @Test func currentCommandOverridesTheStaleLedgerSnapshot() {
        let stale = row(5, state: "started")
        let now = cmd("api:d:5", state: "unknown")
        let ms = MessageStatusRules.ledger(row: stale, scopeTarget: "T", current: now, live: live)
        #expect(ms?.phase == .unknown, "same key and target: the live evaluation wins over the cached started")
        #expect(MessageStatusRules.standalone(stale.command!).phase != .unknown, "control: the stale snapshot alone says something else")
    }

    @Test func withoutACurrentCommandOnlyTheCachedCommandIsEvaluatedStandalone() {
        let r = row(5, state: "finished")
        #expect(MessageStatusRules.ledger(row: r, scopeTarget: "T", current: nil, live: { _ in Issue.record("live must not be consulted"); return MessageStatus(phase: .unknown, label: "") }) == MessageStatusRules.standalone(r.command!))
    }

    @Test func otherTargetOrKeyIsNeverBorrowed() {
        let r = row(5, state: "started")
        // 当前指令 key 不同、或目标不同：不借。
        let otherKey = cmd("api:d:6", state: "unknown")
        let otherTarget = cmd("api:d:5", state: "unknown", target: "U")
        #expect(MessageStatusRules.ledger(row: r, scopeTarget: "T", current: otherKey, live: live) == MessageStatusRules.standalone(r.command!))
        #expect(MessageStatusRules.ledger(row: r, scopeTarget: "T", current: otherTarget, live: live) == MessageStatusRules.standalone(r.command!))
        // 账本行属于别的目标：整行不参与。
        #expect(MessageStatusRules.ledger(row: r, scopeTarget: "U", current: nil, live: live) == nil)
    }

    @Test func outboxAndOldFormatRowsGetNoStatus() {
        let ob = row(5, source: "outbox")
        #expect(MessageStatusRules.ledger(row: ob, scopeTarget: "T", current: nil, live: live) == nil)
        let noCmd = TargetHistoryRow(id: "inbox:x", source: "inbox", text: "t", t: 1, targetId: "T", state: "finished")
        #expect(MessageStatusRules.ledger(row: noCmd, scopeTarget: "T", current: cmd("x", state: "unknown"), live: live) == nil)
    }
}

// 请求槽：物理串行与刷新合并（R2）。
@MainActor
@Suite struct HistoryRequestSlotTests {
    @Test func secondRequestWaitsUntilTheFirstReleases() async {
        let slot = HistoryRequestSlot()
        var order: [String] = []
        await slot.acquire()
        let waiter = Task { @MainActor in
            await slot.acquire()
            order.append("second")
            slot.release()
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(order.isEmpty, "the second request must not start while the first holds the slot")
        order.append("first")
        slot.release()
        await waiter.value
        #expect(order == ["first", "second"])
    }

    @Test func aSucceededRefreshSatisfiesOnlyRequestsRegisteredBeforeItStarted() {
        let slot = HistoryRequestSlot()
        let a = slot.registerRefresh()
        let b = slot.registerRefresh()
        let started = slot.refreshStarted()
        let late = slot.registerRefresh()
        #expect(!slot.refreshSatisfied(a) && !slot.refreshSatisfied(b), "nothing is satisfied before a refresh succeeds")
        slot.refreshSucceeded(startedAt: started)
        #expect(slot.refreshSatisfied(a) && slot.refreshSatisfied(b), "registered before the successful refresh started")
        #expect(!slot.refreshSatisfied(late), "a request registered after the refresh started still needs its own round")
    }
}
