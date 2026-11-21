import Foundation
import Testing
@testable import PalmhelmKit

// 回执后补关联（A2-000 §3）：wire 解码、声明规范化、补丁采纳规则、ETag 形状、更早页刷新。

private func user(_ id: String, receipt: TranscriptReceipt? = nil) -> TranscriptItem { TranscriptItem(id: id, role: "user", text: "正文 \(id)", receipt: receipt) }
private func asst(_ id: String) -> TranscriptItem { TranscriptItem(id: id, role: "assistant", text: "答 \(id)") }
private func rc(_ key: String, cmd: String = "c1", state: String = "sent") -> TranscriptReceipt { TranscriptReceipt(commandKey: cmd, origin: "api", receiptState: state, eventKey: key) }
private func page(_ items: [TranscriptItem], epoch: String = "E", updates: [TranscriptReceiptUpdate]? = nil, hasMore: Bool = false, next: String? = nil) -> TranscriptPage {
    TranscriptPage(status: "ok", sessionEpoch: epoch, revision: "r", items: items, nextBefore: next, hasMore: hasMore, partial: false, receiptUpdates: updates)
}
private func upd(_ id: String, _ key: String, cmd: String = "c1") -> TranscriptReceiptUpdate { TranscriptReceiptUpdate(itemId: id, receipt: rc(key, cmd: cmd)) }
private func req(_ keys: String..., epoch: String = "E") -> TranscriptReceiptRequest { TranscriptReceiptRequest(sessionEpoch: epoch, eventKeys: keys)! }
private func loaded(_ items: [TranscriptItem]) -> TranscriptThread {
    var t = TranscriptThread()
    _ = t.applyLatest(page(items), snapshot: t.snapshot)
    return t
}

