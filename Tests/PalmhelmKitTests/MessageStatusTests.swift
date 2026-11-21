import Foundation
import Testing
@testable import PalmhelmKit

// #89 片 B：呈现值（阶段 + 文案 + 排队卡同源）与最新阅读窗尾部投影的纯规则。
@Suite struct MessageStatusTests {
    private func cmd(_ state: String, key: String = "api:d:1", seq: Int = 1, target: String = "t1", extra: String = "") throws -> ApiCommand {
        let s = #"{"key":"\#(key)","inboxSeq":\#(seq),"text":"hi","truncated":false,"origin":"api","state":"\#(state)","targetId":"\#(target)""# + extra + "}"
        return try JSONDecoder().decode(ApiCommand.self, from: Data(s.utf8))
    }
    private func window(_ cs: [ApiCommand]) -> CommandWindow {
        var w = CommandWindow()
        _ = w.rebuild(server: cs, concurrent: [])
        return w
    }
    private func latest(linked: [String] = []) -> TranscriptThread {
        var t = TranscriptThread()
        t.status = .ok
        t.items = linked.map { TranscriptItem(id: "u\($0)", role: "user", text: "x", receipt: .init(commandKey: $0, origin: "api", receiptState: "accepted", eventKey: $0)) }
        return t
    }

    // MARK: 卡与阶段一致

