import Testing
@testable import PalmhelmKit

@Suite struct OwnerCommandTests {
    @Test func directWrapsBodyForBridge() {
        #expect(OwnerCommand.direct(agent: "alpha_design", text: "你好") == "派给 alpha_design：你好")
    }

    @Test func canDirectFollowsAgentNameRule() {
        #expect(!OwnerCommand.canDirect(agentName: nil))
        #expect(!OwnerCommand.canDirect(agentName: ""))
        #expect(OwnerCommand.canDirect(agentName: "a"))
        #expect(OwnerCommand.canDirect(agentName: "1ab-c.d_e"))
        #expect(OwnerCommand.canDirect(agentName: String(repeating: "a", count: 64)))
        #expect(!OwnerCommand.canDirect(agentName: String(repeating: "a", count: 65)))
        #expect(!OwnerCommand.canDirect(agentName: "a b"))
        #expect(!OwnerCommand.canDirect(agentName: "中文"))
        #expect(!OwnerCommand.canDirect(agentName: "_x"))
        #expect(OwnerCommand.canDirect(agentName: "task_1_execute"))
        #expect(OwnerCommand.canDirect(agentName: "task_1_advisor"))
        #expect(OwnerCommand.canDirect(agentName: "task_1_execute2") && OwnerCommand.canDirect(agentName: "task_1_advisor2"))
        #expect(!OwnerCommand.canDirect(agentName: "_execute"), "首字符规则仍在")
        #expect(OwnerCommand.canDirect(agentName: "a_execute_x"))
    }

    @Test func rejectionFindsOnlyRejectedRepliesToThatKey() {
        let h = [
            HistoryItem(seq: 1, uuid: "u1", text: "rejected:dispatch_disabled（派发未开启）", kind: "text", replyTo: "k1"),
            HistoryItem(seq: 2, uuid: "u2", text: "ack:已受理", kind: "ack", replyTo: "k2"),
        ]
        #expect(ReceiptText.rejection(replyTo: "k1", in: h) == "rejected:dispatch_disabled（派发未开启）")
        #expect(ReceiptText.rejection(replyTo: "k2", in: h) == nil)
        #expect(ReceiptText.rejection(replyTo: "k3", in: h) == nil)
    }
}
