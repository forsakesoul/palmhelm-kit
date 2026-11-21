import Testing
import Foundation
@testable import PalmhelmKit

// 2a 契约（docs/ops/local-api.md §8a）：页、条目、回执与 transcript_changed 事件的解码。
@Suite struct TranscriptTests {
    @Test func decodesPage() throws {
        let json = """
        {"status":"ok","sessionEpoch":"e1","revision":"r9","items":[
          {"id":"a","role":"user","text":"修完提交一下","t":1760000000000,"truncated":false,"receipt":{"commandKey":"k1","origin":"api","receiptState":"done"}},
          {"id":"b","role":"assistant","text":"已修复并提交","truncated":true,"projected":true},
          {"id":"c","role":"gap","text":"这条记录无法解析","truncated":false}
        ],"nextBefore":"cur","hasMore":true,"partial":false}
        """
        let p = try JSONDecoder().decode(TranscriptPage.self, from: Data(json.utf8))
        #expect(p.isAvailable && p.hasMore && p.nextBefore == "cur")
        #expect(p.items.map(\.role) == ["user", "assistant", "gap"])
        #expect(p.items[0].receipt == TranscriptReceipt(commandKey: "k1", origin: "api", receiptState: "done"))
        #expect(TranscriptReceiptState(rawValue: p.items[0].receipt!.receiptState)?.label == "已执行")
        #expect(p.items[1].truncated && p.items[1].projected == true && p.items[1].receipt == nil)
    }

