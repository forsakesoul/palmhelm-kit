import Foundation
import Testing
@testable import PalmhelmKit

// 发送时机的界面规则：菜单只在工作中出现；立即插入不可用时灰掉并给原因；⌘↩ 不会悄悄排队；排队操作的可用性；署名偏好按设备保存。
@Suite struct SendTimingRulesTests {
    @Test func menuOnlyWhileWorking() {
        #expect(SendTimingRules.showsMenu(targetStatus: "working"))
        #expect(!SendTimingRules.showsMenu(targetStatus: "idle"))
        #expect(!SendTimingRules.showsMenu(targetStatus: nil))
    }

    @Test func queueIsDefaultAndSteerDisabledWithReason() {
        let supported = SendTimingRules.menu(steer: .available)
        #expect(supported.map(\.choice) == [.queueAfterTurn, .steerNow])
        #expect(supported.allSatisfy { $0.enabled })
        let off = SendTimingRules.menu(steer: .unavailable)
        #expect(off[0].enabled)
        #expect(!off[1].enabled)
        #expect(off[1].disabledReason == SendTimingCopy.steerUnavailable)
        // 旧 Bridge 未声明：灰掉并说明，不是「不支持」的确定结论。
        let unknown = SendTimingRules.menu(steer: .unknown)
        #expect(!unknown[1].enabled)
        #expect(unknown[1].disabledReason?.contains("没有声明") == true)
    }

    @Test func commandReturnNeverSilentlyQueuesWhenSteerIsUnsupported() {
        #expect(SendTimingRules.commandReturn(working: false, steer: .unavailable) == .send(nil))
        #expect(SendTimingRules.commandReturn(working: true, steer: .available) == .send(.steer))
        #expect(SendTimingRules.commandReturn(working: true, steer: .unavailable) == .blocked(reason: SendTimingCopy.steerUnavailable))
        #expect(SendTimingRules.commandReturn(working: true, steer: .unknown) != .send(.queue))
    }

    @Test func queuedActionsDependOnStateReasonAndSteer() {
        #expect(SendTimingRules.queuedActions(state: "queued", reason: nil, steer: .available) == [.withdraw, .promote])
        #expect(SendTimingRules.queuedActions(state: "queued", reason: nil, steer: .unavailable) == [.withdraw])
        #expect(SendTimingRules.queuedActions(state: "started", reason: nil, steer: .available).isEmpty, "已派发不能撤回")
        #expect(SendTimingRules.queuedActions(state: "rejected", reason: "withdrawn", steer: .available).isEmpty, "已撤回不再有操作")
    }

    // O1-325：直达（派给 <agent>）与绑定目标一样，工作中显示菜单；主按钮不传 mode；立即插入灰掉并写明原因；排队消息可撤回但不能改为立即插入。
    @Test func directTargetShowsMenuWhileWorkingWithSteerDisabled() {
        #expect(SendTimingRules.showsMenu(targetStatus: "working"), "直达工作中也显示菜单")
        let menu = SendTimingRules.menu(steer: .available, direct: true)
        #expect(menu[0].choice == .queueAfterTurn && menu[0].enabled)
        #expect(menu[1].choice == .steerNow && !menu[1].enabled, "直达即使 Bridge 支持也不能立即插入")
        #expect(menu[1].disabledReason == SendTimingCopy.directNoSteer)
        #expect(SendTimingCopy.directNoSteer == "直达暂不支持")
    }

    @Test func primaryButtonKeepsDirectRequestShapeOutsideClaudeSteer() {
        // 直达非 Claude / 无能力 / 空闲：主按钮与回车不传 mode（和以前的直达发送一样）；绑定目标工作中才排队。
        #expect(SendTimingRules.primaryMode(direct: true, targetStatus: "working", kind: "codex", nativeSteer: true) == nil)
        #expect(SendTimingRules.primaryMode(direct: true, targetStatus: "working") == nil, "缺省参数等同旧规则")
        #expect(SendTimingRules.primaryMode(direct: true, targetStatus: "idle", kind: "claude", nativeSteer: true) == nil)
        #expect(SendTimingRules.primaryMode(direct: false, targetStatus: "working") == .queue)
        #expect(SendTimingRules.primaryMode(direct: false, targetStatus: "idle") == nil)
    }

    // #77：直达 Claude + 工作中 + nativeSteer 可用 → 默认立即插入；任一条件不满足即退回原路径。
    @Test func directClaudeWorkingWithNativeSteerDefaultsToSteer() {
        #expect(SendTimingRules.primaryMode(direct: true, targetStatus: "working", kind: "claude", nativeSteer: true) == .steer)
    }

    @Test func missingOrFalseNativeSteerKeepsDirectClaudeOrdinary() {
        #expect(SendTimingRules.primaryMode(direct: true, targetStatus: "working", kind: "claude", nativeSteer: false) == nil, "旧 Bridge 或能力位为 false 不得插入")
        #expect(SendTimingRules.primaryMode(direct: true, targetStatus: "working", kind: "claude") == nil, "能力缺省即不支持")
    }

    @Test func nonClaudeDirectNeverDefaultsToSteer() {
        for kind in ["codex", "pi", "other", nil] as [String?] {
            #expect(SendTimingRules.primaryMode(direct: true, targetStatus: "working", kind: kind, nativeSteer: true) == nil, "kind \(kind ?? "nil")")
        }
    }

