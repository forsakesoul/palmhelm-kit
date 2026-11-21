import Testing
import Foundation
@testable import PalmhelmKit

// h3 契约：state 新字段、inbound 事件、旧服务端缺字段也能解码。
@Suite struct H3ContractTests {
    @Test func stateDecodesH3Fields() throws {
        let json = """
        {"binding":null,"occupancy":"none","hold":null,
         "targets":[{"id":"target:demo","projectName":"demo","agentName":"demo_execute","group":"demo","online":true}],
         "device":{"id":"0123","name":"iPhone","paused":false},
         "commands":[{"key":"api:0123:u1","inboxSeq":17,"text":"hi","truncated":false,"origin":"api","device":{"id":"0123","name":"iPhone"},"targetId":"target:demo","state":"queued"}],
         "commandsTruncated":false,
         "history":{"highWater":42,"items":[{"seq":42,"uuid":"ack:x","text":"ok","kind":"text","replyTo":"api:0123:u1","target":{"id":"target:demo","projectName":"demo","agentName":"demo_execute"}}]}}
        """
        let s = try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8))
        #expect(s.targets.first?.id == "target:demo")
        #expect(s.targets.first?.group == "demo")
        #expect(s.device?.paused == false)
        #expect(s.commands?.first?.state == CommandState.queued.rawValue)
        #expect(s.history.items.first?.target?.id == "target:demo")
    }

    @Test func stateWithoutH3FieldsStillDecodes() throws {
        let json = #"{"occupancy":"none","targets":[{"projectName":"demo","online":null}],"history":{"highWater":0,"items":[{"seq":1,"uuid":"u","text":"t","kind":"text","replyTo":null}]}}"#
        let s = try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8))
        #expect(s.targets.first?.id == "demo")
        #expect(s.commands == nil && s.device == nil)
        #expect(s.history.items.first?.target == nil)
    }

    @Test func inboundEventDecodes() {
        let frame = SSEFrame(id: nil, event: "inbound", data: #"{"key":"k","inboxSeq":1,"text":"t","truncated":true,"origin":"feishu","device":null,"targetId":null,"state":"started"}"#)
        guard case .inbound(let c) = BridgeEventDecoder.decode(frame) else { Issue.record("not inbound"); return }
        #expect(c.truncated && c.origin == InboundOrigin.feishu.rawValue && c.device == nil)
    }
}