    @Test func unavailableIsNotEmptyConversation() throws {
        let p = try JSONDecoder().decode(TranscriptPage.self, from: Data(#"{"status":"unavailable","items":[],"hasMore":false,"partial":true}"#.utf8))
        #expect(!p.isAvailable && p.partial && p.sessionEpoch == nil)
    }

    @Test func decodesChangeEvent() {
        let f = SSEFrame(id: nil, event: "transcript_changed", data: #"{"targetId":"t1","sessionEpoch":"e1","revision":"r2","kind":"append"}"#)
        #expect(BridgeEventDecoder.decode(f) == .transcriptChanged(TranscriptChange(targetId: "t1", sessionEpoch: "e1", revision: "r2", kind: "append")))
        #expect(TranscriptChangeKind(rawValue: "reset") == .reset)
        let bad = SSEFrame(id: nil, event: "transcript_changed", data: #"{"targetId":"t1"}"#)
        #expect(BridgeEventDecoder.decode(bad) == .unknown(name: "transcript_changed"))
    }

    @Test func transcriptPathEncodesTargetId() throws {
        let ep = BridgeEndpoint(host: "127.0.0.1", port: 1, transport: .http)
        let u = try ep.url(BridgeAPI.Path.targets + "/" + "a b/c".addingPercentEncoding(withAllowedCharacters: { var s = CharacterSet.urlPathAllowed; s.remove(charactersIn: "/"); return s }())! + BridgeAPI.Path.transcriptSuffix, query: [URLQueryItem(name: "limit", value: "20")], percentEncoded: true)
        #expect(u.absoluteString == "http://127.0.0.1:1/v1/targets/a%20b%2Fc/transcript?limit=20")
    }
}

@Suite struct TranscriptThreadTests {
    private func item(_ id: String, _ role: String = "assistant", text: String? = nil, receipt: TranscriptReceipt? = nil) -> TranscriptItem { TranscriptItem(id: id, role: role, text: text ?? id, receipt: receipt) }
    private func page(_ ids: [String], epoch: String = "e1", rev: String, next: String? = nil, more: Bool = false) -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: epoch, revision: rev, items: ids.map { item($0) }, nextBefore: next, hasMore: more)
    }

    @Test func firstLoadThenAppendOnlyAddsUnknownTail() {
        var t = TranscriptThread()
        t.applyLatest(page(["a", "b"], rev: "1", next: "c1", more: true))
        #expect(t.status == .ok && t.items.map(\.id) == ["a", "b"] && t.hasMore && t.nextBefore == "c1")
        t.applyLatest(page(["b", "c"], rev: "2", next: "c2", more: true))
        #expect(t.items.map(\.id) == ["a", "b", "c"], "重叠时只接新尾部，不丢已翻到的旧页")
        #expect(t.nextBefore == "c1", "游标仍指向已翻到的最早处")
        t.applyLatest(page(["b", "c"], rev: "2", next: "c2", more: true))
        #expect(t.items.count == 3, "再次并入同一页不重复")
    }

    @Test func knownItemsAreRefreshedNotDuplicated() {
        // A1-121 F1：文件原地改写后 id 可能不变；回执来自命令库，文件 revision 相同也可能变化
        var t = TranscriptThread()
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "1", items: [item("u", "user", text: "x", receipt: .init(commandKey: "k", origin: "api", receiptState: "sent")), item("a", text: "OLD")]))
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "1", items: [item("u", "user", text: "x", receipt: .init(commandKey: "k", origin: "api", receiptState: "done")), item("a", text: "NEW")]))
        #expect(t.items.map(\.text) == ["x", "NEW"] && t.items[0].receipt?.receiptState == "done" && t.items.count == 2)
    }

    @Test func invalidateThenLatestReplacesWholeSnapshot() {
        var t = TranscriptThread()
        t.applyLatest(page(["a"], rev: "1", next: "p", more: true))
        t.invalidate()
        #expect(!t.atStart && t.items.map(\.id) == ["a"], "失效期间保留旧内容，也不冒充已到开头")
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "2", items: [item("a", text: "NEW")], hasMore: false))
        #expect(t.items.map(\.text) == ["NEW"] && t.atStart && t.nextBefore == nil, "reset 后同 epoch 也整体替换：旧游标不保留")
    }

    @Test func noOverlapOrNewSessionReplaces() {
        var t = TranscriptThread()
        t.applyLatest(page(["a"], rev: "1"))
        t.applyLatest(page(["x", "y"], rev: "5", next: "n", more: true))
        #expect(t.items.map(\.id) == ["x", "y"] && t.nextBefore == "n", "最新页一条都不认识：中间可能漏了，整体重来")
        t.applyLatest(page(["z"], epoch: "e2", rev: "1"))
        #expect(t.items.map(\.id) == ["z"] && t.sessionEpoch == "e2" && t.atStart)
    }

    @Test func olderPagePrependsAndEmptyPartialStillAdvances() {
        var t = TranscriptThread()
        t.applyLatest(page(["c"], rev: "1", next: "p1", more: true))
        let snap = t.snapshot
        t.loadingOlder = true
        t.applyOlder(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "1", items: [], nextBefore: "p2", hasMore: true, partial: true), snapshot: snap)
        #expect(!t.loadingOlder && t.nextBefore == "p2" && t.items.count == 1)
        t.applyOlder(page(["a", "b"], rev: "1", next: nil, more: false), snapshot: snap)
        #expect(t.items.map(\.id) == ["a", "b", "c"] && t.atStart)
        t.applyOlder(page(["q"], epoch: "e9", rev: "1"), snapshot: snap)
        #expect(t.items.map(\.id) == ["a", "b", "c"], "会话已换的旧页不并入")
    }

    @Test func staleOlderPageIsDroppedAfterSnapshotChange() {
        // A1-121 F2：翻页在途时最新页整体替换，迟到的旧页不能拼到新链前面；busy 随替换归还
        var t = TranscriptThread()
        t.applyLatest(page(["old-head"], rev: "1", next: "p", more: true))
        let snap = t.snapshot
        t.loadingOlder = true
        t.applyLatest(page(["new-chain"], rev: "9"))
        #expect(!t.loadingOlder && t.snapshot != snap)
        t.applyOlder(page(["older"], rev: "1"), snapshot: snap)
        #expect(t.items.map(\.id) == ["new-chain"])
        t.loadingOlder = true
        t.olderFailed(snapshot: snap)
        #expect(t.loadingOlder, "旧快照的失败不清新快照的 busy")
        t.olderFailed(snapshot: t.snapshot)
        #expect(!t.loadingOlder)
    }

    @Test func staleLatestDoesNotConsumeInvalidation() {
        // A1-123 F1-R：reset 发生在 latest 在途时，迟到的旧页不能清掉失效标记、不能装回旧游标；补拉的新页整体替换
        var t = TranscriptThread()
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "1", items: [item("a", text: "OLD")], nextBefore: "tail", hasMore: true))
        let snapAtStart = t.snapshot
        t.invalidate()
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "1", items: [item("a", text: "OLD")], nextBefore: "stale-cursor", hasMore: true), snapshot: snapAtStart)
        #expect(t.needsReplace && t.dirty && t.nextBefore == nil, "旧响应被丢弃并要求补拉")
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "2", items: [item("a", text: "NEW")], hasMore: false), snapshot: t.snapshot)
        #expect(t.items.map(\.text) == ["NEW"] && t.nextBefore == nil && !t.hasMore && t.atStart)
    }

    @Test func abandonRequestsReturnsBusyFlags() {
        // A1-121 F3：断流换代次时归还在途标记，否则按钮一直禁用
        var t = TranscriptThread()
        t.applyLatest(page(["a"], rev: "1", next: "p", more: true))
        t.loadingOlder = true; t.latestInFlight = true; t.dirty = true; t.activeRequests = 2
        #expect(!t.canStartRequest)
        t.abandonRequests()
        #expect(!t.loadingOlder && !t.latestInFlight && !t.dirty && t.activeRequests == 0 && t.items.count == 1)
    }

    @Test func unavailableClears() {
        var t = TranscriptThread()
        t.applyLatest(page(["a"], rev: "1", next: "p", more: true))
        t.applyLatest(TranscriptPage(status: "unavailable", partial: true))
        #expect(t.status == .unavailable && t.items.isEmpty && !t.hasMore && !t.atStart)
    }
}

