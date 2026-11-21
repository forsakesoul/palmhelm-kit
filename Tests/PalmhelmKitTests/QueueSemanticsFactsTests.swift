import Foundation
import Testing
@testable import PalmhelmKit

// #89 语义片 A：stopDisposition 的 presence 与合并、阶段 / 暂停的共同语义、卡期限、消息窗口与补行规则、历史 inbox 解码。
@Suite struct QueueSemanticsFactsTests {
    private func cmd(_ state: String, key: String = "api:d:1", stop: String? = nil, nullStop: Bool = false, extra: String = "", seq: Int = 1) throws -> ApiCommand {
        var s = #"{"key":"\#(key)","inboxSeq":\#(seq),"text":"hi","truncated":false,"origin":"api","state":"\#(state)","targetId":"t1""#
        if let stop { s += #","stopDisposition":"\#(stop)""# }
        if nullStop { s += #","stopDisposition":null"# }
        return try JSONDecoder().decode(ApiCommand.self, from: Data((s + extra + "}").utf8))
    }
    private func decode(_ json: String) throws -> ApiCommand { try JSONDecoder().decode(ApiCommand.self, from: Data(json.utf8)) }

    // MARK: A. 解码 presence

    @Test func stopPresenceDistinguishesAbsentNullValueAndUnknown() throws {
        #expect(try cmd("paused").stopDisposition == nil, "缺键")
        #expect(try cmd("paused", stop: "not_dispatched").stopDisposition == .notDispatched)
        #expect(try cmd("paused", stop: "execution_uncertain").stopDisposition == .uncertain)
        #expect(try cmd("paused", nullStop: true).stopDisposition == .uncertain, "显式 null 保守为不确定，不是缺键")
        #expect(try cmd("paused", stop: "from_the_future").stopDisposition == .uncertain, "未知值不使解码失败，保守")
        #expect(try cmd("paused", extra: #","stopDisposition":7"#).stopDisposition == .uncertain, "错误类型同样保守")
    }

    @Test func sseProgressCarriesStopPresence() {
        func payload(_ data: String) -> ProgressPayload? {
            if case .progress(let p) = BridgeEventDecoder.decode(SSEFrame(id: nil, event: "progress", data: data)) { return p }
            return nil
        }
        #expect(payload(#"{"eventKey":"k","state":"paused"}"#)?.stop == nil)
        #expect(payload(#"{"eventKey":"k","state":"paused","stopDisposition":"not_dispatched"}"#)?.stop == .notDispatched)
        #expect(payload(#"{"eventKey":"k","state":"paused","stopDisposition":null}"#)?.stop == .uncertain)
        #expect(payload(#"{"eventKey":"k","state":"paused","stopDisposition":"zzz"}"#)?.stop == .uncertain)
        #expect(payload(#"{"eventKey":"k","state":"started"}"#)?.state == "started", "旧 Bridge：无新键照常解码")
    }

    @Test func commandRoundTripsStopQueueAndEquality() throws {
        var c = try cmd("paused", stop: "not_dispatched", extra: #","reason":"x","lane":"ordinary","queueDeadlineT":9,"queueReason":null,"queuePosition":null,"observedAt":null,"phase":null"#)
        c.queue = QueueMeta()
        let back = try JSONDecoder().decode(ApiCommand.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        let plain = try cmd("queued")
        #expect(try JSONDecoder().decode(ApiCommand.self, from: JSONEncoder().encode(plain)) == plain, "缺键往返仍是缺键")
    }

    // MARK: A. 合并

    @Test func nonPausedAlwaysClearsStopEvenWithoutQueueGroup() throws {
        var bogus = try cmd("started", stop: "not_dispatched")
        #expect(bogus.queue == nil)
        #expect(CommandMerge.merged(old: nil, new: bogus).stopDisposition == nil, "queue 为 nil 也清")
        bogus.state = "queued"
        #expect(CommandMerge.snapshotMerged(old: nil, new: bogus, touchedDuringRequest: false).stopDisposition == nil)
        let started = try cmd("started")
        let p = CommandMerge.progressed(started, state: "finished", reason: nil, stop: .notDispatched)
        #expect(p.state == "finished" && p.stopDisposition == nil)
    }

    @Test func samePauseLifecycleKeepsStopAcrossAbsentFramesAndOrderedNullDowngrades() throws {
        let paused = try cmd("paused", stop: "not_dispatched")
        #expect(CommandMerge.merged(old: paused, new: try cmd("paused")).stopDisposition == .notDispatched, "旧增量缺键不抹新事实")
        #expect(CommandMerge.progressed(paused, state: "paused", reason: nil).stopDisposition == .notDispatched)
        #expect(CommandMerge.merged(old: paused, new: try cmd("paused", nullStop: true)).stopDisposition == .uncertain, "有序显式 null 撤销“已证明未派发”")
        #expect(CommandMerge.progressed(paused, state: "paused", reason: nil, stop: .uncertain).stopDisposition == .uncertain)
        let uncertain = try cmd("paused", stop: "execution_uncertain")
        #expect(CommandMerge.progressed(uncertain, state: "paused", reason: nil, stop: .notDispatched).stopDisposition == .notDispatched, "有序新有效证明可细化")
    }

    @Test func rejectedBackwardFrameDoesNotLendItsStop() throws {
        let paused = try cmd("paused", stop: "execution_uncertain")
        let backward = try cmd("started", stop: "not_dispatched")
        let m = CommandMerge.merged(old: paused, new: backward)
        #expect(m.state == "paused" && m.stopDisposition == .uncertain)
        let p = CommandMerge.progressed(paused, state: "queued", reason: nil, stop: .notDispatched)
        #expect(p.state == "paused" && p.stopDisposition == .uncertain)
    }

    @Test func pendingProgressFramesMaterializeStopInOrder() throws {
        let queued = try cmd("queued")
        let frames = [ProgressPayload(eventKey: "api:d:1", state: "started"), ProgressPayload(eventKey: "api:d:1", state: "paused", stop: .notDispatched),
                      ProgressPayload(eventKey: "api:d:1", state: "paused")]
        let m = CommandMerge.materialized(queued, pending: frames)
        #expect(m.state == "paused" && m.stopDisposition == .notDispatched, "同一暂停后的缺键帧不抹")
        var pending = PendingProgress()
        pending.put(ProgressPayload(eventKey: "k", state: "paused", stop: .uncertain), seq: 1)
        #expect(pending.take("k", after: nil).first?.stop == .uncertain)
    }

    @Test func snapshotNeverOverwritesNewerSseStopAndKeepsStopOnAbsentHttp() throws {
        let sse = try cmd("paused", stop: "execution_uncertain")
        // 请求期间 SSE 已写入：HTTP 晚到的显式 not_dispatched 不得覆盖，缺键也不抹。
        #expect(CommandMerge.snapshotMerged(old: sse, new: try cmd("paused", stop: "not_dispatched"), touchedDuringRequest: true).stopDisposition == .uncertain)
        #expect(CommandMerge.snapshotMerged(old: sse, new: try cmd("paused"), touchedDuringRequest: true).stopDisposition == .uncertain)
        // 未被 SSE 触碰：权威 HTTP 的显式值有序生效（含 null → 保守）；缺键保留已见事实。
        let seen = try cmd("paused", stop: "not_dispatched")
        #expect(CommandMerge.snapshotMerged(old: seen, new: try cmd("paused", nullStop: true), touchedDuringRequest: false).stopDisposition == .uncertain)
        #expect(CommandMerge.snapshotMerged(old: seen, new: try cmd("paused"), touchedDuringRequest: false).stopDisposition == .notDispatched)
        // SSE 没给值而 HTTP 有值：采纳 HTTP（不丢信息）。
        #expect(CommandMerge.snapshotMerged(old: try cmd("paused"), new: try cmd("paused", stop: "not_dispatched"), touchedDuringRequest: true).stopDisposition == .notDispatched)
    }

    @Test func firstPausedWithoutStopIsConservativeNotNotDispatched() throws {
        let m = CommandMerge.materialized(try cmd("queued"), pending: [ProgressPayload(eventKey: "api:d:1", state: "paused")])
        #expect(m.stopDisposition == nil)
        #expect(OutgoingStatus.phase(.fromCommand(m)) == .stoppedUncertain)
    }

    // MARK: B. 阶段与暂停的共同语义

    private func facts(_ state: String, phase: String? = nil, working: Bool = false) throws -> OutgoingFacts {
        var c = try cmd(state)
        if let phase { c.queue = QueueMeta(phase: phase) }
        return .fromCommand(c, agentWorking: working)
    }

    @Test func phasesAreIdenticalWhetherOrNotTheTargetIsBusy() throws {
        for (phase, expect) in [("dispatch", OutgoingPhase.dispatching), ("awaiting", .awaiting), ("running", .processing)] {
            for busy in [true, false] {
                #expect(OutgoingStatus.phase(try facts("started", phase: phase, working: busy)) == expect)
            }
        }
        #expect(OutgoingStatus.phase(try facts("started", working: true)) == .delivered, "缺 phase：中性，不据目标忙推断")
        #expect(OutgoingStatus.phase(try facts("started", phase: "zzz", working: true)) == .delivered, "未知 phase 同样中性")
    }

    @Test func dispatchPassesTheTrackerBetweenQueuedAndDelivered() {
        var t = OutgoingStatusTracker()
        #expect(t.advance("k", to: .queued) == .queued)
        #expect(t.advance("k", to: .dispatching) == .dispatching, "不被 queued 压住")
        #expect(t.advance("k", to: .awaiting) == .awaiting)
        #expect(t.advance("k", to: .delivered) == .awaiting, "迟到的旧阶段不回退")
        #expect(t.advance("k", to: .processing) == .processing)
        #expect(t.advance("k", to: .awaiting) == .processing)
        #expect(t.advance("k", to: .done) == .done)
        #expect(t.advance("k", to: .processing) == .done, "终态不重开")
        var u = OutgoingStatusTracker()
        _ = u.advance("u", to: .unknown)
        #expect(u.advance("u", to: .processing) == .unknown, "unknown 不回到处理中")
        #expect(u.advance("u", to: .done) == .done)
    }

    @Test func pausedMatrix() throws {
        func phase(_ f: OutgoingFacts) -> OutgoingPhase { OutgoingStatus.phase(f) }
        var base = OutgoingFacts.fromCommand(try cmd("paused", stop: "not_dispatched"))
        #expect(phase(base) == .stopped)
        base.receiptState = "sent"
        #expect(phase(base) == .stoppedUncertain, "与已送达回执冲突：保守")
        base.receiptState = "done"; #expect(phase(base) == .stoppedUncertain)
        base.receiptState = nil; base.receiptMerged = true; #expect(phase(base) == .merged, "并入是既有强事实")
        var native = OutgoingFacts.fromCommand(try cmd("paused", stop: "not_dispatched", extra: #","reason":"native_delivered""#))
        #expect(phase(native) == .nativeDelivered)
        native.commandReason = "native_send_now_requested"; #expect(phase(native) == .nativeSendRequested)
        #expect(phase(.fromCommand(try cmd("paused", stop: "execution_uncertain"))) == .stoppedUncertain)
        #expect(phase(.fromCommand(try cmd("paused", nullStop: true))) == .stoppedUncertain)
        #expect(phase(.fromCommand(try cmd("rejected", extra: #","reason":"withdrawn""#))) == .withdrawn)
        #expect(phase(.fromCommand(try cmd("paused", extra: #","reason":"queue_expired""#))) == .expired)
        #expect(phase(.fromCommand(try cmd("paused", extra: #","reason":"queue_expired_uncertain""#))) == .queueStopped)
        #expect(phase(.fromCommand(try cmd("rejected"))) == .rejected, "真正拒绝仍是被拒绝")
        #expect(phase(.fromCommand(try cmd("unknown"))) == .unknown)
        #expect(phase(.fromCommand(try cmd("finished"))) == .done)
    }

    @Test func trackerRefinesStopClaimsOnlyWithinTheSamePause() {
        var t = OutgoingStatusTracker()
        #expect(t.advance("a", to: .stopped) == .stopped)
        #expect(t.advance("a", to: .stopped) == .stopped, "重复读取一致")
        #expect(t.advance("a", to: .stoppedUncertain) == .stoppedUncertain, "未发出遇到显式 null / 冲突必须变保守")
        #expect(t.advance("a", to: .stopped) == .stopped, "从未见过送达证据：有新有效证明可细化")
        var b = OutgoingStatusTracker()
        _ = b.advance("b", to: .delivered)
        _ = b.advance("b", to: .stoppedUncertain)
        #expect(b.advance("b", to: .stopped) == .stoppedUncertain, "见过送达证据后不得降成未发出")
        var c = OutgoingStatusTracker()
        _ = c.advance("c", to: .unknown)
        _ = c.advance("c", to: .stoppedUncertain)
        #expect(c.advance("c", to: .stopped) == .stoppedUncertain, "unknown 的执行证据同样阻止")
        var d = OutgoingStatusTracker()
        _ = d.advance("d", to: .nativePaused)
        #expect(d.advance("d", to: .stoppedUncertain) == .stoppedUncertain)
        var e = OutgoingStatusTracker()
        _ = e.advance("e", to: .done)
        #expect(e.advance("e", to: .stopped) == .done, "其它终态不重开")
    }

    @Test func receiptUsesTheCommandOnlyOnExactKeyMatch() throws {
        var c = try cmd("started", key: "api:d:7")
        c.queue = QueueMeta(phase: "awaiting")
        let r = TranscriptReceipt(commandKey: "x", origin: "api", receiptState: "sent", eventKey: "api:d:7")
        let wrong = TranscriptReceipt(commandKey: "x", origin: "api", receiptState: "sent", eventKey: "api:d:8")
        let none = TranscriptReceipt(commandKey: "x", origin: "api", receiptState: "sent")
        #expect(OutgoingStatus.phase(.fromReceipt(r, command: c)) == .awaiting)
        #expect(OutgoingStatus.phase(.fromReceipt(wrong, command: c)) == .delivered, "错 key：不借用 command")
        #expect(OutgoingStatus.phase(.fromReceipt(none, command: c)) == .delivered)
        #expect(OutgoingStatus.phase(.fromReceipt(r, command: nil)) == .delivered, "缺 command：沿回执中性")
        let item = TranscriptItem(id: "u", role: "user", text: "x", receipt: r)
        #expect(TranscriptCopy.sourceLine(item, command: c, now: Date(timeIntervalSince1970: 0)).contains("已送达 · 等待回合开始"))
        let pausedC = try cmd("paused", key: "api:d:7", stop: "not_dispatched")
        #expect(TranscriptCopy.sourceLine(TranscriptItem(id: "u", role: "user", text: "x", receipt: .init(commandKey: "x", origin: "api", receiptState: "accepted", eventKey: "api:d:7")), command: pausedC).contains("已停止，未发出"))
    }

    @Test func commandLabelsShareOneSemantics() throws {
        var started = try cmd("started")
        started.queue = QueueMeta(phase: "running")
        let label = OutgoingStatus.label(OutgoingStatus.phase(.fromCommand(started)))
        #expect(SendTimingCopy.commandStatus(started) == label)
        #expect(CurrentActivity.displayLabel(of: started, linked: true, targets: ["t1"]) == label)
        let paused = try cmd("paused")
        #expect(CurrentActivity.displayLabel(of: paused, linked: true, targets: ["t1"]) == "已停止跟踪，可能已执行")
        #expect(CurrentActivity.displayLabel(state: "paused", targetId: "t1", linked: true, targets: ["t1"]) == "已停止跟踪，可能已执行", "只有 state 字符串时同样保守")
        #expect(SendTimingCopy.commandStatus(try cmd("paused", stop: "not_dispatched")) == "已停止，未发出")
        #expect(CurrentActivity.displayLabel(of: started, linked: false, targets: nil) == "状态待同步", "离线 / 待同步的诚实 note 保留")
    }

    // MARK: 卡与期限

    @Test func deadlineIsIndependentOfQueueMetaAndHiddenAfterStart() throws {
        let ms = 1_700_000_000_000
        let noMeta = try cmd("queued", extra: #","queueDeadlineT":\#(ms)"#)
        let card = try #require(QueueStatusPresentation.card(for: noMeta))
        #expect(card.title == "排队中" && card.deadlineText == SendTimingCopy.deadlineText(ms) && card.detail == nil)
        #expect(card.deadlineText?.hasSuffix("前开始，否则不发") == true)
        var withMeta = noMeta
        withMeta.queue = QueueMeta(reason: "draft", position: 2, observedAt: nil)
        #expect(QueueStatusPresentation.card(for: withMeta)?.deadlineText == card.deadlineText)
        #expect(QueueStatusPresentation.card(for: try cmd("queued")) == nil, "两者皆缺不留空行")
        var started = withMeta
        started.state = "started"
        started.queue = QueueMeta(phase: "dispatch")
        #expect(QueueStatusPresentation.card(for: started)?.deadlineText == nil && QueueStatusPresentation.card(for: started)?.title == "正在发送")
        var useLane = noMeta
        useLane.lane = "use"; useLane.queue = QueueMeta()
        #expect(QueueStatusPresentation.card(for: useLane)?.title == "补充排队")
    }

    // MARK: 当前消息窗口

    private func many(_ n: Int, state: String = "queued", from: Int = 1) throws -> [ApiCommand] {
        try (from..<(from + n)).map { try cmd(state, key: "k\($0)", seq: $0) }
    }

    @Test func windowAdmitsOnRealChangeAndEvictsTheOldest() throws {
        var w = CommandWindow()
        let c = try cmd("queued", key: "a", seq: 1)
        let first = w.admit(c), replay = w.admit(c)
        #expect(first && !replay, "未变化的重放不改窗口")
        #expect(w.contains("a") && w.count == 1)
        for x in try many(CommandWindow.capacity - 1, from: 2) { w.admit(x) }
        #expect(w.count == CommandWindow.capacity && !w.truncated)
        var paused = try cmd("paused", key: "s", stop: "execution_uncertain", seq: 500)
        paused.state = "paused"
        w.admit(paused) // 超限：淘汰最旧的“停止”，没有停止则最旧成员
        #expect(w.count == CommandWindow.capacity && w.truncated)
        #expect(!w.contains("a") && w.contains("s"), "最旧的非停止成员被淘汰（此时窗口里只有新停止）")
        w.admit(try cmd("queued", key: "z", seq: 600))
        #expect(w.contains("s") == false || w.count == CommandWindow.capacity)
        #expect(w.count == CommandWindow.capacity)
    }

    @Test func rebuildFromHttpKeepsRecentStopsWithinBudgetAndMarksTruncation() throws {
        var w = CommandWindow()
        let stopA = try cmd("paused", key: "sa", stop: "execution_uncertain", seq: 5)
        w.admit(stopA); w.admit(try cmd("queued", key: "old", seq: 6))
        // 服务端列表不含 sa（被淘汰 / 重启后只能读账本）、含新成员；old 是非暂停：被移除。
        let server = try many(3, from: 10)
        let c1 = w.rebuild(server: server, concurrent: [])
        #expect(c1)
        #expect(w.contains("sa") && !w.contains("old") && w.contains("k10"))
        #expect(!w.truncated)
        // 空列表：移除非暂停旧成员，保留最近停止。
        let c2 = w.rebuild(server: [], concurrent: [])
        #expect(c2)
        #expect(w.contains("sa") && w.count == 1)
        // 满额：服务端 200 条 → 记 truncated，停止只在余位保留（无余位即淘汰），不挤走服务端成员。
        let full = try many(CommandWindow.capacity, from: 1000)
        w.rebuild(server: full, concurrent: [])
        #expect(w.count == CommandWindow.capacity && w.truncated && !w.contains("sa"))
        // 并发合计超限：按 inboxSeq 保留最新。
        var big = CommandWindow()
        big.rebuild(server: try many(CommandWindow.capacity, from: 1), concurrent: try many(5, from: 5000))
        #expect(big.count == CommandWindow.capacity && big.contains("k5004") && !big.contains("k1") && big.truncated)
        w.clear()
        #expect(w.count == 0 && !w.truncated)
    }

    @Test func supplementRowsFollowTheLatestWindowAndDedupRules() throws {
        var w = CommandWindow()
        let cs = [try cmd("queued", key: "q", seq: 3), try cmd("started", key: "s", seq: 2), try cmd("paused", key: "p", stop: "not_dispatched", seq: 1),
                  try cmd("finished", key: "f", seq: 4), try cmd("queued", key: "ghost", seq: 5), try cmd("queued", key: "other", seq: 6)]
        for c in cs where c.key != "ghost" { w.admit(c) }
        var all = cs
        all[5].targetId = "t2"
        func rows(latest: Bool = true, linked: Set<String> = [], covered: Set<String> = [], foreign: Set<String> = []) -> [String] {
            ThreadCommandSupplement.rows(commands: all, window: w, threadId: "t1", linkedKeys: linked, coveredKeys: covered, foreignKeys: foreign, latestWindow: latest).map(\.key)
        }
        #expect(rows() == ["p", "s", "q"], "窗口内 queued / started / paused 补行；finished / 窗口外 / 他线程不补")
        #expect(rows(latest: false).isEmpty, "历史 / 定位窗零强插")
        #expect(rows(linked: ["s"]) == ["p", "q"], "已关联（含不在可见窗口）不补尾")
        #expect(rows(covered: ["q"]) == ["p", "s"], "本机回显 / 期限行已显示：同 key 只一份")
        #expect(rows(foreign: ["p"]) == ["s", "q"], "不同会话代次不冒称属于当前原生会话")
    }

    // MARK: 历史 inbox

    @Test func historyInboxKeepsTheFullCommandAndOldRowsDoNotFail() throws {
        let json = #"{"items":[{"id":"inbox:api:d:1","source":"inbox","key":"api:d:1","inboxSeq":4,"text":"停","truncated":false,"origin":"api","targetId":"t1","state":"paused","stopDisposition":"not_dispatched","createdT":1700},{"id":"inbox:api:d:2","source":"inbox","text":"旧","createdT":1701,"state":"finished"},{"id":"outbox:u1","source":"outbox","text":"回执","t":1702},{"id":"inbox:api:d:3","source":"inbox","key":"api:d:3","text":"缺字段","state":"paused"}],"nextBefore":"1.2","hasMore":true,"partial":false}"#
        let page = try JSONDecoder().decode(TargetHistoryPage.self, from: Data(json.utf8))
        #expect(page.items.count == 4)
        let full = page.items[0]
        #expect(full.command?.stopDisposition == .notDispatched && full.command?.key == "api:d:1" && full.t == 1700)
        #expect(SendTimingCopy.commandStatus(try #require(full.command)) == "已停止，未发出")
        #expect(page.items[1].command == nil && page.items[2].command == nil && page.items[3].command == nil, "旧 / outbox / 缺字段：沿正文与时间，不伪造 eventKey")
        let back = try JSONDecoder().decode(TargetHistoryPage.self, from: JSONEncoder().encode(page))
        #expect(back == page)
        var paging = TargetHistoryPaging()
        paging.apply(page, older: false)
        #expect(paging.items.count == 4 && paging.nextBefore == "1.2", "分页 id / 游标不变")
    }

    // MARK: 复审补修（A1-004）

    @Test func anyEntryRefusesUnsentAfterDeliveryOrUnknownEvidence() {
        for (n, evidence) in [("d", OutgoingPhase.delivered), ("a", .awaiting), ("p", .processing), ("u", .unknown), ("x", .dispatching)] {
            var t = OutgoingStatusTracker()
            _ = t.advance(n, to: evidence)
            #expect(t.advance(n, to: .stopped) == .stoppedUncertain, "\(evidence) → 直接 stopped 也必须保守")
        }
        var native = OutgoingStatusTracker()
        _ = native.advance("n", to: .awaiting)
        #expect(native.advance("n", to: .nativePaused) == .stoppedUncertain, "nativePaused 入口同样")
        var ok = OutgoingStatusTracker()
        #expect(ok.advance("k", to: .stopped) == .stopped, "正控：没有任何送达证据的首次未发出照常显示")
        var done = OutgoingStatusTracker()
        _ = done.advance("e", to: .done)
        #expect(done.advance("e", to: .stopped) == .done, "终态不重开")
    }

    @Test func deliveryEvidenceIsOwnedByFactAdoptionNotByWhenTheViewReads() throws {
        var started = try cmd("started", key: "k")
        started.queue = QueueMeta(phase: "awaiting")
        let paused = try cmd("paused", key: "k", stop: "not_dispatched")
        let stoppedPhase = OutgoingStatus.phase(.fromCommand(paused))
        #expect(stoppedPhase == .stopped)
        var readEarly = OutgoingStatusTracker(), readLate = OutgoingStatusTracker(), neverStarted = OutgoingStatusTracker()
        readEarly.observe(started); _ = readEarly.advance("k", to: OutgoingStatus.phase(.fromCommand(started)))
        readLate.observe(started) // 采纳 started 时记下证据；直到暂停才首次读取
        neverStarted.observe(try cmd("queued", key: "k"))
        let a = readEarly.advance("k", to: stoppedPhase), b = readLate.advance("k", to: stoppedPhase)
        #expect(a == .stoppedUncertain && b == a, "先读 / 后读结论一致")
        #expect(neverStarted.advance("k", to: stoppedPhase) == .stopped, "正控：只见过 queued 的未发出照常")
        var unk = OutgoingStatusTracker()
        unk.observe(try cmd("unknown", key: "k"))
        #expect(unk.advance("k", to: stoppedPhase) == .stoppedUncertain, "unknown 也是证据")
    }

    @Test func receiptEvidenceConflictsStayConservativeAndStrongFactsWin() throws {
        for r in ["sent", "done", "unknown"] {
            var f = OutgoingFacts.fromCommand(try cmd("paused", stop: "not_dispatched"))
            f.receiptState = r
            #expect(OutgoingStatus.phase(f) == .stoppedUncertain, "回执 \(r) 与“未发出”冲突")
        }
        var merged = OutgoingFacts.fromCommand(try cmd("paused", stop: "not_dispatched", extra: #","reason":"merged""#))
        merged.receiptMerged = true
        #expect(OutgoingStatus.phase(merged) == .merged, "强事实优先")
    }

    @Test func needsAdmissionSeparatesContentChangeFromNewActiveMembership() throws {
        var w = CommandWindow()
        let active = try cmd("started", key: "k")
        #expect(w.needsAdmission(active, changed: false), "活动成员不在窗口：同内容再次到来也要准入")
        w.admit(active)
        let replay = w.admit(active)
        #expect(!w.needsAdmission(active, changed: false) && !replay, "已在窗不重复发布")
        #expect(w.needsAdmission(active, changed: true))
        let done = try cmd("finished", key: "old")
        #expect(!w.needsAdmission(done, changed: false), "已淘汰的未变终态不复活")
        let rebuilt = w.rebuild(server: [], concurrent: [])
        #expect(rebuilt)
        #expect(!w.contains("k") && w.needsAdmission(active, changed: false), "HTTP 空列表移除后，同内容活动 inbound 可重新准入")
    }

    @Test func admitAndRebuildApplyTheSameCapacityRule() throws {
        let queued = try many(CommandWindow.capacity, from: 1000)
        let ancient = try cmd("paused", key: "ancient", stop: "not_dispatched", seq: 1)
        var viaAdmit = CommandWindow()
        for c in queued { viaAdmit.admit(c) }
        let changed = viaAdmit.admit(ancient)
        var viaHttp = CommandWindow()
        _ = viaHttp.rebuild(server: queued, concurrent: [ancient])
        for w in [viaAdmit, viaHttp] {
            #expect(!w.contains("ancient") && w.contains("k1000") && w.count == CommandWindow.capacity, "旧停止不因“刚被调用”而免淘汰；更新的活动保留")
            #expect(w.truncated)
        }
        #expect(changed, "成员未变但 truncated 翻转：按真实值发布")
        let again = viaAdmit.admit(ancient)
        #expect(!again, "再次到来：成员与 truncated 都不变，不发布")
        let fresh = viaAdmit.admit(try cmd("queued", key: "fresh", seq: 5000))
        #expect(fresh)
        #expect(viaAdmit.contains("fresh") && !viaAdmit.contains("k1000") && viaAdmit.count == CommandWindow.capacity, "新 seq 活动正控：挤掉最旧")
    }

    @Test func startedLabelIsOneNeutralStringIncludingMissingOrUnknownPhase() throws {
        let delivered = OutgoingStatus.label(.delivered)
        let bare = try cmd("started")
        #expect(CurrentActivity.displayLabel(of: bare, linked: true, targets: ["t1"]) == delivered, "缺 phase")
        var weird = bare; weird.queue = QueueMeta(phase: "from_the_future")
        #expect(CurrentActivity.displayLabel(of: weird, linked: true, targets: ["t1"]) == delivered, "未知 phase")
        #expect(CurrentActivity.displayLabel(state: "started", targetId: "t1", linked: true, targets: ["t1"]) == delivered, "只有 state 字符串")
        var running = bare; running.queue = QueueMeta(phase: "running")
        #expect(CurrentActivity.displayLabel(of: running, linked: true, targets: ["t1"]) == OutgoingStatus.label(.processing))
        #expect(CurrentActivity.displayLabel(of: running, linked: true, targets: []) == "目标已不在 · 结果未确认", "目标消失的诚实分支先于新文案")
        #expect(CurrentActivity.displayLabel(of: bare, linked: true, targets: []) == "目标已不在 · 结果未确认")
        #expect(CurrentActivity.displayLabel(of: running, linked: false, targets: nil) == "状态待同步", "offline / pendingSync 正控")
        #expect(CurrentActivity.displayLabel(of: bare, linked: true, targets: nil) == "状态待同步")
    }

    // MARK: 复审补修 v3（A1-006）

    @Test func progressBeforeTheCommandExistsStillRecordsDeliveryEvidence() throws {
        var t = OutgoingStatusTracker()
        t.observeProgress(key: "k", state: "started", phase: "awaiting")
        t.observeProgress(key: "k", state: "paused")
        #expect(t.advance("k", to: OutgoingStatus.phase(.fromCommand(try cmd("paused", key: "k", stop: "not_dispatched")))) == .stoppedUncertain, "待物化阶段的 started 是证据，物化后只剩 paused 也不得写“未发出”")
        var unknown = OutgoingStatusTracker()
        unknown.observeProgress(key: "u", state: "unknown")
        #expect(unknown.advance("u", to: .stopped) == .stoppedUncertain, "unknown 也是证据")
        var control = OutgoingStatusTracker()
        control.observeProgress(key: "c", state: "queued"); control.observeProgress(key: "c", state: "paused")
        #expect(control.advance("c", to: .stopped) == .stopped, "正控：只见 queued / 首个 paused 的有效 not_dispatched 仍是未发出")
    }

    @Test func aPausedCommandIsNeverReconfirmedIntoTheWindowButNewOrChangedOnesAreAdmitted() throws {
        var w = CommandWindow()
        let paused = try cmd("paused", key: "p", stop: "execution_uncertain", seq: 1)
        #expect(!CommandWindow.isReconfirmable(paused))
        #expect(!w.needsAdmission(paused, changed: false), "不在窗口的同内容 paused 重放：不准入")
        #expect(w.needsAdmission(paused, changed: true), "新的 / 内容真实改变的 paused 仍走 changed 分支")
        for state in ["queued", "started", "unknown"] { #expect(w.needsAdmission(try cmd(state, key: "x"), changed: false), "\(state) 可同内容重新确认") }
        // 先淘汰 → 腾空 → 同内容重放
        w.admit(paused)
        for c in try many(CommandWindow.capacity, from: 1000) { w.admit(c) }
        #expect(!w.contains("p"))
        _ = w.rebuild(server: [], concurrent: [])
        #expect(w.count == 0)
        #expect(!w.needsAdmission(paused, changed: false), "腾空后同内容重放仍不复活")
        let changedStop = try cmd("paused", key: "p", stop: "not_dispatched", seq: 1)
        #expect(w.needsAdmission(changedStop, changed: true) && w.admit(changedStop) && w.contains("p"), "显式 stop 分类改变：按 changed 准入")
    }
}