    @Test func boundClaudeWorkingStillQueuesNotSteers() {
        // 绑定目标的默认仍是「本轮结束后发送」；hook steer 不因此升级为默认插入。
        #expect(SendTimingRules.primaryMode(direct: false, targetStatus: "working", kind: "claude", nativeSteer: true) == .queue)
    }

    @Test func directQueuedMessageCanBeWithdrawnButNotPromoted() {
        #expect(SendTimingRules.queuedActions(state: "queued", reason: nil, steer: .available, direct: true) == [.withdraw])
        #expect(SendTimingRules.queuedActions(state: "queued", reason: nil, steer: .unavailable, direct: true) == [.withdraw])
        #expect(SendTimingRules.queuedActions(state: "started", reason: nil, steer: .available, direct: true).isEmpty)
        #expect(SendTimingRules.queuedActions(state: "queued", reason: nil, steer: .available) == [.withdraw, .promote], "绑定目标行为不变")
    }

    @Test func commandStatusSeparatesQueueModesByServerLane() {
        #expect(SendTimingCopy.commandStatus(state: "queued", reason: nil, lane: "ordinary") == "排队中 · 本轮结束后发送")
        #expect(SendTimingCopy.commandStatus(state: "queued", reason: nil, lane: "use") == "补充排队中 · 将并入当前回合")
        #expect(SendTimingCopy.commandStatus(state: "queued", reason: nil, lane: nil) == "排队中 · 本轮结束后发送", "旧 Bridge 没有 lane 时按排队")
        #expect(SendTimingCopy.commandStatus(state: "rejected", reason: "withdrawn", lane: "use", locale: zhHansLocale) == "已撤回，未发出")
        #expect(SendTimingCopy.commandStatus(state: "finished", reason: "merged", lane: "use", locale: zhHansLocale) == "已并入当前回合")
        #expect(SendTimingCopy.commandStatus(state: "started", reason: nil, lane: nil) == "已送达", "缺阶段：中性")
        #expect(SendTimingCopy.commandStatus(state: "started", reason: nil, lane: nil, phase: "running") == "已送达 · 回合进行中")
    }
}

@Suite struct CommandMergeTests {
    private func cmd(_ state: String, reason: String? = nil, lane: String? = "use") -> ApiCommand {
        ApiCommand(key: "k", inboxSeq: 1, text: "x", origin: "api", state: state, reason: reason, lane: lane)
    }

    @Test func lateSnapshotDoesNotOverwriteTerminalReason() {
        let withdrawn = cmd("rejected", reason: "withdrawn")
        let late = merged(withdrawn, cmd("queued"))
        #expect(late.state == "rejected" && late.reason == "withdrawn", "迟到的 queued 快照不能覆盖撤回")
        let merged = CommandMerge.merged(old: cmd("finished", reason: "merged"), new: cmd("finished"))
        #expect(merged.reason == "merged", "同一终态、快照没带原因时保留已有原因")
    }

    @Test func mergedSurvivesTheWholeStateSequence() {
        // 队列 → 并入（started + merged）→ 完成（finished，无 reason）：仍显示「已并入当前回合」
        var row = cmd("queued", reason: nil, lane: "use")
        row = CommandMerge.merged(old: row, new: cmd("started", reason: "merged", lane: "use"))
        row = CommandMerge.merged(old: row, new: cmd("finished", reason: nil, lane: "use"))
        #expect(row.reason == "merged")
        #expect(SendTimingCopy.commandStatus(state: row.state, reason: row.reason, lane: row.lane, locale: zhHansLocale) == "已并入当前回合")
        // 迟到的 queued 快照不能抹掉已并入
        let late = CommandMerge.merged(old: row, new: cmd("queued", reason: nil, lane: "use"))
        #expect(late.reason == "merged")
        let progressed = CommandMerge.progressed(row, state: "finished", reason: nil)
        #expect(progressed.reason == "merged")
    }

    @Test func progressKeepsTheReasonWhenItIsMissing() {
        let p = CommandMerge.progressed(cmd("rejected", reason: "withdrawn"), state: "rejected", reason: nil)
        #expect(p.reason == "withdrawn")
        let fresh = CommandMerge.progressed(cmd("queued"), state: "started", reason: nil)
        #expect(fresh.reason == nil)
    }

    private func merged(_ old: ApiCommand, _ new: ApiCommand) -> ApiCommand { CommandMerge.merged(old: old, new: new) }
}

@Suite struct TranscriptMergedReceiptTests {
    @Test func receiptReasonDecodesAndAbsentReasonStaysNil() throws {
        let merged = try JSONDecoder().decode(TranscriptReceipt.self, from: Data(#"{"commandKey":"k","origin":"api","receiptState":"sent","reason":"merged"}"#.utf8))
        #expect(merged.reason == "merged" && merged.receiptState == "sent")
        let old = try JSONDecoder().decode(TranscriptReceipt.self, from: Data(#"{"commandKey":"k","origin":"api","receiptState":"done"}"#.utf8))
        #expect(old.reason == nil, "旧 Bridge 没有 reason")
    }
}
