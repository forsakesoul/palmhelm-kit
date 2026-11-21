import Foundation
import Testing
@testable import PalmhelmKit

// O1-365：发送状态机——事实到阶段、文案、单调性与两端共用的一行文案。
@Suite struct OutgoingStatusTests {
    @Test func localSendWithoutAcceptanceIsSendingAndAcceptedIsQueued() {
        #expect(OutgoingStatus.phase(OutgoingFacts()) == .sending)
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true)) == .queued)
        #expect(OutgoingStatus.phase(OutgoingFacts(commandState: "queued")) == .queued)
        #expect(OutgoingStatus.phase(OutgoingFacts(commandState: "queued", steer: true)) == .queuedSteer)
    }

    @Test func deliveredProcessingAndDoneFollowTheCommandPhaseNotTargetBusy() {
        #expect(OutgoingStatus.phase(OutgoingFacts(receiptState: "sent")) == .delivered)
        #expect(OutgoingStatus.phase(OutgoingFacts(receiptState: "sent", agentWorking: true)) == .delivered, "目标忙不等于本条处理中")
        #expect(OutgoingStatus.phase(OutgoingFacts(commandState: "started", agentWorking: true)) == .delivered, "旧 Bridge 缺阶段：中性已送达")
        #expect(OutgoingStatus.phase(OutgoingFacts(commandState: "started", commandPhase: "running")) == .processing)
        #expect(OutgoingStatus.phase(OutgoingFacts(commandState: "finished")) == .done)
        #expect(OutgoingStatus.phase(OutgoingFacts(receiptState: "done")) == .done)
    }

    @Test func unknownIsNotProcessingAndTerminalStatesWin() {
        #expect(OutgoingStatus.phase(OutgoingFacts(commandState: "unknown", agentWorking: true)) == .unknown, "结果未知不显示处理中")
        #expect(OutgoingStatus.phase(OutgoingFacts(commandState: "rejected", commandReason: "withdrawn")) == .withdrawn)
        #expect(OutgoingStatus.phase(OutgoingFacts(commandState: "rejected", rejectText: "目标已不在")) == .rejected)
        #expect(OutgoingStatus.phase(OutgoingFacts(commandState: "finished", receiptMerged: true)) == .merged)
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, localError: true)) == .failed)
    }

    @Test func labelsAreTheOneSharedOneLineCopy() {
        #expect(OutgoingStatus.label(.queued) == "排队中 · 本轮结束后发送")
        #expect(OutgoingStatus.label(.queuedSteer) == "补充排队中 · 将并入当前回合")
        #expect(OutgoingStatus.label(.delivered) == "已送达")
        #expect(OutgoingStatus.label(.processing) == "已送达 · 回合进行中")
        #expect(OutgoingStatus.label(.done) == "已完成")
        #expect(OutgoingStatus.label(.rejected, rejectText: "目标已不在") == "未发出 · 目标已不在")
        #expect(OutgoingStatus.label(.failed) == "发送失败 · 重试")
        #expect(OutgoingStatus.line(label: "已送达", time: "今天 10:42") == "已送达 · 今天 10:42")
        #expect(OutgoingStatus.line(label: "处理中", time: nil) == "处理中")
        #expect(OutgoingStatus.label(.dispatching) == "正在发送")
        #expect(OutgoingStatus.label(.awaiting) == "已送达 · 等待回合开始")
        #expect(OutgoingStatus.label(.stopped) == "已停止，未发出")
        #expect(OutgoingStatus.label(.stoppedUncertain) == "已停止跟踪，可能已执行")
    }

    @Test func trackerOnlyMovesForward() {
        var t = OutgoingStatusTracker()
        #expect(t.advance("k", to: .queued) == .queued)
        #expect(t.advance("k", to: .processing) == .processing)
        #expect(t.advance("k", to: .queued) == .processing, "迟到的排队事实不把处理中拉回排队")
        #expect(t.advance("k", to: .done) == .done)
        #expect(t.advance("k", to: .processing) == .done, "终态后不再变化")
    }

    @Test func unknownResolvesOnlyToATerminalState() {
        var t = OutgoingStatusTracker()
        _ = t.advance("u", to: .processing)
        #expect(t.advance("u", to: .unknown) == .unknown)
        #expect(t.advance("u", to: .processing) == .unknown, "unknown 之后不会回到处理中")
        #expect(t.advance("u", to: .done) == .done)
    }

    @Test func keysAreIndependent() {
        var t = OutgoingStatusTracker()
        _ = t.advance("a", to: .done)
        #expect(t.advance("b", to: .queued) == .queued)
        #expect(t.current("a") == .done && t.current("b") == .queued)
    }

    // O1-068：原生直达插话被暂停且 Bridge 证明未派发时是独立的未送达阶段；没有证明的 generic paused 不能自行断言未发。
    @Test func pausedNativeInsertNeedsProofOfNotDispatched() {
        let native = OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, commandState: "paused", steer: true, nativeSteer: true, stop: .notDispatched))
        #expect(native == .nativePaused)
        #expect(OutgoingStatus.label(native) == "未发送 · 已暂停，不会自动重发")
        #expect(native.isTerminal)
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, commandState: "paused", steer: true, nativeSteer: true)) == .stoppedUncertain, "缺键：不由路由类型推断未发送")
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, commandState: "paused")) == .stoppedUncertain, "普通 paused 不再是“被拒绝”")
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, commandState: "paused", stop: .notDispatched)) == .stopped)
        #expect(SendTimingCopy.commandStatus(state: "paused", reason: nil, lane: "use", direct: true, stop: .notDispatched) == "未发送 · 已暂停，不会自动重发", "服务端指令行与本机回显同一文案")
    }
}
