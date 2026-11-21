import Foundation
import Testing
@testable import PalmhelmKit

// #89 联测缺陷 ③：owner 操作（重置占用等）没有排队指令，结果只来自 ack:<eventKey>；不能显示“排队中”，也不能因终态而消失或后移。
@Suite struct OwnerOperationTests {
    private func ack(_ uuid: String, _ text: String, replyTo: String? = nil) -> HistoryItem {
        HistoryItem(seq: 1, uuid: uuid, text: text, kind: "text", replyTo: replyTo)
    }

    @Test func kindOfWireIsStrict() {
        #expect(OwnerOperation.kind(ofWire: "面板") == .panel)
        #expect(OwnerOperation.kind(ofWire: " 任务 ") == .tasks)
        #expect(OwnerOperation.kind(ofWire: "重置占用 q89-b") == .resetOccupancy)
        #expect(OwnerOperation.kind(ofWire: "重置占用 q89-b #k1") == .resetOccupancy)
        #expect(OwnerOperation.kind(ofWire: "切换到 q89-b") == .switchTo)
        // 自然语句、缺空白、仅前缀都不是 owner 操作
        #expect(OwnerOperation.kind(ofWire: "重置占用") == nil)
        #expect(OwnerOperation.kind(ofWire: "重置占用了吗") == nil)
        #expect(OwnerOperation.kind(ofWire: "面板上的按钮坏了") == nil)
        #expect(OwnerOperation.kind(ofWire: "请帮我切换到测试分支") == nil)
        // R2：与服务端整串语法等价——多余参数不是 owner 操作（否则会被当普通输入入队却被当 owner 处理）
        #expect(OwnerOperation.kind(ofWire: "重置占用 alpha 普通说明") == nil)
        #expect(OwnerOperation.kind(ofWire: "重置占用 alpha #k1 多余") == nil)
        #expect(OwnerOperation.kind(ofWire: "重置占用 #k1") == nil)
        #expect(OwnerOperation.kind(ofWire: "重置占用 alpha #") == nil)
        #expect(OwnerOperation.kind(ofWire: "切换到 a b c") == nil)
        #expect(OwnerOperation.kind(ofWire: "面板 任务") == nil)
        // Unicode 空白（U+2003、U+3000、NBSP、BOM）与服务端 JS \s 一致
        #expect(OwnerOperation.kind(ofWire: "重置占用\u{3000}alpha") == .resetOccupancy)
        #expect(OwnerOperation.kind(ofWire: "重置占用 alpha\u{2003}beta") == nil, "alpha 与 beta 是两个 token，服务端整串解析失败")
        #expect(OwnerOperation.kind(ofWire: "切换到\u{a0}alpha\u{2003}beta") == .switchTo, "服务端读成 target=alpha agent=beta")
        #expect(OwnerOperation.kind(ofWire: "switch to a b") == .switchTo)
        #expect(OwnerOperation.kind(ofWire: "Switch a") == .switchTo)
        #expect(OwnerOperation.kind(ofWire: "switch to a b c") == nil)
    }

    @Test func resetAckIsParsedStrictly() {
        #expect(OwnerOperationParser.result(ack: "reset:0") == .reset(released: 0))
        #expect(OwnerOperationParser.result(ack: "reset:12") == .reset(released: 12))
        for bad in ["reset:", "reset:-1", "reset:1x", "reset: 1", "reset:١", "reset:1234567890", "Reset:1", "xreset:1"] {
            #expect(OwnerOperationParser.result(ack: bad) == nil, "\(bad)")
        }
        #expect(OwnerOperationParser.result(ack: "rejected:reset_stale（x）") == .rejected("reset_stale（x）"))
    }

