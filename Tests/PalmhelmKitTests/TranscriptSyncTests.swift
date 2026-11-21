import Foundation
import Testing
@testable import PalmhelmKit

// #88 S2/S4 修复：激活同步的纯规则。反例与 A1-223 审查一致（R1–R4）。

private func item(_ id: String, role: String = "assistant", text: String, continuation: String? = nil, truncated: Bool = false) -> TranscriptItem {
    TranscriptItem(id: id, role: role, text: text, truncated: truncated, continuation: continuation)
}

private func segment(_ text: String, item: String = "i", epoch: String = "e", more: Bool = false, next: String? = nil) -> TranscriptItemSegment {
    TranscriptItemSegment(status: "ok", sessionEpoch: epoch, itemId: item, text: text, hasMore: more, continuation: next)
}

@Suite struct TranscriptSyncTests {
    // 旧 Bridge 的条目没有 continuation 键：照常解码，续读令牌为 nil。
    @Test func oldServerItemDecodesWithoutContinuation() throws {
        let old = #"{"id":"i1","role":"assistant","text":"hi","truncated":false}"#
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: Data(old.utf8))
        #expect(decoded.continuation == nil)
        let new = #"{"id":"i1","role":"assistant","text":"hi…","truncated":true,"continuation":"abc.def"}"#
        let withToken = try JSONDecoder().decode(TranscriptItem.self, from: Data(new.utf8))
        #expect(withToken.continuation == "abc.def")
    }

    @Test func segmentDecodesOkAndUnavailable() throws {
        let ok = try JSONDecoder().decode(TranscriptItemSegment.self, from: Data(#"{"status":"ok","sessionEpoch":"e1","itemId":"i1","text":"段","hasMore":true,"continuation":"t.x"}"#.utf8))
        #expect(ok.isAvailable && ok.hasMore == true && ok.continuation == "t.x")
        let gone = try JSONDecoder().decode(TranscriptItemSegment.self, from: Data(#"{"status":"unavailable","items":[],"hasMore":false,"partial":true,"reason":"budget_exceeded"}"#.utf8))
        #expect(!gone.isAvailable && gone.text == nil)
    }

    // A→B→A：第三次激活与第一次的目标相同，但代次不同，第一次的迟到结果不被采纳。
    @Test func aToBToAStaleResultsAreRejected() {
        var gate = TranscriptActivation()
        let firstA = gate.activate("A")
        let b = gate.activate("B")
        let secondA = gate.activate("A")
        #expect(!gate.accepts(firstA))
        #expect(!gate.accepts(b))
        #expect(gate.accepts(secondA))
    }

    @Test func inlineExpansionBudget() {
        for role in ["assistant", "user"] {
            func inline(_ text: String, truncated: Bool = false) -> Bool { TranscriptFolding.expandsInline(item("i", role: role, text: text, truncated: truncated)) }
            #expect(inline(String(repeating: "字", count: 600)))
            #expect(!inline(String(repeating: "字", count: 601)))
            #expect(inline(Array(repeating: "行", count: 12).joined(separator: "\n"))) // 11 个换行 = 12 行
            #expect(!inline(Array(repeating: "行", count: 13).joined(separator: "\n"))) // 12 个换行
            #expect(!inline("短", truncated: true))
        }
    }

    @Test func foldingRules() {
        let short = item("s", text: "很短的回复")
        #expect(!TranscriptFolding.isFoldable(short, isLatestStreaming: false))
        let tenLines = item("l", text: (1...9).map { "第 \($0) 行" }.joined(separator: "\n"))
        #expect(TranscriptFolding.isFoldable(tenLines, isLatestStreaming: false))
        let long = item("c", text: String(repeating: "字", count: 401))
        #expect(TranscriptFolding.isFoldable(long, isLatestStreaming: false))
        #expect(!TranscriptFolding.isFoldable(item("u", role: "user", text: String(repeating: "字", count: 900)), isLatestStreaming: false))
        #expect(!TranscriptFolding.isFoldable(long, isLatestStreaming: true))
    }

    @Test func previewKeepsFirstEightLinesAndLabelRounds() {
        let text = (1...12).map { "行\($0)" }.joined(separator: "\n")
        #expect(TranscriptFolding.previewText(text).split(separator: "\n").count == 8)
        // 语言固定为显式注入（不跟运行机器的系统语言）；数字按显示地区分组（KitL10n.format 带 locale，同 KitL10n.number），十位取整。
        KitL10n.$locale.withValue(Locale(identifier: "zh-Hans")) {
            #expect(TranscriptFolding.characterLabel(String(repeating: "字", count: 57)) == "57 字")
            #expect(TranscriptFolding.characterLabel(String(repeating: "字", count: 1234)) == "约 1,230 字")
        }
        KitL10n.$locale.withValue(Locale(identifier: "en")) {
            #expect(TranscriptFolding.characterLabel(String(repeating: "字", count: 57)) == "57 characters")
            #expect(TranscriptFolding.characterLabel(String(repeating: "字", count: 1234)) == "About 1,230 characters")
        }
    }

    // A1-281 R2：无换行的长段落也要截住，否则折叠态与展开态等高。
    @Test func previewCapsAnUnbrokenLongParagraph() {
        let long = String(repeating: "这是没有换行的长回复正文。", count: 80)
        #expect(TranscriptFolding.previewText(long).count == TranscriptFolding.foldCharacters)
    }

    // 应答必须自证身份：应答的条目或会话不对，不追加（A1-223 R3 的真实类型探针）。
    @Test func segmentIdentityComesFromTheResponseNotTheCaller() {
        var exp = TranscriptExpansion(itemId: "i", sessionEpoch: "e", text: "base", continuation: "tok")
        let ticket = exp.beginLoad()!
        let out = exp.complete(ticket, with: segment("wrong", item: "other", epoch: "other"))
        #expect(out == .stale)
        #expect(exp.text == "base")
    }

    // 单飞：同一条目的第二次续读在途时不发起；第一次完成后才能再发。
    @Test func continuationIsSingleFlight() {
        var exp = TranscriptExpansion(itemId: "i", sessionEpoch: "e", text: "base", continuation: "tok")
        let first = exp.beginLoad()
        #expect(first != nil)
        let second = exp.beginLoad()
        #expect(second == nil, "a second continuation for the same item must not start while one is in flight")
        let finished = exp.complete(first!, with: segment("tail"))
        #expect(finished == .complete)
        #expect(exp.text == "basetail")
    }

    // 收起/重开：旧实例的应答无法进入新实例（R3 的重开吸收旧段）。
    @Test func oldInstanceNeverEntersAReopenedExpansion() {
        var old = TranscriptExpansion(itemId: "i", sessionEpoch: "e", text: "old", continuation: "tok")
        let ticket = old.beginLoad()!
        var reopened = TranscriptExpansion(itemId: "i", sessionEpoch: "e", text: "reopened", continuation: "tok")
        let stale = reopened.complete(ticket, with: segment("old-tail"))
        #expect(stale == .stale)
        #expect(reopened.text == "reopened")
        #expect(reopened.canLoadMore)
    }

    // 晚到的 410 不能把新展开标记为需要重取。
    @Test func lateResetCannotMarkAReopenedExpansion() {
        var old = TranscriptExpansion(itemId: "i", sessionEpoch: "e", text: "old", continuation: "tok")
        let ticket = old.beginLoad()!
        var reopened = TranscriptExpansion(itemId: "i", sessionEpoch: "e", text: "reopened", continuation: "tok")
        reopened.fail(ticket, reset: true)
        #expect(!reopened.needsRefetch)
    }

    // 版本变化：同一条目的令牌变了，旧展开不属于当前条目。
    @Test func expansionBelongsOnlyToTheSameVersionOfItem() {
        let exp = TranscriptExpansion(itemId: "i", sessionEpoch: "e", text: "base", continuation: "tok-1")
        #expect(exp.belongs(to: item("i", text: "x", continuation: "tok-1")))
        #expect(!exp.belongs(to: item("i", text: "x", continuation: "tok-2")))
    }

    // 展开的字节有界：超过上限的段不追加，已显示内容保留，之后不再加载。
    @Test func expansionMemoryIsBounded() {
        var exp = TranscriptExpansion(itemId: "i", sessionEpoch: "e", text: "", continuation: "t")
        let chunk = String(repeating: "字", count: 4000)
        var outcome = TranscriptExpansion.Outcome.appended
        var rounds = 0
        while outcome == .appended, rounds < 1000 {
            guard let ticket = exp.beginLoad() else { break }
            outcome = exp.complete(ticket, with: segment(chunk, more: true, next: "t\(rounds)"))
            rounds += 1
        }
        #expect(exp.text.utf8.count <= TranscriptExpansion.maxBytes)
        #expect(outcome == .limitReached)
        #expect(!exp.canLoadMore)
    }

    // 服务端 reset（410）：保留已显示部分，标记需要重新读取，不再续读。
    @Test func resetKeepsShownTextAndRequestsRefetch() {
        var exp = TranscriptExpansion(itemId: "i", sessionEpoch: "e", text: "已显示", continuation: "t")
        let ticket = exp.beginLoad()!
        exp.fail(ticket, reset: true)
        #expect(exp.needsRefetch && exp.text == "已显示" && !exp.canLoadMore && !exp.isComplete)
    }

    // 读取准入：后台、非当前线程或同线程最新页在途时延后（dirty），前台可见时才发起。
    @Test func readGateDefersOutsideTheVisibleForegroundThread() {
        var activation = TranscriptActivation()
        let t = TranscriptThread()
        #expect(TranscriptReadGate.decide(targetId: "A", connection: 1, activation: activation, thread: t) == .deferred, "no active thread: a background read must not start")
        _ = activation.activate("B")
        #expect(TranscriptReadGate.decide(targetId: "A", connection: 1, activation: activation, thread: t) == .deferred, "a non-current thread must not start")
        _ = activation.activate("A")
        if case .start = TranscriptReadGate.decide(targetId: "A", connection: 1, activation: activation, thread: t) {} else { Issue.record("visible foreground thread should start") }
        var busy = TranscriptThread()
        busy.latestInFlight = true
        #expect(TranscriptReadGate.decide(targetId: "A", connection: 1, activation: activation, thread: busy) == .deferred)
    }

    // 采纳：连接换代、激活变化或快照失效的应答不采纳。
    @Test func acceptanceRequiresSameConnectionActivationAndSnapshot() {
        var activation = TranscriptActivation()
        let token = activation.activate("A")
        let ticket = TranscriptReadGate.Ticket(connection: 1, activation: token, targetId: "A", snapshot: 3, etag: nil, receipt: nil)
        #expect(TranscriptReadGate.accepts(ticket, connection: 1, activation: activation, snapshot: 3))
        #expect(!TranscriptReadGate.accepts(ticket, connection: 2, activation: activation, snapshot: 3), "connection changed")
        _ = activation.activate("B")
        #expect(!TranscriptReadGate.accepts(ticket, connection: 1, activation: activation, snapshot: 3), "activation changed")
        _ = activation.activate("A")
        #expect(!TranscriptReadGate.accepts(ticket, connection: 1, activation: activation, snapshot: 4), "snapshot invalidated")
    }


    @Test func unavailabilityKeepsContentOnlyForTransientReasons() {
        #expect(TranscriptUnavailability.clearsContent(reason: "identity_changed"))
        #expect(TranscriptUnavailability.clearsContent(reason: "owner_mismatch"))
        #expect(TranscriptUnavailability.clearsContent(reason: nil), "an unexplained unavailable clears, as before")
        #expect(!TranscriptUnavailability.clearsContent(reason: "identity_unverified"))
        #expect(!TranscriptUnavailability.clearsContent(reason: "budget_exceeded"))
    }

    @Test func cadenceSingleFlightBackoffAndCancel() {
        var cadence = TranscriptReadCadence()
        let t0 = Date(timeIntervalSince1970: 3000)
        let first = cadence.begin(now: t0)
        #expect(first)
        let early = cadence.begin(now: t0.addingTimeInterval(1))
        #expect(!early)
        cadence.finish(now: t0, success: false)
        let backedOff = cadence.begin(now: t0.addingTimeInterval(1.5))
        #expect(!backedOff)
        let retried = cadence.begin(now: t0.addingTimeInterval(2))
        #expect(retried)
        cadence.cancel()
        #expect(cadence.nextAllowedAt == nil && !cadence.inFlight)
    }
}

/// 折叠判断与预览改为有界遍历后，与旧实现（整篇 components 再取前 8 行 / 400 字）逐例一致。
@Suite struct TranscriptFoldingBoundedTests {
    private func oldFoldable(_ t: String) -> Bool { t.components(separatedBy: "\n").count > 8 || t.count > 400 }
    private func oldPreview(_ t: String) -> String { String(t.components(separatedBy: "\n").prefix(8).joined(separator: "\n").prefix(400)) }

    private func check(_ t: String, _ label: String) {
        let item = TranscriptItem(id: "x", role: "assistant", text: t)
        #expect(TranscriptFolding.isFoldable(item, isLatestStreaming: false) == oldFoldable(t), "isFoldable \(label)")
        #expect(TranscriptFolding.previewText(t) == oldPreview(t), "previewText \(label)")
    }

    @Test func boundariesAndSpecialSequencesAgreeWithTheOldImplementation() {
        let atoms = ["a", "中", "\n", "\r\n", "\r", "😀", "👨‍👩‍👧", "e\u{301}", " ", "\n\n", "🇨🇳"]
        for n in [0, 1, 7, 8, 9, 10] { check(Array(repeating: "行", count: n + 1).joined(separator: "\n"), "\(n) 个换行") }
        for n in [399, 400, 401] {
            check(String(repeating: "字", count: n), "\(n) 字")
            check(String(repeating: "👨‍👩‍👧", count: n), "\(n) 个组合 emoji")
            check(String(repeating: "e\u{301}", count: n), "\(n) 个组合附标")
            check(String(repeating: "a\r\n", count: n), "\(n) 个 CRLF")
        }
        check("", "空串")
        check(String(repeating: "x", count: 19500), "19500 字压力样本")
        check((0..<8).map { _ in String(repeating: "长", count: 60) }.joined(separator: "\n") + "\n后文", "8 行且 400 字边界")
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        for k in 0..<4000 {
            var s = ""
            for _ in 0..<(next() % 700) { s += atoms[next() % atoms.count] }
            check(s, "随机 \(k)")
        }
    }
}
