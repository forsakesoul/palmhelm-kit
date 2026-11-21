import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct ReceiptTextTests {
    @Test func systemReceiptsBecomeReadable() {
        #expect(ReceiptText.summary("queued:task:om_x100b63c48610d8a8dc0a3585e7ae0ec") == "已排队，等 agent 空闲后发送")
        #expect(ReceiptText.summary("ack:om_abc:p2") == "已受理")
        #expect(ReceiptText.summary("switched:demo@10（已重新核验目标身份）") == "已切换到 demo（已重新核验目标身份）")
        #expect(ReceiptText.summary("switched:demo@10") == "已切换到 demo")
        #expect(ReceiptText.summary("rejected:target_identity_changed（该目标已更换会话）") == ReceiptText.identityPauseCopy, "身份暂停改为统一的中文说明（O1-332）")
        #expect(ReceiptText.summary("rejected:member_target_conflict:demo") == "已拒绝 · member target conflict")
        #expect(ReceiptText.summary("[demo] 已完成") == "[demo] 已完成")
        #expect(ReceiptText.isSystem("queued:task:x") && ReceiptText.isSystem("[demo] 已完成") && !ReceiptText.isSystem("正文"))
    }
}

// O1-327：撤回回填的正文、系统回执的识别（uuid 为 ack: 的回执不冒充 agent 消息）、排队状态族。
@Suite struct WithdrawnDraftTests {
    @Test func userTextThatLooksLikeAttributionIsNeverStripped() {
        // 外形相同的首行不证明是 Bridge 的署名：Kit 不提供剥离接口，回填只来自本机记录（O1-331 R1）。
        #expect(WithdrawnDraft.isBlank("") && !WithdrawnDraft.isBlank("[来自 Palmhelm · x]\n保留我"))
    }

    @Test func blankDraftIsFillable() {
        #expect(WithdrawnDraft.isBlank(""))
        #expect(WithdrawnDraft.isBlank(" \n\t"))
        #expect(!WithdrawnDraft.isBlank("有内容"))
    }

    @Test func ackReceiptsAreSystemEvenWithSentenceText() {
        let ack = HistoryItem(seq: 5, uuid: "ack:api:d:1", text: "已撤回，未发出。", kind: "text", replyTo: "api:d:1")
        #expect(ReceiptText.isSystem(ack), "ack: 回执即使正文是普通句子也是系统回执")
        let agent = HistoryItem(seq: 6, uuid: "transcript:abc", text: "好的，我来处理。", kind: "md")
        #expect(!ReceiptText.isSystem(agent), "agent 正文不是系统回执")
        let queued = HistoryItem(seq: 7, uuid: "x", text: "queued:task:1", kind: "text")
        #expect(ReceiptText.isSystem(queued))
    }

    @Test func queuedFamilyCoversQueuedWithdrawnAndMerged() {
        #expect(SendTimingRules.isQueuedFamily(state: "queued", reason: nil))
        #expect(SendTimingRules.isQueuedFamily(state: "rejected", reason: "withdrawn"), "撤回不能显示成被拒绝")
        #expect(SendTimingRules.isQueuedFamily(state: "finished", reason: "merged"))
        #expect(!SendTimingRules.isQueuedFamily(state: "started", reason: nil))
        #expect(!SendTimingRules.isQueuedFamily(state: "rejected", reason: nil))
    }
}

// O1-332：身份暂停的中文、重置占用命令、切换命令去重、排队行被快照终态收敛。
@Suite struct IdentityPauseAndConvergenceTests {
    @Test func identityPauseReceiptsReadAsChineseNotEnglishCodes() {
        #expect(ReceiptText.summary("rejected:direct_identity_changed") == ReceiptText.identityPauseCopy)
        let ordinary = "rejected:target_identity_changed（该目标对应的 agent 已重建或换了会话，已暂停该目标。确认无误后发「重置占用 p」，再重新切换）"
        #expect(ReceiptText.summary(ordinary) == ReceiptText.identityPauseCopy)
        #expect(!ReceiptText.summary("rejected:direct_identity_changed").contains("identity"))
        #expect(ReceiptText.summary("rejected:direct_target_held").hasPrefix("已拒绝"), "其他拒绝保持原有说明")
        #expect(ReceiptText.isIdentityPause("rejected:direct_identity_changed") && !ReceiptText.isIdentityPause("rejected:direct_target_held"))
    }

    @Test func identityRecoverCommandIsConditionalAndSingleToken() {
        #expect(ReceiptText.identityRecoverCommand(eventKey: "api:d:1") == "恢复身份 #api:d:1")
        #expect(ReceiptText.identityRecoverCommand(eventKey: "a b") == nil, "含空白不生成命令")
        #expect(ReceiptText.identityRecoverCommand(eventKey: "k#x") == nil)
        #expect(ReceiptText.identityRecoverCommand(eventKey: "") == nil, "没有 eventKey 不生成（没有裸名形式）")
    }

    @Test func refusalReasonsReadAsChinese() {
        #expect(ReceiptText.summary("rejected:identity_recover_refused:active_command") == "这个目标还有未完成的命令，先等它结束")
        #expect(ReceiptText.summary("rejected:identity_recover_refused:not_observed").contains("Herdr"))
        #expect(ReceiptText.summary("rejected:identity_recover_refused:weird") == "恢复没有完成")
        #expect(ReceiptText.summary("rejected:identity_recover_refused:generation_changed").contains("执行端"))
        #expect(ReceiptText.summary("rejected:identity_recover_private_only") == "恢复身份只能在私聊里发起")
    }

    @Test func switchCommandKeepsTheAgentTheUserChose() {
        #expect(OwnerCommand.switchTo(project: "task_x_execute", agent: "task_x_execute") == "切换到 task_x_execute task_x_execute", "用户选择的 agent 原样保留（消歧语义，O1-338 R4）")
        #expect(OwnerCommand.switchTo(project: "p", agent: "a") == "切换到 p a")
        #expect(OwnerCommand.switchTo(project: "p") == "切换到 p")
    }

    @Test func snapshotTerminalStateConvergesAQueuedRow() throws {
        func cmd(_ json: String) throws -> ApiCommand { try JSONDecoder().decode(ApiCommand.self, from: Data(json.utf8)) }
        let queued = try cmd(#"{"key":"api:d:1","inboxSeq":1,"text":"补","truncated":false,"origin":"api","state":"queued","lane":"ordinary","targetId":"t1"}"#)
        // 漏掉了 progress 帧：只靠快照里的撤回终态也要收敛为已撤回
        let snapshot = try cmd(#"{"key":"api:d:1","inboxSeq":1,"text":"补","truncated":false,"origin":"api","state":"rejected","reason":"withdrawn","lane":"ordinary","targetId":"t1"}"#)
        let merged = CommandMerge.merged(old: queued, new: snapshot)
        #expect(merged.state == "rejected" && merged.reason == "withdrawn")
        #expect(SendTimingCopy.commandStatus(state: merged.state, reason: merged.reason, lane: merged.lane, locale: zhHansLocale) == "已撤回，未发出")
    }
}