@Suite struct TranscriptReceiptBackfillTests {
    // 冻结示例的 wire 形状（A2-000 §1）与旧 payload
    @Test func decodesTheFrozenShapeAndOldPayloads() throws {
        let json = #"{"status":"ok","sessionEpoch":"E","revision":"R","items":[{"id":"A","role":"user","text":"x","truncated":false}],"hasMore":true,"partial":false,"receiptUpdates":[{"itemId":"A","receipt":{"commandKey":"ck","origin":"api","receiptState":"sent","eventKey":"K"}}]}"#
        let p = try JSONDecoder().decode(TranscriptPage.self, from: Data(json.utf8))
        #expect(p.receiptUpdates == [TranscriptReceiptUpdate(itemId: "A", receipt: TranscriptReceipt(commandKey: "ck", origin: "api", receiptState: "sent", eventKey: "K"))])
        let old = try JSONDecoder().decode(TranscriptPage.self, from: Data(#"{"status":"ok","items":[],"hasMore":false,"partial":false}"#.utf8))
        #expect(old.receiptUpdates == nil)
    }

    @Test func requestNormalizesDedupesSortsAndCaps() {
        let r = TranscriptReceiptRequest(sessionEpoch: "E", eventKeys: ["b", "a", "b", "", "bad\u{7}key", String(repeating: "x", count: 257)])!
        #expect(r.eventKeys == ["a", "b"])
        let many = (0..<25).map { String(format: "k%02d", $0) }
        let capped = TranscriptReceiptRequest(sessionEpoch: "E", eventKeys: many)!
        #expect(capped.eventKeys.count == 20)
        #expect(capped.eventKeys.first == "k05" && capped.eventKeys.last == "k24", "keep the most recent 20, ordered by bytes")
        #expect(TranscriptReceiptRequest(sessionEpoch: "", eventKeys: ["a"]) == nil)
        #expect(TranscriptReceiptRequest(sessionEpoch: "E", eventKeys: []) == nil)
        #expect(req("b", "a") == req("a", "b"), "same set, same shape")
        let q = req("b", "a").queryItems.map { "\($0.name)=\($0.value ?? "")" }
        #expect(q == ["receiptEpoch=E", "receiptEventKey=a", "receiptEventKey=b"])
    }

    @Test func selectionTakesOnlyUnlinkedKeysOfTheCurrentEpoch() {
        let sent: [(eventKey: String?, sessionEpoch: String?)] = [("old", "E"), (nil, "E"), ("other", "F"), ("unbound", nil), ("linked", "E"), ("new", "E")]
        let r = TranscriptReceiptRequest.select(epoch: "E", linked: ["linked"], sent: sent)
        #expect(r?.eventKeys == ["new", "old"])
        #expect(TranscriptReceiptRequest.select(epoch: nil, linked: [], sent: sent) == nil)
        #expect(TranscriptReceiptRequest.select(epoch: "E", linked: ["old", "linked", "new"], sent: sent) == nil)
    }

    // #110 C：补行 key 进声明——不带原 epoch、排在普通发送与优先回显之后（最近最靠后）；重复只留一份；linked 不进；总上限 20
    @Test func supplementKeysJoinTheClaimAfterSendsAndKeepTheMostRecent() {
        let sent: [(eventKey: String?, sessionEpoch: String?)] = [("s1", "E"), ("s-old", "F")]
        let r = TranscriptReceiptRequest.select(epoch: "E", linked: ["done"], sent: sent, preferred: ["s1"], supplementKeys: ["c1", "done", "s1", "c2"])
        #expect(r?.eventKeys == ["c1", "c2", "s1"], "s1 重复只一份，done 已关联不进，其它代次的 s-old 不进")
        #expect(TranscriptReceiptRequest.select(epoch: "E", linked: [], sent: [], supplementKeys: ["c1"])?.eventKeys == ["c1"], "没有本机发送也能声明")
        #expect(TranscriptReceiptRequest.select(epoch: nil, linked: [], sent: [], supplementKeys: ["c1"]) == nil, "没有当前 epoch 不声明")
        #expect(TranscriptReceiptRequest.select(epoch: "E", linked: ["c1"], sent: [], supplementKeys: ["c1"]) == nil)
        let ordinary = (0..<20).map { (eventKey: Optional("o\(String(format: "%02d", $0))"), sessionEpoch: Optional("E")) }
        let supp = (0..<22).map { String(format: "c%02d", $0) }
        let capped = TranscriptReceiptRequest.select(epoch: "E", linked: [], sent: ordinary, supplementKeys: supp)
        #expect(capped?.eventKeys.count == 20)
        #expect(capped?.eventKeys == Array(supp.suffix(20)), "补行本身超过 20 取最近 20，普通发送被挤出")
        let mixed = TranscriptReceiptRequest.select(epoch: "E", linked: [], sent: ordinary, supplementKeys: ["c1", "c2"])
        #expect(mixed?.eventKeys.filter { $0.hasPrefix("c") } == ["c1", "c2"] && mixed?.eventKeys.count == 20, "补行占最近的名额")
    }

    @Test func supplementKeysComeOnlyFromUnlinkedApiRowsOfThisTarget() {
        func c(_ key: String, _ seq: Int, target: String? = "t", origin: String = "api") -> ApiCommand {
            var x = ApiCommand(key: key, inboxSeq: seq, text: "t", origin: origin, state: "unknown", lane: "ordinary"); x.targetId = target; return x
        }
        let rows = [c("b", 3), c("a", 1), c("feishu", 2, origin: "feishu"), c("other", 4, target: "u"), c("linked", 5), c("none", 6, target: nil)]
        #expect(TranscriptReceiptRequest.supplementKeys(commandRows: rows, targetId: "t", linked: ["linked"]) == ["a", "b"])
        #expect(TranscriptReceiptRequest.supplementKeys(commandRows: [], targetId: "t", linked: []).isEmpty)
    }

    // 调用例：A(无 receipt) + B(K)：补丁只改 A 的 receipt 并累积 K，正文/顺序不变；重复应用幂等
    @Test func patchLinksTheLoadedItemAndAccumulatesTheKey() {
        var t = loaded([user("A"), asst("B")])
        let p = page([asst("B")], updates: [upd("A", "K")])
        #expect(t.applyReceiptUpdates(p, request: req("K"), snapshot: t.snapshot) == 1)
        #expect(t.items.map(\.id) == ["A", "B"] && t.items[0].text == "正文 A")
        #expect(t.items[0].receipt?.eventKey == "K")
        #expect(t.linkedEventKeys == ["K"])
        #expect(t.applyReceiptUpdates(p, request: req("K"), snapshot: t.snapshot) == 0, "same value is a no-op")
    }

    @Test func rejectsEverythingThatIsNotAnExactLegitimateUpdate() {
        func run(_ updates: [TranscriptReceiptUpdate]?, request: TranscriptReceiptRequest? = req("K"), epoch: String = "E", mutate: (inout TranscriptThread) -> Void = { _ in }) -> TranscriptThread {
            var t = loaded([user("A"), asst("B")]); mutate(&t)
            t.applyReceiptUpdates(page([asst("B")], epoch: epoch, updates: updates), request: request, snapshot: t.snapshot)
            return t
        }
        #expect(run([upd("ZZ", "K")]).linkedEventKeys.isEmpty, "unknown item id never records the key")
        #expect(run([upd("ZZ", "K")]).items.count == 2, "and never creates a row")
        #expect(run([upd("B", "K")]).linkedEventKeys.isEmpty, "assistant items are not eligible")
        #expect(run([upd("A", "NOT-REQUESTED")]).linkedEventKeys.isEmpty, "key must belong to this request")
        #expect(run([upd("A", "K")], request: nil).linkedEventKeys.isEmpty)
        #expect(run([upd("A", "K")], epoch: "F").linkedEventKeys.isEmpty, "stale/other epoch response")
        #expect(run([upd("A", "K")], request: req("K", epoch: "F")).linkedEventKeys.isEmpty, "request epoch != thread epoch")
        #expect(run([upd("A", "K"), upd("A", "K")]).linkedEventKeys.isEmpty, "duplicate item ids reject the whole array")
        let tooMany = (0..<21).map { upd("A\($0)", "K") }
        #expect(run(tooMany).linkedEventKeys.isEmpty)
        let foreign = TranscriptReceiptUpdate(itemId: "A", receipt: TranscriptReceipt(commandKey: "c1", origin: "feishu", receiptState: "sent", eventKey: "K"))
        #expect(run([foreign]).linkedEventKeys.isEmpty, "only origin=api carries a local key")
        let replacing = run([upd("A", "K")], mutate: { (t: inout TranscriptThread) in t.invalidate() })
        #expect(replacing.linkedEventKeys.isEmpty, "needsReplace: wait for the authoritative page")
        var stale = loaded([user("A")])
        #expect(stale.applyReceiptUpdates(page([], updates: [upd("A", "K")]), request: req("K"), snapshot: stale.snapshot - 1) == 0)
    }

    @Test func conflictingExistingReceiptIsNotOverwritten() {
        var t = loaded([user("A", receipt: rc("K0", cmd: "other"))])
        #expect(t.applyReceiptUpdates(page([], updates: [upd("A", "K", cmd: "c1")]), request: req("K")) == 0)
        #expect(t.items[0].receipt?.eventKey == "K0")
        var same = loaded([user("A", receipt: rc("K", state: "sent"))])
        let done = TranscriptReceiptUpdate(itemId: "A", receipt: rc("K", state: "done"))
        #expect(same.applyReceiptUpdates(page([], updates: [done]), request: req("K")) == 1, "same command+key follows the authoritative state")
        #expect(same.items[0].receipt?.receiptState == "done")
    }

    // 定位视图 / 尾部已裁剪时页正文被拒，但合法补丁仍更新已加载项；窗口、游标、正文不动
    @Test func patchStillAppliesWhenTheBodyIsRefusedAndTheWindowDoesNotMove() {
        var t = TranscriptThread()
        let located = t.applyLocated(page([user("A"), asst("B")], hasMore: true, next: "c"), itemId: "A")
        #expect(located)
        let latest = page([asst("B")], updates: [upd("A", "K")])
        let adopted = t.applyLatest(latest, snapshot: t.snapshot)
        #expect(!adopted, "pinned view refuses the latest body")
        let before = (t.windowRange, t.nextBefore, t.revision, t.items.map(\.text), t.snapshot)
        #expect(t.applyReceiptUpdates(latest, request: req("K"), snapshot: t.snapshot) == 1)
        #expect(t.items[0].receipt?.eventKey == "K" && t.linkedEventKeys == ["K"])
        #expect(before.0 == t.windowRange && before.1 == t.nextBefore && before.2 == t.revision && before.3 == t.items.map(\.text) && before.4 == t.snapshot)
    }

    // applyLatest 带声明：页里同一项没有 receipt 时不让页覆盖补丁；整页替换也先记账本
    @Test func applyLatestAdoptsThePatchEvenWhenThePageItselfLacksTheReceipt() {
        var t = loaded([user("A"), asst("B")])
        let p = page([user("A"), asst("B")], updates: [upd("A", "K")])
        let adopted = t.applyLatest(p, snapshot: t.snapshot, etag: "\"v\"", shape: req("K"))
        #expect(adopted)
        #expect(t.items[0].receipt?.eventKey == "K" && t.linkedEventKeys == ["K"])
        #expect(t.validator(for: req("K")) == "\"v\"")
        var replaced = loaded([user("A")])
        let far = page([user("X"), asst("Y")], updates: [upd("A", "K")]) // 与已加载内容不相交：整页替换
        let swapped = replaced.applyLatest(far, snapshot: replaced.snapshot, shape: req("K"))
        #expect(swapped)
        #expect(replaced.items.map(\.id) == ["X", "Y"] && replaced.linkedEventKeys == ["K"], "ledger keeps K even though A left the loaded window")
    }

    @Test func linkedKeysAreNotResurrectedNorInheritedAcrossEpochs() {
        var t = loaded([user("A"), asst("B")])
        t.applyReceiptUpdates(page([], updates: [upd("A", "K")]), request: req("K"))
        _ = t.applyLatest(page([asst("B")]), snapshot: t.snapshot) // 窗口/替换后 A 不在页里，账本仍记得 K
        #expect(t.linkedEventKeys.contains("K"))
        _ = t.applyLatest(page([user("X")], epoch: "E2"), snapshot: t.snapshot)
        #expect(t.linkedEventKeys.isEmpty, "a real epoch change starts a new ledger")
    }

    // 更早页：已加载项 Bridge 现已挂 receipt → 刷新元数据，不插重复行
    @Test func olderPageRefreshesKnownItemsWithoutDuplicating() {
        var t = TranscriptThread()
        _ = t.applyLatest(page([user("A"), asst("B")], hasMore: true, next: "c"), snapshot: t.snapshot)
        let merge = t.applyOlder(page([user("A", receipt: rc("K")), user("Z")]), snapshot: t.snapshot)
        #expect(merge.added == 1)
        #expect(t.items.map(\.id) == ["Z", "A", "B"])
        #expect(t.items[1].receipt?.eventKey == "K" && t.linkedEventKeys == ["K"])
        // 冲突不覆盖
        _ = t.applyOlder(page([user("A", receipt: rc("K9", cmd: "zz"))]), snapshot: t.snapshot)
        #expect(t.items[1].receipt?.eventKey == "K")
    }

    // ETag 绑定请求形状：声明集合变化后不复用旧 validator
    @Test func validatorIsBoundToTheRequestShape() {
        var t = TranscriptThread()
        let k1 = req("K")
        _ = t.applyLatest(page([user("A")]), snapshot: t.snapshot, etag: "\"v\"", shape: k1)
        #expect(t.validator(for: k1) == "\"v\"")
        #expect(t.validator(for: req("K", "K2")) == nil)
        #expect(t.validator(for: nil) == nil)
        #expect(t.validator == nil)
        var plain = TranscriptThread()
        _ = plain.applyLatest(page([user("A")]), snapshot: plain.snapshot, etag: "\"p\"")
        #expect(plain.validator == "\"p\"" && plain.validator(for: k1) == nil)
        let gate = TranscriptReadGate.decide(targetId: "T", connection: 1, activation: { var a = TranscriptActivation(); _ = a.activate("T"); return a }(), thread: t, receipt: k1)
        guard case .start(let ticket) = gate else { Issue.record("expected start"); return }
        #expect(ticket.etag == "\"v\"" && ticket.receipt == k1)
    }

    // R1：真实 applyLatest 里，页覆盖成空 receipt 后，第二遍也不能放行第一遍拒绝的冲突补丁
    @Test func conflictingPatchStaysRejectedThroughApplyLatest() {
        let old = TranscriptReceipt(commandKey: "old-command", origin: "api", receiptState: "sent", eventKey: "old-key")
        var t = loaded([user("A", receipt: old)])
        let fresh = TranscriptReceiptUpdate(itemId: "A", receipt: TranscriptReceipt(commandKey: "new-command", origin: "api", receiptState: "done", eventKey: "new-key"))
        let p = page([user("A")], updates: [fresh]) // 同一页里的 A 没有 receipt
        let adopted = t.applyLatest(p, snapshot: t.snapshot, shape: req("new-key"))
        #expect(adopted)
        #expect(!t.linkedEventKeys.contains("new-key"), "冲突补丁不能因正文刷新而被放行")
        #expect(t.items[0].receipt?.commandKey != "new-command")
        // 正控：同 command/key 的状态更新仍被采纳；页里本来就带 receipt 的不被补丁改写
        var same = loaded([user("A", receipt: rc("K", state: "sent"))])
        let done = TranscriptReceiptUpdate(itemId: "A", receipt: rc("K", state: "done"))
        _ = same.applyLatest(page([user("A")], updates: [done]), snapshot: same.snapshot, shape: req("K"))
        #expect(same.items[0].receipt?.receiptState == "done")
        var pageOwned = loaded([user("A")])
        _ = pageOwned.applyLatest(page([user("A", receipt: rc("K", state: "done"))], updates: [upd("A", "K")]), snapshot: pageOwned.snapshot, shape: req("K"))
        #expect(pageOwned.items[0].receipt?.receiptState == "done", "the page's own receipt is not overwritten by the restore pass")
    }

    // R2：1 个仍保留的原生回显 + 20 个更晚的已终态普通发送：优先项不被挤出声明
    @Test func preferredNativeEchoIsNotStarvedByOrdinarySends() {
        let native: (eventKey: String?, sessionEpoch: String?) = ("native-kept", "E")
        let ordinary = (0..<20).map { (eventKey: Optional("ordinary-\(String(format: "%02d", $0))"), sessionEpoch: Optional("E")) }
        let plain = TranscriptReceiptRequest.select(epoch: "E", linked: [], sent: [native] + ordinary)
        #expect(plain?.eventKeys.contains("native-kept") == false, "没有优先级时最近 20 个普通发送占满")
        let preferred = TranscriptReceiptRequest.select(epoch: "E", linked: [], sent: [native] + ordinary, preferred: ["native-kept"])
        #expect(preferred?.eventKeys.count == 20 && preferred?.eventKeys.contains("native-kept") == true)
        // 优先项仍受同代次 / 未关联约束
        #expect(TranscriptReceiptRequest.select(epoch: "E", linked: ["native-kept"], sent: [native], preferred: ["native-kept"]) == nil)
        #expect(TranscriptReceiptRequest.select(epoch: "F", linked: [], sent: [native], preferred: ["native-kept"]) == nil)
    }

    // G1（Kit 部分）：W1 真实路由输出（合成，未归一化）解码 + 采纳
    @Test func actualBridgeFixtureDecodesAndBackfillsLoadedHistory() throws {
        func fixture(_ name: String) throws -> TranscriptPage {
            try JSONDecoder().decode(TranscriptPage.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ReceiptFixtures/fixture-" + name + ".json")))
        }
        let pending = try fixture("receipt-updates-pending"), complete = try fixture("receipt-updates-complete")
        var older = try fixture("older-page-with-receipt")
        let u = try #require(complete.receiptUpdates?.first), epoch = try #require(complete.sessionEpoch), key = try #require(u.receipt.eventKey)
        let request = try #require(TranscriptReceiptRequest(sessionEpoch: epoch, eventKeys: [key]))
        #expect(pending.receiptUpdates?.isEmpty == true)
        #expect(!complete.items.contains { $0.id == u.itemId } && u.receipt.origin == "api")
        // 旧页先到但 proof 未完成时的已加载状态：只清掉 setup 的 receipt，ID/正文/时间保持 Bridge 原值
        for i in older.items.indices { older.items[i].receipt = nil }
        var t = TranscriptThread()
        _ = t.applyLatest(pending); _ = t.applyOlder(older, snapshot: t.snapshot)
        #expect(t.items.contains { $0.id == u.itemId } && t.linkedEventKeys.isEmpty)
        let before = t.items.first { $0.id == u.itemId }
        _ = t.applyLatest(complete, snapshot: t.snapshot, shape: request)
        let a = try #require(t.items.first { $0.id == u.itemId })
        #expect(a.text == before?.text && a.t == before?.t && a.receipt == u.receipt && t.linkedEventKeys == [key])
        #expect(TranscriptCopy.sourceLine(a).contains("Palmhelm"))
        // 未加载 A 的同一真实响应不记账本
        var unknown = TranscriptThread()
        _ = unknown.applyLatest(pending); _ = unknown.applyLatest(complete, snapshot: unknown.snapshot, shape: request)
        #expect(unknown.linkedEventKeys.isEmpty)
        // 旧页自带 receipt：刷新已知项且不重复插行
        let oldPage = try fixture("older-page-with-receipt")
        var loadedA = TranscriptThread()
        _ = loadedA.applyLatest(pending); _ = loadedA.applyOlder(older, snapshot: loadedA.snapshot)
        let count = loadedA.items.count
        _ = loadedA.applyOlder(oldPage, snapshot: loadedA.snapshot)
        #expect(loadedA.items.count == count && loadedA.items.first { $0.id == u.itemId }?.receipt == u.receipt)
    }
}