    @Test func phaseCardFollowsTheEffectivePhaseNotTheRawCommand() throws {
        let started = try cmd("started", extra: #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"awaiting""#)
        #expect(QueueStatusPresentation.card(for: started)?.title == OutgoingStatus.label(.awaiting), "原卡按 raw phase")
        // tracker 已推进到更高阶段：卡标题跟有效阶段，不再显示 raw 的 awaiting
        #expect(QueueStatusPresentation.card(for: started, phase: .processing)?.title == OutgoingStatus.label(.processing))
        // tracker 已不确定 / 停止：不得仍展示 raw awaiting 卡（由行文案表达）
        for p in [OutgoingPhase.unknown, .stoppedUncertain, .stopped, .done, .merged, .rejected] {
            #expect(QueueStatusPresentation.card(for: started, phase: p) == nil, "\(p)")
        }
    }

    @Test func queuedCardKeepsTheDeadlineOnlyForEffectiveQueuedPhases() throws {
        let queued = try cmd("queued", extra: #","queueDeadlineT":1790000000000"#)
        #expect(QueueStatusPresentation.card(for: queued, phase: .queued)?.deadlineText != nil)
        #expect(QueueStatusPresentation.card(for: queued, phase: .queuedSteer)?.deadlineText != nil)
        let started = try cmd("started", extra: #","queueDeadlineT":1790000000000,"phase":"running""#)
        #expect(QueueStatusPresentation.card(for: started, phase: .processing)?.deadlineText == nil, "已开始后期限消失")
        // 指令快照仍是 queued，但有效阶段已越过排队：不能继续展示排队卡
        #expect(QueueStatusPresentation.card(for: queued, phase: .awaiting)?.deadlineText == nil)
    }

    @Test func statusLabelAndCardAreOneValue() throws {
        let queued = try cmd("queued", extra: #","queueDeadlineT":1790000000000,"lane":"ordinary""#)
        let s = MessageStatusRules.status(for: queued, phase: .queued)
        #expect(s.label == SendTimingCopy.commandStatus(state: "queued", reason: nil, lane: "ordinary", direct: false, queueDeadlineT: 1790000000000))
        #expect(s.card != nil)
        let stopped = MessageStatusRules.status(for: try cmd("paused"), phase: .stoppedUncertain)
        #expect(stopped.label == OutgoingStatus.label(.stoppedUncertain))
        #expect(stopped.card == nil, "停止不借卡，也必须有可读文案")
    }

    // MARK: 独立求值（只读账本行）

    @Test func standaloneStatusUsesTheSameKitSemanticsWithoutATracker() throws {
        #expect(MessageStatusRules.standalone(try cmd("paused", extra: #","stopDisposition":"not_dispatched""#)).label == OutgoingStatus.label(.stopped))
        #expect(MessageStatusRules.standalone(try cmd("paused", extra: #","stopDisposition":"execution_uncertain""#)).phase == .stoppedUncertain)
        #expect(MessageStatusRules.standalone(try cmd("paused")).phase == .stoppedUncertain, "旧 Bridge 缺键保守")
        #expect(MessageStatusRules.standalone(try cmd("paused", extra: #","stopDisposition":null"#)).phase == .stoppedUncertain)
        #expect(MessageStatusRules.standalone(try cmd("queued", extra: #","queueDeadlineT":1790000000000"#)).card?.deadlineText != nil)
    }

    @Test func strongReceiptResultsAreTheOnesATrackerMustNotOverride() {
        for p in [OutgoingPhase.done, .merged, .nativeDelivered, .withdrawn] { #expect(MessageStatusRules.isStrongReceiptResult(p)) }
        for p in [OutgoingPhase.stopped, .stoppedUncertain, .awaiting, .queued, .unknown] { #expect(!MessageStatusRules.isStrongReceiptResult(p)) }
    }

    // MARK: 来源行

    @Test func sourceLineUsesTheResolvedStatusAndCanOmitItWhenACardCarriesIt() throws {
        let item = TranscriptItem(id: "u", role: "user", text: "x", receipt: .init(commandKey: "k", origin: "api", receiptState: "accepted", eventKey: "api:d:1"))
        let exact = try cmd("paused", key: "api:d:1")           // 与 receipt.eventKey 精确相等
        let plain = TranscriptCopy.sourceLine(item, command: exact)
        let resolved = TranscriptCopy.sourceLine(item, command: exact, resolvedStatus: "已送达 · 回合进行中")
        #expect(resolved.contains("已送达 · 回合进行中") && !resolved.contains("已停止跟踪"), "精确关联：采用父级已解析的状态")
        #expect(plain != resolved)
        let omitted = TranscriptCopy.sourceLine(item, command: exact, resolvedStatus: "已送达 · 回合进行中", showsStatus: false)
        #expect(!omitted.contains("已送达") && !omitted.contains("已停止跟踪"), "精确关联且卡已表达状态时来源行不重复")
        #expect(omitted.hasPrefix(KitL10n.string("经 Palmhelm")))
    }

    // B-F3：新参数不得绕过精确 key 守卫
    @Test func sourceLineOverridesNeverApplyWithoutAnExactlyMatchingCommand() throws {
        let item = TranscriptItem(id: "u", role: "user", text: "x", receipt: .init(commandKey: "k", origin: "api", receiptState: "sent", eventKey: "B"))
        let baseline = TranscriptCopy.sourceLine(item)
        let other = try cmd("paused", key: "A")                 // 别的指令（错 key）
        for command in [other, nil] as [ApiCommand?] {
            let tag = command == nil ? "无 command" : "错 key"
            let polluted = TranscriptCopy.sourceLine(item, command: command, resolvedStatus: "已停止，未发出")
            #expect(polluted == baseline, "\(tag)：外部 override 被忽略，沿原中性来源行")
            #expect(!polluted.contains("未发出"), Comment(rawValue: tag))
            let hidden = TranscriptCopy.sourceLine(item, command: command, resolvedStatus: "已停止，未发出", showsStatus: false)
            #expect(hidden == baseline, "\(tag)：省略状态的请求同样被忽略")
        }
        let noKey = TranscriptItem(id: "u2", role: "user", text: "x", receipt: .init(commandKey: "k", origin: "api", receiptState: "sent"))
        #expect(TranscriptCopy.sourceLine(noKey, command: other, resolvedStatus: "已停止，未发出") == TranscriptCopy.sourceLine(noKey), "回执无 eventKey：不关联")
    }

    // MARK: 尾部投影

    @Test func tailIsEmptyOutsideTheLatestWindow() throws {
        let c = try cmd("paused")
        let w = window([c])
        var pinned = latest()
        pinned.status = .loading
        #expect(ThreadTailRules.tail(commands: [c], window: w, threadId: "t1", transcript: pinned, foreignKeys: [], echoes: { _ in [String]() }, echoKey: { $0 }).commandRows.isEmpty)
        #expect(ThreadTailRules.tail(commands: [c], window: w, threadId: "t1", transcript: nil, foreignKeys: [], echoes: { _ in [String]() }, echoKey: { $0 }).commandRows.isEmpty)
        #expect(ThreadTailRules.tail(commands: [c], window: w, threadId: "t1", transcript: latest(), foreignKeys: [], echoes: { _ in [String]() }, echoKey: { $0 }).commandRows.map(\.key) == [c.key])
    }

    @Test func deadlineRowsFollowWindowLinkAndForeignFilters() throws {
        let a = try cmd("queued", key: "a", seq: 1, extra: #","queueDeadlineT":1790000000000"#)
        let b = try cmd("queued", key: "b", seq: 2, extra: #","queueDeadlineT":1790000000000"#)
        let c = try cmd("queued", key: "c", seq: 3, extra: #","queueDeadlineT":1790000000000"#)
        let outside = try cmd("queued", key: "o", seq: 4, extra: #","queueDeadlineT":1790000000000"#)
        let w = window([a, b, c])
        let rows = ThreadTailRules.deadline(commands: [a, b, c, outside], window: w, linkedKeys: ["b"], foreignKeys: ["c"])
        #expect(rows.map(\.key) == ["a"], "已被记录关联的、其他会话代次的、不在窗口的都不当期限行")
    }

    @Test func aNominalDeadlineRowThatIsNotShownCannotSwallowTheOnlyEcho() throws {
        // 期限行 K 已被记录关联（不显示）：回显 K 不能因“名义上有期限行”被吞掉——回显规则收到的是实际期限键。
        let k = try cmd("queued", key: "K", extra: #","queueDeadlineT":1790000000000"#)
        let w = window([k])
        var seen: Set<String>?
        let tail = ThreadTailRules.tail(commands: [k], window: w, threadId: "t1", transcript: latest(linked: ["K"]), foreignKeys: [],
                                        echoes: { deadlineKeys in seen = deadlineKeys; return ["K"] }, echoKey: { $0 })
        #expect(seen == [], "实际显示的期限键为空")
        #expect(tail.echoes == ["K"])
        #expect(tail.commandRows.isEmpty, "记录已承载同 key，不补尾")
    }

    @Test func echoDeadlineAndSupplementShowEachKeyOnce() throws {
        let q = try cmd("queued", key: "Q", seq: 1, extra: #","queueDeadlineT":1790000000000"#)
        let p = try cmd("paused", key: "P", seq: 2)
        let e = try cmd("started", key: "E", seq: 3)
        let same1 = try cmd("queued", key: "S1", seq: 4)
        let same2 = try cmd("queued", key: "S2", seq: 5)
        let all = [q, p, e, same1, same2]
        let tail = ThreadTailRules.tail(commands: all, window: window(all), threadId: "t1", transcript: latest(), foreignKeys: [],
                                        echoes: { _ in ["E"] }, echoKey: { $0 })
        #expect(tail.deadline.map(\.key) == ["Q"])
        #expect(tail.supplement.map(\.key) == ["P", "S1", "S2"], "回显 E 与期限行 Q 不再补一份；同正文不同 key 各一份")
        #expect(tail.commandRows.map(\.key) == ["Q", "P", "S1", "S2"])
    }

    @Test func otherThreadsAndForeignEpochKeysNeverAppear() throws {
        let other = try cmd("paused", key: "X", target: "t2")
        let foreign = try cmd("paused", key: "F", seq: 2)
        let tail = ThreadTailRules.tail(commands: [other, foreign], window: window([other, foreign]), threadId: "t1", transcript: latest(), foreignKeys: ["F"],
                                        echoes: { _ in [String]() }, echoKey: { $0 })
        #expect(tail.commandRows.isEmpty)
    }
}
