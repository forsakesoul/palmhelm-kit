import Foundation
import Testing
@testable import PalmhelmKit

// 直达原生插话（nativeSteer）的客户端规则：能力缺省 = 不支持；路由按原消息；native_delivered 只表示已写入、并入未验证。
@Suite struct NativeSteerRulesTests {
    private func command(state: String, reason: String? = nil, lane: String? = nil, direct: String? = nil) -> ApiCommand {
        var c = ApiCommand(key: "k", inboxSeq: 1, text: "x", origin: "api", state: state, reason: reason, lane: lane)
        c.directAgent = direct
        return c
    }

    @Test func capabilityDecodesOldAndNewBridgeShapes() throws {
        let old = try JSONDecoder().decode(TargetCapabilities.self, from: Data(#"{"steer":true}"#.utf8))
        #expect(old.nativeSteer == nil)
        let new = try JSONDecoder().decode(TargetCapabilities.self, from: Data(#"{"steer":false,"nativeSteer":true}"#.utf8))
        #expect(new.nativeSteer == true)
    }

    @Test func nativeSteerIsOnlyTrueWhenDeclaredTrue() {
        let target = { (caps: TargetCapabilities?) in TargetSummary(projectName: "p", targetId: "t", capabilities: caps) }
        #expect(!target(nil).nativeSteerEnabled)
        #expect(!target(TargetCapabilities(steer: true)).nativeSteerEnabled, "hook steer 不授权直达")
        #expect(!target(TargetCapabilities(steer: true, nativeSteer: false)).nativeSteerEnabled)
        #expect(target(TargetCapabilities(steer: false, nativeSteer: true)).nativeSteerEnabled)
    }

    @Test func directMenuFollowsNativeSteerNotHookSteer() {
        let off = SendTimingRules.menu(steer: .available, direct: true, nativeSteer: false)
        #expect(!off[1].enabled && off[1].disabledReason == SendTimingCopy.directNoSteer, "hook steer=true 不能放开直达")
        let on = SendTimingRules.menu(steer: .unavailable, direct: true, nativeSteer: true)
        #expect(on[1].enabled && on[1].disabledReason == nil)
        #expect(SendTimingRules.menu(steer: .available)[1].enabled, "绑定目标仍按 hook steer")
    }

    /// Watch 只用 primaryMode（从不产生 steer）：直达即使 nativeSteer=true 也是普通发送，绑定工作中是排队。
    @Test func watchPrimaryModeNeverSteersNatively() {
        #expect(SendTimingRules.primaryMode(direct: true, targetStatus: "working") == nil)
        #expect(SendTimingRules.primaryMode(direct: false, targetStatus: "working") == .queue)
    }

    @Test func commandReturnForDirectIsOrdinaryQueueWhileWorking() {
        #expect(SendTimingRules.commandReturn(working: true, steer: .available, direct: true) == .send(nil))
        #expect(SendTimingRules.commandReturn(working: true, steer: .unavailable, direct: true) == .send(nil))
        #expect(SendTimingRules.commandReturn(working: true, steer: .available) == .send(.steer), "绑定目标 ⌘↩ 行为不变")
    }

    @Test func queuedActionsRouteByOriginalCommand() {
        let queued = "queued"
        #expect(SendTimingRules.queuedActions(state: queued, reason: nil, steer: .unavailable, direct: true, nativeSteer: true) == [.withdraw, .promote], "原直达，原目标支持 native")
        #expect(SendTimingRules.queuedActions(state: queued, reason: nil, steer: .available, direct: true, nativeSteer: false) == [.withdraw], "原直达，hook steer 不授权")
        #expect(SendTimingRules.queuedActions(state: queued, reason: nil, steer: .available, direct: false, nativeSteer: false) == [.withdraw, .promote], "原绑定，hook steer 授权")
        #expect(SendTimingRules.queuedActions(state: queued, reason: nil, steer: .unavailable, direct: false, nativeSteer: true) == [.withdraw], "原绑定不因 native 能力启用")
    }

    @Test func nativeDeliveredAndPendingAreNotDone() {
        var pending = command(state: "finished", lane: "use", direct: "claude")
        #expect(SendTimingRules.isNativePending(pending))
        #expect(OutgoingStatus.label(.nativePending) == "待确认")
        pending.reason = "native_delivered"
        #expect(!SendTimingRules.isNativePending(pending))
        #expect(SendTimingRules.isQueuedFamily(state: "finished", reason: "native_delivered"))
        #expect(SendTimingCopy.commandStatus(state: "finished", reason: "native_delivered", lane: "use") == "已送达工作中终端，尚未确认并入本轮")
        #expect(CurrentActivity.displayLabel(of: pending, linked: true, targets: nil) == "已送达工作中终端，尚未确认并入本轮")
        #expect(!SendTimingRules.isNativePending(command(state: "finished", lane: "ordinary", direct: "claude")), "普通直达完成不是待确认")
    }

    @Test func nativeDeliveredPhaseAndPendingPhase() {
        let delivered = OutgoingFacts(hasEventKey: true, commandState: "finished", commandReason: "native_delivered", nativeSteer: true)
        #expect(OutgoingStatus.phase(delivered) == .nativeDelivered)
        #expect(OutgoingStatus.label(.nativeDelivered) == "已送达工作中终端，尚未确认并入本轮")
        let pending = OutgoingFacts(hasEventKey: true, commandState: "finished", nativeSteer: true)
        #expect(OutgoingStatus.phase(pending) == .nativePending)
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, commandState: "finished")) == .done)
    }

    /// C2'：普通 done 保持已完成（含其他设备、飞书）；原生插话的回执本就是 unknown；只有精确 eventKey 的权威指令才细化。
    @Test func receiptStateIsKeptUnlessAnExactAuthoritativeCommandRefinesIt() {
        let apiDone = TranscriptReceipt(commandKey: "k", origin: "api", receiptState: "done")
        #expect(OutgoingStatus.phase(.fromReceipt(apiDone)) == .done, "普通 done 不降级")
        let feishu = TranscriptReceipt(commandKey: "k", origin: "feishu", receiptState: "done")
        #expect(OutgoingStatus.phase(.fromReceipt(feishu)) == .done)
        let native = TranscriptReceipt(commandKey: "k", origin: "api", receiptState: "unknown", eventKey: "k")
        #expect(OutgoingStatus.phase(.fromReceipt(native)) == .unknown, "原生回执本就是 unknown")
        let linkedNative = command(state: "finished", lane: "use", direct: "claude")
        #expect(OutgoingStatus.phase(.fromReceipt(native, command: linkedNative)) == .nativePending, "精确关联 + 无 reason：待确认")
        #expect(OutgoingStatus.phase(.fromReceipt(native, command: { var c = linkedNative; c.reason = "native_delivered"; return c }())) == .nativeDelivered)
        #expect(OutgoingStatus.phase(.fromReceipt(apiDone, command: command(state: "finished"))) == .done, "普通完成仍是已完成")
    }

    /// R2：原生排队只说会写入工作中终端，不承诺并入；hook 排队文案不变。
    @Test func nativeQueuedLabelDoesNotPromiseMerge() {
        let queued = OutgoingFacts(hasEventKey: true, commandState: "queued", steer: true, nativeSteer: true)
        #expect(OutgoingStatus.phase(queued) == .queuedNative)
        #expect(!OutgoingStatus.label(.queuedNative).contains("将并入"))
        #expect(!SendTimingCopy.commandStatus(state: "queued", reason: nil, lane: "use", direct: true).contains("将并入"))
        #expect(OutgoingStatus.label(.queuedSteer) == "补充排队中 · 将并入当前回合", "绑定 hook 排队不变")
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, commandState: "queued", steer: true)) == .queuedSteer)
    }

    /// R6：hook_target 是目标使用 hook 模式（与 not_hook 相反），文案不能说反。
    @Test func hookTargetCopyIsNotTheOppositeOfNotHook() throws {
        let body = Data(#"{"error":"steer_unavailable","reason":"hook_target"}"#.utf8)
        let mapped = MessageActions.error(status: 409, data: body)
        #expect(mapped == .steerUnavailable(reason: .hookTarget))
        #expect(SendTimingCopy.text(for: mapped) == "此目标使用 hook 模式，不能按原生直达立即插入")
        #expect(SendTimingCopy.text(for: .steerUnavailable(reason: .notHook)) == "这个目标不是 Claude Code hook 模式，不能立即插入")
    }

    @Test func trackerAllowsOnlyTheDoneToNativeDeliveredRefinement() {
        var t = OutgoingStatusTracker()
        #expect(t.advance("a", to: .done) == .done)
        #expect(t.advance("a", to: .nativeDelivered) == .nativeDelivered, "done 经权威快照细化为 native_delivered")
        #expect(t.advance("a", to: .done) == .nativeDelivered, "细化后不回退")

        var p = OutgoingStatusTracker()
        #expect(p.advance("b", to: .nativePending) == .nativePending)
        #expect(p.advance("b", to: .processing) == .nativePending, "待确认不回到处理中")
        #expect(p.advance("b", to: .nativeDelivered) == .nativeDelivered)
    }

    @Test func steerRejectReasonsMapToFixedCopy() throws {
        let body = Data(#"{"error":"steer_unavailable","reason":"not_observed"}"#.utf8)
        #expect(MessageActions.error(status: 409, data: body) == .steerUnavailable(reason: .notObserved))
        let unknown = Data(#"{"error":"steer_unavailable","reason":"something_new"}"#.utf8)
        let mapped = MessageActions.error(status: 409, data: unknown)
        #expect(mapped == .steerUnavailable(reason: nil))
        #expect(SendTimingCopy.text(for: mapped) == "立即插入暂不可用，未发出", "未知 reason 不回显服务端字符串")
        for reason in SteerUnavailableReason.allCases {
            let text = SendTimingCopy.text(for: .steerUnavailable(reason: reason))
            #expect(!text.isEmpty && !text.contains(reason.rawValue), "\(reason.rawValue) 必须是固定中文")
        }
    }

    @Test func definitiveRefusalsRestoreAndUnknownDoesNot() {
        #expect(MessageActionError.steerUnavailable(reason: .devicePaused).isDefinitiveRefusal)
        #expect(MessageActionError.readOnly.isDefinitiveRefusal)
        #expect(MessageActionError.http(status: 401).isDefinitiveRefusal)
        #expect(MessageActionError.http(status: 409).isDefinitiveRefusal)
        #expect(!MessageActionError.invalidResponse.isDefinitiveRefusal, "无效回复不冒称零写入")
        #expect(!MessageActionError.http(status: 500).isDefinitiveRefusal)
    }
}