@Suite struct TranscriptCopyTests {
    @Test func sourceLineDistinguishesPalmhelmFeishuAndTerminal() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let ms = 1_760_000_000_000
        let reins = TranscriptItem(id: "a", role: "user", text: "x", t: ms, receipt: .init(commandKey: "k", origin: "api", receiptState: "done", eventKey: "k"))
        let linked = ApiCommand(key: "k", inboxSeq: 1, text: "x", origin: "api", state: "finished")
        #expect(TranscriptCopy.sourceLine(reins, command: linked, now: now).hasPrefix("经 Palmhelm · 已完成 · 今天 "))
        #expect(TranscriptCopy.sourceLine(reins, now: now).hasPrefix("经 Palmhelm · 已完成 · 今天 "), "未关联的普通 done 保持已完成（C2'）")
        let unknown = TranscriptItem(id: "u", role: "user", text: "x", t: ms, receipt: .init(commandKey: "k", origin: "api", receiptState: "unknown", eventKey: "k"))
        #expect(TranscriptCopy.sourceLine(unknown, now: now).hasPrefix("经 Palmhelm · 结果未知 · 今天 "), "原生回执未关联：结果未知")
        let native = ApiCommand(key: "k", inboxSeq: 1, text: "x", origin: "api", state: "finished", reason: "native_delivered")
        #expect(TranscriptCopy.sourceLine(reins, command: native, now: now).hasPrefix("经 Palmhelm · 已送达工作中终端，尚未确认并入本轮 · 今天 "))
        let feishu = TranscriptItem(id: "b", role: "user", text: "x", receipt: .init(commandKey: "k", origin: "feishu", receiptState: "sent"))
        #expect(TranscriptCopy.sourceLine(feishu, now: now) == "经飞书 · 已送达")
        #expect(TranscriptCopy.sourceLine(feishu, agentWorking: true, now: now) == "经飞书 · 已送达", "目标忙不改写本条的阶段")
        let merged = TranscriptItem(id: "m", role: "user", text: "x", receipt: .init(commandKey: "k", origin: "api", receiptState: "sent", reason: "merged"))
        #expect(TranscriptCopy.sourceLine(merged, now: now, locale: zhHansLocale) == "经 Palmhelm · 已并入当前回合", "并入只出现在状态里，不另起一行")
        let terminal = TranscriptItem(id: "c", role: "user", text: "x", t: ms - 86_400_000 * 3)
        let s = TranscriptCopy.sourceLine(terminal, now: now)
        #expect(s.hasPrefix("在终端输入 · ") && !s.contains("今天"))
        #expect(TranscriptCopy.startMarker(firstT: nil) == "已到本次会话开头")
    }
}

