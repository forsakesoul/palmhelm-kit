import Foundation
import Testing
@testable import PalmhelmKit

// #155 现场：结束状态（unknown / paused）的旧补行在对话已有更晚的 user 回合后属于历史，不再挂在线程尾部；在途的 queued / started 不受影响。
@Suite struct ThreadTailHistoryTests {
    private func cmd(_ state: String, key: String, seq: Int, createdT: Int?, reason: String? = nil) throws -> ApiCommand {
        var s = #"{"key":"\#(key)","inboxSeq":\#(seq),"text":"hi","truncated":false,"origin":"api","state":"\#(state)","targetId":"t1""#
        if let createdT { s += #","createdT":\#(createdT)"# }
        if let reason { s += #","reason":"\#(reason)""# }
        return try JSONDecoder().decode(ApiCommand.self, from: Data((s + "}").utf8))
    }
    private func rows(_ cs: [ApiCommand], latestUserT: Int?) -> [String] {
        var w = CommandWindow(); for c in cs { w.admit(c) }
        return ThreadCommandSupplement.rows(commands: cs, window: w, threadId: "t1", linkedKeys: [], coveredKeys: [], latestWindow: true, latestUserT: latestUserT).map(\.key)
    }

    @Test func endedRowsOlderThanTheLatestUserTurnAreHistory() throws {
        let u = try cmd("unknown", key: "u", seq: 1, createdT: 1000), p = try cmd("paused", key: "p", seq: 2, createdT: 1000)
        #expect(rows([u, p], latestUserT: 2000).isEmpty, "①③ unknown / paused 早于最新 user：不补")
        #expect(rows([u, p], latestUserT: 500) == ["u", "p"], "② 晚于最新 user：补")
        #expect(rows([u, p], latestUserT: 1000) == ["u", "p"], "相等不算更晚")
    }
    @Test func inFlightRowsAreNeverHistory() throws {
        let q = try cmd("queued", key: "q", seq: 1, createdT: 1000), s = try cmd("started", key: "s", seq: 2, createdT: 1000)
        #expect(rows([q, s], latestUserT: 9000) == ["q", "s"], "④ queued / started 仍在途")
    }
    @Test func missingTimesKeepTheOriginalBehavior() throws {
        let noCreated = try cmd("unknown", key: "n", seq: 1, createdT: nil), old = try cmd("unknown", key: "o", seq: 2, createdT: 1)
        #expect(rows([noCreated], latestUserT: 9000) == ["n"], "⑤ 没有 createdT：原行为")
        #expect(rows([old], latestUserT: nil) == ["o"], "⑤ 没有 user 记录：原行为")
        let t = TranscriptThread()
        #expect(ThreadTailRules.latestUserTime(t) == nil)
    }
    @Test func latestUserTimeTakesTheLastUserItemWithATime() {
        var t = TranscriptThread()
        _ = t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e", revision: "r", items: [
            TranscriptItem(id: "a", role: "user", text: "旧", t: 100), TranscriptItem(id: "b", role: "assistant", text: "答", t: 900),
            TranscriptItem(id: "c", role: "user", text: "新", t: 500), TranscriptItem(id: "d", role: "user", text: "无时间", t: nil),
        ], nextBefore: nil, hasMore: false, partial: false))
        #expect(ThreadTailRules.latestUserTime(t) == 500)
    }

    // ⑥ #155 形状：unknown / ambiguous 的旧命令，其后已有多条真实 user → 尾部不再出现；账本不受影响（本规则只作用于尾部补行）
    @Test func the155ShapeIsGoneFromTheTailOnceLaterUserTurnsExist() throws {
        let old = try cmd("unknown", key: "api:d:155", seq: 155, createdT: 1_794_000_000_000, reason: "ambiguous")
        var t = TranscriptThread()
        _ = t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e", revision: "r", items: [
            TranscriptItem(id: "u1", role: "user", text: "之后一", t: 1_794_100_000_000), TranscriptItem(id: "a1", role: "assistant", text: "答", t: 1_794_100_001_000),
            TranscriptItem(id: "u2", role: "user", text: "之后二", t: 1_794_200_000_000),
        ], nextBefore: nil, hasMore: true, partial: false))
        var w = CommandWindow(); w.admit(old)
        let tail = ThreadTailRules.tail(commands: [old], window: w, threadId: "t1", transcript: t, foreignKeys: [], echoes: { _ in [String]() }, echoKey: { $0 })
        #expect(tail.supplement.isEmpty && tail.commandRows.isEmpty)
        // 没有更晚 user 回合（刚发出就 unknown）时仍显示
        var fresh = TranscriptThread()
        _ = fresh.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e", revision: "r", items: [TranscriptItem(id: "a0", role: "assistant", text: "答", t: 1_793_000_000_000)], nextBefore: nil, hasMore: true, partial: false))
        #expect(ThreadTailRules.tail(commands: [old], window: w, threadId: "t1", transcript: fresh, foreignKeys: [], echoes: { _ in [String]() }, echoKey: { $0 }).supplement.map(\.key) == ["api:d:155"])
    }
}
