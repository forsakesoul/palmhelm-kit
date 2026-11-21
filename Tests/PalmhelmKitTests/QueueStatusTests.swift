import Foundation
import Testing
@testable import PalmhelmKit

// #89 S2：扩展组的缺失/null 语义、排队卡文案、状态不倒退、队列组清除与回执覆盖。

@Suite struct QueueStatusTests {
    private func command(_ json: String) throws -> ApiCommand {
        try JSONDecoder().decode(ApiCommand.self, from: Data(json.utf8))
    }

    private let legacy = #"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"queued","lane":"ordinary"}"#

    @Test func legacyFrameHasNoGroupAndDoesNotClear() throws {
        let c = try command(legacy)
        #expect(c.queue == nil)
        #expect(QueueStatusPresentation.card(for: c) == nil)
    }

    @Test func explicitNullsAreAClearNotALegacyFrame() throws {
        let c = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"queued","lane":"use","queueReason":null,"queuePosition":null,"observedAt":null,"phase":null}"#)
        #expect(c.queue == QueueMeta())
        #expect(QueueStatusPresentation.card(for: c)?.title == "补充排队")
    }

    @Test func unknownReasonDegradesWithoutFailingTheFrame() throws {
        let c = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"queued","lane":"ordinary","queueReason":"from_the_future","queuePosition":2,"observedAt":null,"phase":null}"#)
        #expect(c.queue?.reason == "from_the_future")
        #expect(QueueStatusPresentation.card(for: c) == QueueStatusCard(title: "队列第 2 位", detail: "排队中", uncertain: false))
    }

    @Test func progressFrameDecodesGroupOrNone() {
        let withGroup = SSEFrame(id: nil, event: "progress", data: #"{"eventKey":"api:d:1","state":"queued","queueReason":"draft","queuePosition":1,"observedAt":1700000000000,"phase":null}"#)
        #expect(BridgeEventDecoder.decode(withGroup) == .progress(ProgressPayload(eventKey: "api:d:1", state: "queued", queue: QueueMeta(reason: "draft", position: 1, observedAt: 1700000000000))))
        let legacy = SSEFrame(id: nil, event: "progress", data: #"{"eventKey":"api:d:1","state":"started"}"#)
        #expect(BridgeEventDecoder.decode(legacy) == .progress(ProgressPayload(eventKey: "api:d:1", state: "started")))
    }

    @Test func unconfirmedWithoutTimeSaysNoValidDeterminationAndInventsNoTime() throws {
        let c = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"queued","lane":"ordinary","queueReason":"unconfirmed","queuePosition":1,"observedAt":null,"phase":null}"#)
        let card = QueueStatusPresentation.card(for: c)
        #expect(card?.detail == "尚无有效判定")
        #expect(card?.uncertain == true)
        #expect(card?.detail?.contains("截至") == false)
    }

    @Test func unconfirmedWithTimeShowsTheLastEvidenceTime() throws {
        let ms = 1_700_000_000_000
        let c = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"queued","lane":"ordinary","queueReason":"unconfirmed","queuePosition":1,"observedAt":1700000000000,"phase":null}"#)
        let card = QueueStatusPresentation.card(for: c)
        #expect(card?.detail == "原因待确认 · " + QueueStatusPresentation.observedText(ms))
        #expect(card?.detail?.contains("超过") == false)
    }

    @Test func phaseFollowsStartedAndClearsWhenNotApplicable() throws {
        var c = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"started","lane":"ordinary","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"awaiting"}"#)
        #expect(QueueStatusPresentation.card(for: c)?.title == "已送达 · 等待回合开始")
        c.state = "finished"
        #expect(QueueStatusPresentation.card(for: c) == nil)
    }

    @Test func staleQueuedProgressDoesNotRegressStartedAndKeepsPhase() throws {
        let started = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"started","lane":"ordinary","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"dispatch"}"#)
        let got = CommandMerge.progressed(started, state: "queued", reason: nil, queue: QueueMeta(reason: "wait_turn", position: 1))
        #expect(got.state == "started")
        #expect(got.queue?.reason == nil)
    }

    @Test func queuedProgressAfterInboundReplacesGroupAndClearsOnStart() throws {
        let queued = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"queued","lane":"ordinary","queueReason":"draft","queuePosition":1,"observedAt":5,"phase":null}"#)
        let cleared = CommandMerge.progressed(queued, state: "queued", reason: nil, queue: QueueMeta(reason: nil, position: nil, observedAt: nil, phase: nil))
        #expect(cleared.queue == QueueMeta())
        #expect(QueueStatusPresentation.card(for: cleared)?.title == "排队中")
        let started = CommandMerge.progressed(queued, state: "started", reason: nil, queue: QueueMeta(phase: "dispatch"))
        #expect(started.queue == QueueMeta(phase: "dispatch"))
    }

    @Test func legacyProgressKeepsExistingGroup() throws {
        let queued = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"queued","lane":"ordinary","queueReason":"draft","queuePosition":1,"observedAt":5,"phase":null}"#)
        let got = CommandMerge.progressed(queued, state: "queued", reason: nil, queue: nil)
        #expect(got.queue?.reason == "draft")
    }

    @Test func incrementalLegacyInboundKeepsGroupButFullRebuildClearsIt() throws {
        let queued = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"queued","lane":"ordinary","queueReason":"draft","queuePosition":1,"observedAt":5,"phase":null}"#)
        let legacyQueued = try command(legacy)
        // 增量帧（inbound）不带四键：未启用，保留原组。
        #expect(CommandMerge.merged(old: queued, new: legacyQueued).queue?.reason == "draft")
        // 完整重建（HTTP 快照）不带四键：视为旧 Bridge，清除（#89 F3）。
        #expect(CommandMerge.snapshotMerged(old: queued, new: legacyQueued, touchedDuringRequest: false).queue == nil)
        let finished = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"finished","lane":"ordinary"}"#)
        #expect(CommandMerge.merged(old: queued, new: finished).queue == nil)
    }

    // 以下为 A1-042 的反例（#89 S2 审查 F1–F5），修复前红、修复后绿。

    private func row(_ state: String = "queued", reason: String? = "draft", phase: String? = nil) -> ApiCommand {
        var c = ApiCommand(key: "api:d:1", inboxSeq: 1, text: "synthetic", origin: "api", state: state, lane: "ordinary")
        c.queue = QueueMeta(reason: reason, position: state == "queued" ? 1 : nil, observedAt: reason == nil ? nil : 1000, phase: phase)
        return c
    }

    @Test func f1SameStateSSEUpdateWinsOverInflightSnapshot() {
        let snapshot = row()
        let updated = CommandMerge.progressed(snapshot, state: "queued", reason: nil, queue: QueueMeta(reason: "unconfirmed", position: 1, observedAt: 2000))
        let got = CommandMerge.snapshotMerged(old: updated, new: snapshot, touchedDuringRequest: true)
        #expect(got.queue?.reason == "unconfirmed")
        #expect(got.queue?.observedAt == 2000)
    }

    @Test func f1ExplicitClearIsNotResurrectedBySameStateSnapshot() {
        let snapshot = row()
        let updated = CommandMerge.progressed(snapshot, state: "queued", reason: nil, queue: QueueMeta())
        #expect(CommandMerge.snapshotMerged(old: updated, new: snapshot, touchedDuringRequest: true).queue == QueueMeta())
    }

    @Test func f1PhaseIsNotRegressedByInflightSnapshot() {
        let snapshot = row("started", reason: nil, phase: "dispatch")
        let updated = CommandMerge.progressed(snapshot, state: "started", reason: nil, queue: QueueMeta(phase: "running"))
        #expect(CommandMerge.snapshotMerged(old: updated, new: snapshot, touchedDuringRequest: true).queue?.phase == "running")
    }

    @Test func f2RepeatedInboundDoesNotRegressStartedButKeepsLaneUpdates() {
        let started = row("started", reason: nil, phase: "running")
        var newer = row()
        // 普通车道的较旧 queued 不是恢复边（O1-048）：不得把 started 拉回，但 mode 等事实照常更新。
        newer.mode = "send_now"
        let got = CommandMerge.merged(old: started, new: newer)
        #expect(got.state == "started")
        #expect(got.queue == QueueMeta(phase: "running"))
        #expect(got.mode == "send_now")
    }

    @Test func f2InboundCannotResurrectAClearedGroup() {
        let started = row("started", reason: nil, phase: nil)
        let got = CommandMerge.merged(old: started, new: row())
        #expect(got.queue?.reason == nil)
    }

    @Test func f3FullRebuildAfterRollbackClearsTheDraftAndBringsTheReceiptBack() throws {
        let draft = row()
        let legacy = try command(legacy)
        let got = CommandMerge.snapshotMerged(old: draft, new: legacy, touchedDuringRequest: false)
        #expect(QueueStatusPresentation.card(for: got) == nil)
        #expect(!QueueStatusPresentation.rendersCard(got, folded: false), "no card rendered means the dirty receipt stays visible")
    }

    @Test func f4FoldedFeishuRowRendersNoCard() {
        let c = row()
        #expect(QueueStatusPresentation.rendersCard(c, folded: false))
        #expect(!QueueStatusPresentation.rendersCard(c, folded: true))
    }

    @Test func f5WaitTurnIsNeutral() {
        #expect(QueueStatusPresentation.reasonText("wait_turn") == "等待目标空闲")
    }

    @Test func receiptCoveredOnlyWhenTheCardCarriesTheSameKey() {
        let keys: Set<String> = ["api:d:1"]
        #expect(QueueStatusPresentation.receiptCovered(uuid: "dirty:target:alpha:1:api:d:1", replyTo: "api:d:1", coveredKeys: keys))
        #expect(!QueueStatusPresentation.receiptCovered(uuid: "dirty:target:alpha:1:api:d:2", replyTo: "api:d:2", coveredKeys: keys))
        #expect(QueueStatusPresentation.receiptCovered(uuid: "busy:api:d:1", replyTo: nil, coveredKeys: keys))
        #expect(QueueStatusPresentation.receiptCovered(uuid: "blocked:api:d:1", replyTo: nil, coveredKeys: keys))
        #expect(!QueueStatusPresentation.receiptCovered(uuid: "busy:api:d:10", replyTo: nil, coveredKeys: keys))
        #expect(!QueueStatusPresentation.receiptCovered(uuid: "ack:api:d:1", replyTo: nil, coveredKeys: keys))
    }

    @Test func snapshotDuringSSEUpdateKeepsTheNewerLocalRow() throws {
        let queued = try command(legacy)
        let started = try command(#"{"key":"api:d:1","inboxSeq":1,"text":"hi","truncated":false,"origin":"api","state":"started","lane":"ordinary","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"dispatch"}"#)
        // 快照在 SSE 把 started 推进之前读取：读取期间有更新，且本地更靠后，保留本地。
        #expect(CommandMerge.snapshotMerged(old: started, new: queued, touchedDuringRequest: true).state == "started")
        // 没有并发更新：快照也不能把已 started 的命令拉回 queued（F2 的状态不倒退对所有入口生效）。
        #expect(CommandMerge.snapshotMerged(old: started, new: queued, touchedDuringRequest: false).state == "started")
    }

    // #89 S2 复审 R2：快照生命周期比本地更靠后时，采用快照的组与适用 phase（不因途中 SSE 而丢弃）。
    @Test func r2NewerSnapshotStateTakesItsOwnPhaseEvenWhenTouched() {
        var old = ApiCommand(key: "api:d:1", inboxSeq: 1, text: "synthetic", origin: "api", state: "queued", lane: "ordinary")
        old.queue = QueueMeta(reason: "unconfirmed", position: 1, observedAt: 1000)
        var snapshot = old
        snapshot.state = "started"
        snapshot.queue = QueueMeta(phase: "running")
        let got = CommandMerge.snapshotMerged(old: old, new: snapshot, touchedDuringRequest: true)
        #expect(got.state == "started")
        #expect(got.queue?.phase == "running")
        #expect(got.queue?.reason == nil)
    }

    // #89 S2 复审 R1（规则 C）：inflight 由最终 commands 派生。
    @Test func r1DerivedInflightFollowsTheFinalCommands() {
        func cmd(_ state: String) -> ApiCommand { ApiCommand(key: "x", inboxSeq: 1, text: "t", origin: "api", state: state, lane: "ordinary") }
        let commands: [String: ApiCommand] = [
            "finishedNow": cmd("finished"),   // 快照刚确认终态：旧本地在途必须删除
            "startedNew": cmd("started"),     // 途中新增（快照没有）：保留本地在途细节
            "started": cmd("started"),        // 快照在途：取快照
            "queuedKey": cmd("queued"),       // 排队中不在途
            "unknownKey": cmd("unknown"),     // 送达未知仍在途
        ]
        let local = ["finishedNow": "started", "startedNew": "started", "unknownKey": "unknown"]
        let snapshot = ["started": "started"]
        // 已知命令的在途值就是它的状态（O1-049 F2）：没有第二套细节字符串。
        #expect(CommandMerge.deriveInflight(commands: commands, local: local, snapshot: snapshot) == [
            "startedNew": "started", "started": "started", "unknownKey": "unknown",
        ])
    }

    // #89 S2 复审 R2（A1-046 反例，规则 A/B）。
    @Test func r2aUnknownCannotFollowBackToAnOlderStartedSnapshot() {
        let unknown = ApiCommand(key: "api:d:1", inboxSeq: 1, text: "t", origin: "api", state: "unknown", lane: "ordinary")
        let started = ApiCommand(key: "api:d:1", inboxSeq: 1, text: "t", origin: "api", state: "started", lane: "ordinary")
        #expect(CommandMerge.snapshotMerged(old: unknown, new: started, touchedDuringRequest: true).state == "unknown")
    }

    @Test func r2bOrdinaryToUseClearsTheOrdinaryGroupEvenWhenTouched() {
        var old = row()
        old.queue = QueueMeta(reason: "draft", position: 1, observedAt: 1000)
        var newer = row(reason: nil)
        newer.lane = "use"
        newer.queue = QueueMeta()
        let got = CommandMerge.snapshotMerged(old: old, new: newer, touchedDuringRequest: true)
        #expect(got.state == "queued")
        #expect(got.lane == "use")
        #expect(got.queue == QueueMeta())
    }

    @Test func r2cPausedIsTerminalAndCannotResumeQueued() {
        let paused = ApiCommand(key: "api:d:1", inboxSeq: 1, text: "t", origin: "api", state: "paused", lane: "ordinary")
        let queued = row()
        #expect(CommandMerge.snapshotMerged(old: paused, new: queued, touchedDuringRequest: true).state == "paused")
    }

    @Test func ruleATableMatchesTheWireTransitions() {
        let states = ["queued", "started", "unknown", "finished", "paused", "rejected"]
        // 由 DB 合法路径推导的多步可达（O1-049 F1）：queued→sending→unknown；sending→queued_use→withdrawn。
        // started → queued 不在表中（只由 lane=use 的有序恢复边接受，见 canFollow(lane:ordered:)）。
        let allowed: [String: Set<String>] = [
            "queued": ["queued", "started", "unknown", "paused", "finished", "rejected"],
            "started": ["started", "unknown", "paused", "finished", "rejected"],
            "unknown": ["unknown", "paused", "finished"],
            "finished": ["finished"], "paused": ["paused"], "rejected": ["rejected"],
        ]
        for from in states {
            for to in states {
                #expect(CommandMerge.canFollow(from: from, to: to) == allowed[from]!.contains(to), "\(from) -> \(to)")
            }
        }
        // 未知的线上状态不做判断（现有降级规则）。
        #expect(CommandMerge.canFollow(from: "started", to: "from_the_future"))
    }

    // 车道由 use 回到 ordinary 时，组来自最终（快照）来源，不沿用本地的空组（规则 B 的车道判定）。
    @Test func r2dLaneChangeBackToOrdinaryTakesTheSnapshotGroupEvenWhenTouched() {
        var old = row(reason: nil)
        old.lane = "use"
        old.queue = QueueMeta()
        var newer = row(reason: "draft")
        newer.queue = QueueMeta(reason: "draft", position: 1, observedAt: 2000)
        let got = CommandMerge.snapshotMerged(old: old, new: newer, touchedDuringRequest: true)
        #expect(got.lane == "ordinary")
        #expect(got.queue?.reason == "draft")
    }

    // #89 S2 裁定 O1-048：started→queued 恢复边（Bridge sending→queued_use，线上 queued + lane=use）。
    private func started(_ lane: String = "ordinary") -> ApiCommand {
        ApiCommand(key: "api:d:1", inboxSeq: 1, text: "t", origin: "api", state: "started", lane: lane)
    }
    private func queuedUse() -> ApiCommand {
        var c = ApiCommand(key: "api:d:1", inboxSeq: 1, text: "t", origin: "api", state: "queued", lane: "use")
        c.queue = QueueMeta()
        return c
    }

    @Test func o1048aOrderedInboundRecoveryToQueuedUseIsAcceptedAndInflightClears() {
        let got = CommandMerge.merged(old: started(), new: queuedUse())
        #expect(got.state == "queued")
        #expect(got.lane == "use")
        #expect(CommandMerge.inflight(after: got, current: "started") == nil, "queued is not in flight")
    }

    @Test func o1048bOrdinaryStartedToQueuedStaysRejected() {
        var queued = queuedUse()
        queued.lane = "ordinary"
        #expect(CommandMerge.merged(old: started(), new: queued).state == "started")
        #expect(!CommandMerge.progressAccepted(started(), state: "queued"))
    }

    @Test func o1048cTouchedSnapshotCannotPullStartedBackToQueuedUse() {
        let got = CommandMerge.snapshotMerged(old: started("use"), new: queuedUse(), touchedDuringRequest: true)
        #expect(got.state == "started")
    }

    @Test func o1048dUntouchedSnapshotAcceptsTheRecoveryToQueuedUse() {
        let got = CommandMerge.snapshotMerged(old: started(), new: queuedUse(), touchedDuringRequest: false)
        #expect(got.state == "queued")
        #expect(got.lane == "use")
    }

    // #89 复审4（A1-049）：读面可跳过中间状态（规则 A 为多步可达）、在途只由最终命令状态决定、组的适用性在所有返回路径规范化。
    private func cmd(_ state: String, lane: String = "ordinary", queue: QueueMeta? = nil) -> ApiCommand {
        var c = ApiCommand(key: "api:d:1", inboxSeq: 1, text: "t", origin: "api", state: state, lane: lane)
        c.queue = queue
        return c
    }

    @Test func f1SnapshotMaySkipIntermediateStatesQueuedToUnknown() {
        // DB 合法路径：queued → sending → unknown（断线期间两步，重连只看到终点）。
        #expect(CommandMerge.snapshotMerged(old: cmd("queued"), new: cmd("unknown"), touchedDuringRequest: false).state == "unknown")
        #expect(CommandMerge.snapshotMerged(old: cmd("queued"), new: cmd("started"), touchedDuringRequest: false).state == "started")
    }

    @Test func f1SnapshotMaySkipIntermediateStatesStartedUseToWithdrawn() {
        // DB 合法路径：sending → queued_use → withdrawn（线上 started → rejected，中间的 queued 未被观察到）。
        var withdrawn = cmd("rejected", lane: "use")
        withdrawn.reason = "withdrawn"
        #expect(CommandMerge.snapshotMerged(old: cmd("started", lane: "use"), new: withdrawn, touchedDuringRequest: false).state == "rejected")
    }

    @Test func f1TerminalStaysTerminalForAFutureState() {
        #expect(CommandMerge.merged(old: cmd("finished"), new: cmd("from_the_future")).state == "finished")
    }

    @Test func f1DBNonEdgesStayRejected() {
        #expect(!CommandMerge.canFollow(from: "unknown", to: "started"))
        #expect(!CommandMerge.canFollow(from: "paused", to: "queued"))
        #expect(!CommandMerge.canFollow(from: "finished", to: "unknown"))
    }

    @Test func f2KnownUnknownCommandOwnsItsInflightState() {
        let unknown = cmd("unknown")
        #expect(CommandMerge.deriveInflight(commands: ["api:d:1": unknown], local: ["api:d:1": "started"], snapshot: [:])["api:d:1"] == "unknown")
        #expect(CommandMerge.inflight(after: unknown, current: "started") == "unknown")
    }

    @Test func f3RejectedTouchedSnapshotStillSettlesTheUseLane() {
        let old = cmd("started", queue: QueueMeta(phase: "running"))
        let got = CommandMerge.snapshotMerged(old: old, new: cmd("queued", lane: "use", queue: QueueMeta()), touchedDuringRequest: true)
        #expect(got.state == "started")
        #expect(got.lane == "use")
        #expect(got.queue == QueueMeta(), "a use lane must not keep the ordinary phase")
    }

    @Test func f3IncrementalLegacyLaneChangeDoesNotKeepTheOrdinaryGroup() {
        let old = cmd("queued", queue: QueueMeta(reason: "draft", position: 1))
        let got = CommandMerge.merged(old: old, new: cmd("queued", lane: "use"))
        #expect(got.lane == "use")
        #expect(got.queue == QueueMeta(), "a legacy frame without the keys keeps the group only while the lane is unchanged")
    }

    @Test func f2OrderedProgressRecoveryClearsInflight() {
        let got = CommandMerge.progressed(cmd("started", lane: "use"), state: "queued", reason: nil, queue: QueueMeta())
        #expect(got.state == "queued")
        #expect(CommandMerge.inflight(after: got, current: "started") == nil)
    }

    // #89 O1-052 N1（规则层）：命令尚不存在时到达的 progress 事实，在命令出现后按同一 A/B/C 规则物化。
    private func progress(_ state: String, reason: String? = nil, queue: QueueMeta? = nil) -> ProgressPayload {
        ProgressPayload(eventKey: "api:d:1", state: state, reason: reason, queue: queue)
    }

    @Test func n1PendingFinishedWinsOverAnOlderStartedCommand() {
        let got = CommandMerge.materialized(cmd("started"), pending: progress("finished"))
        #expect(got.state == "finished")
        #expect(CommandMerge.inflight(after: got, current: "started") == nil)
    }

    @Test func n1PendingUnknownWinsOverAnOlderStartedCommand() {
        let got = CommandMerge.materialized(cmd("started"), pending: progress("unknown"))
        #expect(got.state == "unknown")
        #expect(CommandMerge.inflight(after: got, current: "started") == "unknown")
    }

    @Test func n1PendingQueuedGroupAppliesWhenTheCommandAppearsQueued() {
        let group = QueueMeta(reason: "draft", position: 1, observedAt: 1000)
        let got = CommandMerge.materialized(cmd("queued"), pending: progress("queued", queue: group))
        #expect(got.state == "queued")
        #expect(got.queue == group)
    }

    @Test func n1PendingReasonIsKeptWhenTheCommandAppearsQueued() {
        let got = CommandMerge.materialized(cmd("queued"), pending: progress("rejected", reason: "withdrawn"))
        #expect(got.state == "rejected")
        #expect(got.reason == "withdrawn")
    }

    @Test func n1PendingStartedDoesNotRegressAFinishedCommand() {
        #expect(CommandMerge.materialized(cmd("finished"), pending: progress("started")).state == "finished")
    }

    @Test func n1PendingTableIsBoundedConsumedOnceAndClearable() {
        var table = PendingProgress()
        for i in 0..<205 { table.put(ProgressPayload(eventKey: "k\(i)", state: "started"), seq: i) }
        #expect(table.count == 200)
        #expect(table.take("k0", after: nil).isEmpty, "the oldest fact is evicted at capacity")
        #expect(!table.take("k204", after: nil).isEmpty)
        #expect(table.take("k204", after: nil).isEmpty, "a fact is consumed once")
        table.clear()
        #expect(table.count == 0)
    }

    // #89 O1-054（A1-053 F1）：同一 key 的多帧按序重放，等价于逐帧 progressed（已并入的原因不丢）。
    @Test func o54MultiFrameReplayEqualsSequentialProgress() {
        let c = cmd("started", lane: "use")
        let frames = [ProgressPayload(eventKey: "api:d:1", state: "started", reason: "merged"), ProgressPayload(eventKey: "api:d:1", state: "finished")]
        let got = CommandMerge.materialized(c, pending: frames)
        let expected = CommandMerge.progressed(CommandMerge.progressed(c, state: "started", reason: "merged"), state: "finished", reason: nil)
        #expect(got == expected)
        #expect(got.reason == "merged")
    }

    // #89 O1-054（A1-053 F2A）：快照发起之前的帧被快照覆盖（丢弃），之后的帧才重放。
    @Test func o54FramesOlderThanTheSnapshotAreDiscardedAndNewerReplayed() {
        var table = PendingProgress()
        table.put(ProgressPayload(eventKey: "k", state: "queued"), seq: 1)
        table.put(ProgressPayload(eventKey: "k", state: "started"), seq: 3)
        #expect(table.take("k", after: 2).map(\.state) == ["started"])
        #expect(table.count == 0)
    }

    // #89 O1-054：每 key 最多保留最新 8 帧，超出丢最旧。
    @Test func o54PerKeyFramesAreBoundedToTheLatestEight() {
        var table = PendingProgress()
        for i in 0..<10 { table.put(ProgressPayload(eventKey: "k", state: "started", reason: "r\(i)"), seq: i) }
        let got = table.take("k", after: nil)
        #expect(got.count == 8)
        #expect(got.first?.reason == "r2")
        #expect(got.last?.reason == "r9")
    }
}