@Suite struct TranscriptLinkedKeysTests {
    private func item(_ id: String, key: String?) -> TranscriptItem {
        TranscriptItem(id: id, role: "user", text: id, receipt: key.map { TranscriptReceipt(commandKey: $0, origin: "api", receiptState: "done", eventKey: $0) })
    }
    private func page(_ items: [TranscriptItem], epoch: String = "e1") -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: epoch, revision: "r", items: items)
    }

    // H2-3：原生代次有证据地切换时，已关联集合按新页重算（三个页入口一致）；同代次的任何并入 / 替换保持单调。
    @Test func nativeEpochChangeResetsLinkedKeysOnEveryPageEntry() {
        var a = TranscriptThread()
        a.applyLatest(page([item("x", key: "old")]))
        a.applyLatest(page([item("y", key: "new")], epoch: "e2"))
        #expect(a.linkedEventKeys == ["new"], "applyLatest 换代：旧代次的关联不跨会话")

        var b = TranscriptThread()
        b.applyLatest(page([item("x", key: "old")]))
        b.replaceWithLatest(page([item("y", key: "new")], epoch: "e2"))
        #expect(b.linkedEventKeys == ["new"], "replaceWithLatest 换代")

        var c = TranscriptThread()
        c.applyLatest(page([item("x", key: "old")]))
        let located = c.applyLocated(page([item("y", key: "new")], epoch: "e2"), itemId: "y")
        #expect(located && c.linkedEventKeys == ["new"], "applyLocated 换代")
    }

    @Test func sameEpochKeepsLinkedKeysAcrossPageReplacementAndLocate() {
        var t = TranscriptThread()
        t.applyLatest(page([item("x", key: "k1")]))
        t.replaceWithLatest(page([item("z", key: nil)]))
        #expect(t.linkedEventKeys == ["k1"], "同代次整页替换不丢已关联")
        t.applyLocated(page([item("w", key: nil)]), itemId: "w")
        #expect(t.linkedEventKeys == ["k1"], "同代次定位不丢已关联")
    }

    // H3-1：暂不可读（无代次）不是换代证据；已知代次 e1 → 未知 → e1 保留关联，→ e2 才重置。
    @Test func sameEpochRecoveryAfterUnavailableKeepsLinkedKeys() {
        var t = TranscriptThread()
        t.applyLatest(page([item("x", key: "k1")]))
        t.applyLatest(TranscriptPage(status: "unavailable"))
        #expect(t.linkedEventKeys == ["k1"], "暂不可读不清关联")
        t.applyLatest(page([item("y", key: nil)]))
        #expect(t.linkedEventKeys == ["k1"], "同代次恢复不当换代")
    }

    @Test func differentEpochAfterUnavailableResetsLinkedKeys() {
        var t = TranscriptThread()
        t.applyLatest(page([item("x", key: "k1")]))
        t.applyLatest(TranscriptPage(status: "unavailable"))
        t.applyLatest(page([item("y", key: "new")], epoch: "e2"))
        #expect(t.linkedEventKeys == ["new"], "恢复后代次不同：原子重置并收集新页")
    }
}
