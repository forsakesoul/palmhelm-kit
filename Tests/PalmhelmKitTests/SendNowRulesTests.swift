import Foundation
import Testing
@testable import PalmhelmKit

// 立即发送（mode=send_now，可能另起一轮）的客户端规则：能力三态、线上形状、排队动作、回执投影。
@Suite struct SendNowRulesTests {
    private func command(state: String, reason: String? = nil, lane: String? = "use", direct: String? = "claude") -> ApiCommand {
        var c = ApiCommand(key: "k", inboxSeq: 1, text: "x", origin: "api", state: state, reason: reason, lane: lane)
        c.directAgent = direct
        return c
    }

    @Test func capabilityNativeSendNowIsTriState() throws {
        let old = try JSONDecoder().decode(TargetCapabilities.self, from: Data(#"{"steer":true}"#.utf8))
        #expect(old.nativeSendNow == nil, "旧 Bridge 缺字段 = 隐藏")
        let off = try JSONDecoder().decode(TargetCapabilities.self, from: Data(#"{"steer":false,"nativeSendNow":false}"#.utf8))
        #expect(off.nativeSendNow == false, "false 灰显")
        let on = try JSONDecoder().decode(TargetCapabilities.self, from: Data(#"{"steer":false,"nativeSendNow":true}"#.utf8))
        #expect(on.nativeSendNow == true)
        #expect(on.nativeSteer == nil, "send_now 能力不借 nativeSteer")
    }

    @Test func sendNowEncodesOnTheWireAndDefaultsStayUnchanged() throws {
        let id = UUID()
        let sendNow = try JSONEncoder().encode(SendMessageBody(clientMsgId: id.uuidString.lowercased(), text: "hi", mode: SendMode.sendNow.rawValue))
        #expect(String(decoding: sendNow, as: UTF8.self).contains(#""mode":"send_now""#))
        let plain = try JSONEncoder().encode(SendMessageBody(clientMsgId: "a", text: "hi", mode: nil))
        #expect(!String(decoding: plain, as: UTF8.self).contains("mode"), "缺省请求体不变")
    }

    @Test func promoteAcceptsOnlyTheRequestedMode() throws {
        let body = Data(#"{"eventKey":"k","mode":"steer","state":"queued"}"#.utf8)
        #expect(throws: MessageActionError.invalidResponse) {
            try MessageActions.decodePromote(eventKey: "k", mode: .sendNow, status: 200, data: body)
        }
        let sendNow = Data(#"{"eventKey":"k","mode":"send_now","state":"queued"}"#.utf8)
        #expect(try MessageActions.decodePromote(eventKey: "k", mode: .sendNow, status: 200, data: sendNow).eventKey == "k")
        #expect(try MessageActions.decodePromote(eventKey: "k", status: 200, data: body).eventKey == "k", "默认 steer 兼容")
    }

    @Test func commandDecodesModeAndToleratesUnknownValues() throws {
        let known = try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"k","inboxSeq":1,"text":"x","truncated":false,"origin":"api","state":"queued","mode":"send_now"}"#.utf8))
        #expect(known.mode == "send_now")
        let future = try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"k","inboxSeq":1,"text":"x","truncated":false,"origin":"api","state":"queued","mode":"future"}"#.utf8))
        #expect(future.state == "queued", "未知 mode 不使整条解码失败")
        let legacy = try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"k","inboxSeq":1,"text":"x","truncated":false,"origin":"api","state":"queued"}"#.utf8))
        #expect(legacy.mode == nil, "缺省不等于 steer")
    }

    @Test func menuShowsSendNowOnlyForDirectTargetsWithDeclaredCapability() {
        let hidden = SendTimingRules.menu(steer: .unavailable, direct: true, nativeSteer: false, nativeSendNow: nil)
        #expect(!hidden.contains { $0.choice == .sendNow }, "nil 隐藏")
        let bound = SendTimingRules.menu(steer: .available, direct: false, nativeSteer: false, nativeSendNow: true)
        #expect(!bound.contains { $0.choice == .sendNow }, "绑定目标永不出现")
        let disabled = SendTimingRules.menu(steer: .available, direct: true, nativeSteer: true, nativeSendNow: false)
        let off = disabled.first { $0.choice == .sendNow }
        #expect(off?.enabled == false && off?.disabledReason == SendTimingCopy.directNoSteer, "false 灰显带短原因，hook steer 与 nativeSteer 都不授权")
        let on = SendTimingRules.menu(steer: .unavailable, direct: true, nativeSteer: false, nativeSendNow: true)
        #expect(on.first { $0.choice == .sendNow }?.enabled == true)
        #expect(SendMenuChoice.sendNow.title == "立即发送（可能另起一轮）")
        #expect(SendMenuChoice.sendNow.mode == .sendNow)
        #expect(SendMenuChoice.steerNow.mode == .steer, "既有插入项不变")
    }

    @Test func queuedSendNowFollowsTheOriginalRouteAndItsOwnCapability() {
        let queued = "queued"
        func items(direct: Bool, steer: SteerAvailability = .unavailable, nativeSendNow: Bool?) -> [QueuedActionItem] {
            SendTimingRules.queuedActionItems(state: queued, reason: nil, steer: steer, direct: direct, nativeSteer: false, nativeSendNow: nativeSendNow)
        }
        #expect(!items(direct: true, nativeSendNow: nil).contains { $0.action == .promoteSendNow }, "nil 隐藏")
        let off = items(direct: true, nativeSendNow: false).first { $0.action == .promoteSendNow }
        #expect(off?.enabled == false && off?.disabledReason == SendTimingCopy.directNoSteer, "false 灰显，入口同源")
        #expect(items(direct: true, nativeSendNow: true).first { $0.action == .promoteSendNow }?.enabled == true)
        #expect(!items(direct: false, steer: .available, nativeSendNow: true).contains { $0.action == .promoteSendNow }, "原绑定消息不借能力升级")
        #expect(!items(direct: true, steer: .available, nativeSendNow: nil).contains { $0.action == .promoteSendNow }, "hook steer 不授权立即发送")
        #expect(SendTimingRules.queuedActions(state: queued, reason: nil, steer: .available, direct: false, nativeSteer: false, nativeSendNow: nil) == [.withdraw, .promote], "绑定排队动作不变")
        #expect(QueuedAction.promoteSendNow.title == "改为立即发送（可能另起一轮）", "风险提示在标题里")
    }

    @Test func sendNowRejectionsUseSendNowCopy() {
        #expect(SendTimingCopy.text(for: .steerUnavailable(reason: .notDirect), sendNow: true) == "这条消息不是直达，不能立即发送")
        #expect(SendTimingCopy.text(for: .steerUnavailable(reason: .hookTarget), sendNow: true) == "此目标使用 hook 模式，不能按原生直达立即发送")
        #expect(SendTimingCopy.text(for: .steerUnavailable(reason: nil), sendNow: true) == "立即发送暂不可用，未发出")
        #expect(SendTimingCopy.text(for: .steerUnavailable(reason: .rejectedReplay), sendNow: true) == "同一消息已有不同发送方式，本次变更未被接受；请查看原消息状态", "rejected_replay 不改原记录")
        #expect(SendTimingCopy.text(for: .steerUnavailable(reason: .notDirect)) == SendTimingCopy.steerNotDirect, "插入的文案不变")
    }

    @Test func requestedAndSkippedProjectWithoutFailureOrRetry() {
        let requested = OutgoingFacts(hasEventKey: true, commandState: "finished", commandReason: "native_send_now_requested", nativeSteer: true)
        #expect(OutgoingStatus.phase(requested) == .nativeSendRequested)
        #expect(OutgoingStatus.label(.nativeSendRequested) == "已送达并提交立即发送快捷键（可能另起一轮，处理未验证）")
        let skipped = OutgoingFacts(hasEventKey: true, commandState: "finished", commandReason: "native_send_now_skipped", nativeSteer: true)
        #expect(OutgoingStatus.phase(skipped) == .nativeSendSkipped)
        #expect(OutgoingStatus.label(.nativeSendSkipped) == "文字已送达，未触发立即发送", "部分结果，不可报未发送")
        #expect(OutgoingPhase.nativeSendRequested.isTerminal && OutgoingPhase.nativeSendSkipped.isTerminal)
        let pending = OutgoingFacts(hasEventKey: true, commandState: "finished", nativeSteer: true)
        #expect(OutgoingStatus.phase(pending) == .nativePending, "send_now 发出后无 reason 先是待确认")
        #expect(SendTimingCopy.commandStatus(state: "finished", reason: "native_send_now_skipped", lane: "use", direct: true) == "文字已送达，未触发立即发送")
        #expect(SendTimingCopy.statusText(state: "finished", reason: "native_send_now_requested") == "已送达并提交立即发送快捷键（可能另起一轮，处理未验证）")
        #expect(SendTimingRules.isQueuedFamily(state: "finished", reason: "native_send_now_skipped"))
        let unknown = OutgoingFacts(hasEventKey: true, commandState: "unknown", nativeSteer: true)
        #expect(OutgoingStatus.phase(unknown) == .unknown, "unknown 不当未发送")
    }

    @Test func trackerRefinesDoneAndPendingButNeverRegresses() {
        var t = OutgoingStatusTracker()
        #expect(t.advance("a", to: .done) == .done)
        #expect(t.advance("a", to: .nativeSendRequested) == .nativeSendRequested, "finished 先到，requested 后到")
        #expect(t.advance("a", to: .done) == .nativeSendRequested, "迟到无 reason 不冲掉")
        #expect(t.advance("a", to: .nativeSendSkipped) == .nativeSendRequested, "终态之后不再变化")

        var p = OutgoingStatusTracker()
        #expect(p.advance("b", to: .nativePending) == .nativePending)
        #expect(p.advance("b", to: .nativeSendSkipped) == .nativeSendSkipped, "待确认经 skipped 收束")

        var s = OutgoingStatusTracker()
        #expect(s.advance("c", to: .done) == .done)
        #expect(s.advance("c", to: .nativeSendSkipped) == .nativeSendSkipped)
    }

    /// 与 t15：只有 send_now 的原生资格扩展到 requested/skipped；绑定与普通直达完成不变。
    @Test func nativeEligibilityIncludesSendNowButNotPlainDirectDone() {
        let sendNow = command(state: "finished", reason: "native_send_now_requested")
        #expect(sendNow.reason == "native_send_now_requested" && sendNow.directAgent != nil && sendNow.lane == "use")
        #expect(!SendTimingRules.isNativePending(command(state: "finished", lane: "ordinary")), "普通直达完成不是待确认")
    }

    // 立即发送的拒绝文案按操作区分；重放冲突是中性说明，不声称原消息未发出。
    @Test func allSendNowRefusalsUseTheirOwnOperation() {
        for reason: SteerUnavailableReason in [.ownerOnly, .notHook, .hookTarget, .unsupportedEngine, .memberTarget] {
            let copy = SendTimingCopy.text(for: .steerUnavailable(reason: reason), sendNow: true)
            #expect(!copy.contains("插入"), "\(reason): \(copy)")
        }
    }

    @Test func replayConflictDoesNotClaimOriginalWasNeverSent() {
        let copy = SendTimingCopy.text(for: .steerUnavailable(reason: .rejectedReplay))
        #expect(!copy.contains("未发出"), "send_now original replayed with another intent: \(copy)")
    }
}