    @Test func resetAckSettlesAResetEchoAndZeroIsASuccess() {
        for text in ["reset:0", "reset:3"] {
            #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: text, ownerKind: .resetOccupancy)) == .done, "\(text)")
        }
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "rejected:target_not_registered", ownerKind: .resetOccupancy)) == .rejected)
    }

    // R2：畸形 / 未知 / 种类不符的回执不造完成（终态 tracker 一旦采纳就无法退回）
    @Test func malformedOrWrongKindAcksNeverSettleAnOwnerEcho() {
        for bad in ["reset:-1", "reset:", "reset:1x", "switched:", "switched:t@3", "queued:task:x", "ack", "", "random text"] {
            #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: bad, ownerKind: .resetOccupancy)) == .ownerSubmitted, "reset ← \(bad.debugDescription)")
        }
        for bad in ["reset:1", "switched:", "queued:task:x", "", "random text"] {
            #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: bad, ownerKind: .switchTo)) == .ownerSubmitted, "switch ← \(bad.debugDescription)")
        }
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "switched:t@3", ownerKind: .switchTo)) == .done)
        for kind in [OwnerOperationKind.panel, .tasks] {
            #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "任务列表…", ownerKind: kind)) == .done, "面板 / 任务的结果片")
            #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "queued:task:x", ownerKind: kind)) == .ownerSubmitted)
            #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "reset:1", ownerKind: kind)) == .ownerSubmitted)
        }
        for kind in [OwnerOperationKind.panel, .tasks, .resetOccupancy, .switchTo] {
            #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "rejected:x", ownerKind: kind)) == .rejected, "\(kind)")
        }
    }

    @Test func aQueuedAckBeforeTheCommandSnapshotDoesNotLockAFalseTerminal() {
        // queued: 回执先到、命令快照后到：先是已提交（非终态），命令到达后以命令为准
        var t = OutgoingStatusTracker()
        let early = OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "queued:task:x", ownerKind: .resetOccupancy))
        #expect(t.advance("k", to: early) == .ownerSubmitted)
        let started = OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, commandState: "started", ackText: "queued:task:x", commandPhase: "awaiting", ownerKind: .resetOccupancy))
        #expect(t.advance("k", to: started) == .awaiting, "命令事实后到仍能前进，没有被假终态锁住")
    }

    @Test func ownerWithoutAckIsSubmittedNotQueued() {
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ownerKind: .resetOccupancy)) == .ownerSubmitted)
        #expect(OutgoingStatus.label(.ownerSubmitted) == "已提交操作，等待结果")
        #expect(!OutgoingPhase.ownerSubmitted.isTerminal)
        #expect(OutgoingStatus.phase(OutgoingFacts(ownerKind: .panel)) == .sending)
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: false, localError: true, ownerKind: .panel)) == .failed)
    }

    @Test func aRealCommandStillWinsAndOrdinaryMessagesAreUntouched() {
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, commandState: "queued", ackText: "reset:1", ownerKind: .resetOccupancy)) == .queued)
        // 普通消息：ack 里出现 reset:1 不是系统事实，仍按排队
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "reset:1")) == .queued)
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true)) == .queued)
    }

    // R1：Bridge 的 outbox 触发器为 ack:<K> 回填 reply_to=K；双重关联缺一不采纳（null 不是新 Bridge 的成功证据）
    @Test func ackNeedsTheExactIdentityOnBothUuidAndReplyTo() {
        let items = [ack("ack:k1", "reset:2"), ack("ack:k2", "reset:5", replyTo: "other"), ack("ack:k3", "reset:7", replyTo: "k3"), ack("u1", "reset:9", replyTo: "k4"), ack("ack:k5:p2", "第二片", replyTo: "k5")]
        #expect(OutgoingFacts.ackText(eventKey: "k1", in: items) == nil, "缺 replyTo 不采纳")
        #expect(OutgoingFacts.ackText(eventKey: "k2", in: items) == nil, "replyTo 对不上不采纳")
        #expect(OutgoingFacts.ackText(eventKey: "k3", in: items) == "reset:7")
        #expect(OutgoingFacts.ackText(eventKey: "k4", in: items) == nil, "普通正文的 reset:9 不是系统事实")
        #expect(OutgoingFacts.ackText(eventKey: "k5", in: items) == nil, "分片 uuid 不是首片身份")
    }

    @Test func summaryReadsAsAResultWithConsequences() {
        #expect(ReceiptText.summary("reset:0").contains("没有需要停止跟踪"))
        #expect(ReceiptText.summary("reset:3").contains("3"))
        #expect(ReceiptText.summary("reset:3").contains("终端里的 agent 不受影响"))
        #expect(ReceiptText.summary("reset:-1") == "reset:-1", "畸形原样，不编造成功")
        #expect(ReceiptText.summary("switched:") == "已切换到 ", "空 switched 不被当成有效结果（仍走旧摘要）")
    }

    @Test func resetRequestNeedsALosslesslyParseableTargetId() {
        let scope = LedgerScope(targetId: "q89-b", epoch: 3, bridgeId: "b", accountId: "a")
        let r = OwnerResetRequest(scope: scope, displayName: "q89-b")
        #expect(r?.command == "重置占用 q89-b")
        #expect(r?.scope == scope)
        for bad in ["", "a b", "a\tb", "a#b", "#a", "a\nb", "a\u{2003}b"] {
            #expect(OwnerResetRequest(scope: LedgerScope(targetId: bad, epoch: 1, bridgeId: "b"), displayName: "x") == nil, "\(bad.debugDescription)")
        }
        // 不带“派给”包装、不带条件 key
        #expect(!(r?.command.contains("派给") ?? true))
        #expect(!(r?.command.contains("#") ?? true))
    }

    @Test func placementKeepsOpsAfterTheirAnchorAndDegradesWhenTheAnchorIsGone() {
        let ops: [(op: String, anchor: String?)] = [("a", "i1"), ("b", "i1"), ("c", "gone"), ("d", nil), ("e", "i3")]
        let p = OwnerPlacementRules.place(ops, visibleItemIds: ["i1", "i2", "i3"], allowLocal: true)
        #expect(p.after == ["i1": ["a", "b"], "i3": ["e"]])
        #expect(p.local == ["c", "d"], "没有锚 / 锚不可见：明确分组，不猜位置")
        let history = OwnerPlacementRules.place(ops, visibleItemIds: ["i1"], allowLocal: false)
        #expect(history.after == ["i1": ["a", "b"]])
        #expect(history.local.isEmpty, "历史 / 定位窗不追加本机操作记录组")
    }
}
