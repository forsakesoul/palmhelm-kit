import Testing
import Foundation
@testable import PalmhelmKit

@Suite struct SSEParserTests {
    @Test func splitsFramesAcrossChunks() {
        var p = SSEParser()
        let first = Data("id: 7\nevent: outbox\ndata: {\"seq\":7,\"uuid\":\"u\",\"text\":\"hi\",\"kind\":\"text\",\"replyTo\":null}\n\nevent: pi".utf8)
        let second = Data("ng\ndata: {}\n\n".utf8)
        let a = p.feed(first)
        #expect(a.count == 1)
        #expect(a[0].id == "7")
        #expect(a[0].event == "outbox")
        let b = p.feed(second)
        #expect(b.count == 1)
        #expect(b[0].event == "ping")
    }

    // h4 §2.1：SSE targets 帧同样不因一个目标的 customTitle 形状不对而整帧丢失。
    @Test func targetsFrameSurvivesAMalformedCustomTitle() {
        let frame = SSEFrame(id: nil, event: "targets", data: #"{"occupancy":"idle","history":{"highWater":0,"items":[]},"targets":[{"projectName":"bad","id":"t1","customTitle":[1]},{"projectName":"good","id":"t2","customTitle":"正常"}]}"#)
        guard case let .targets(targets, _, _, _, _) = BridgeEventDecoder.decode(frame) else {
            Issue.record("targets 帧被丢弃")
            return
        }
        #expect(targets.map(\.projectName) == ["bad", "good"])
        #expect(targets[0].customTitle == nil)
        #expect(targets[1].customTitle == "正常")
    }

    @Test func decodesBridgeEvents() {
        let sync = SSEFrame(id: nil, event: "sync", data: "{\"highWater\":12,\"count\":3,\"mode\":\"snapshot\"}")
        #expect(BridgeEventDecoder.decode(sync) == .sync(highWater: 12, count: 3, mode: "snapshot"))
        let ready = SSEFrame(id: nil, event: "ready", data: "{\"highWater\":12}")
        #expect(BridgeEventDecoder.decode(ready) == .ready(highWater: 12))
        let reset = SSEFrame(id: nil, event: "reset_required", data: "{\"highWater\":900}")
        #expect(BridgeEventDecoder.decode(reset) == .resetRequired(highWater: 900))
        let progress = SSEFrame(id: nil, event: "progress", data: "{\"eventKey\":\"api:d:1\",\"state\":\"started\"}")
        #expect(BridgeEventDecoder.decode(progress) == .progress(ProgressPayload(eventKey: "api:d:1", state: "started")))
        // 撤回的 progress 帧带 reason（旧 Bridge 没有该字段时为 nil）
        let withdrawn = SSEFrame(id: nil, event: "progress", data: "{\"eventKey\":\"api:d:2\",\"state\":\"rejected\",\"reason\":\"withdrawn\"}")
        #expect(BridgeEventDecoder.decode(withdrawn) == .progress(ProgressPayload(eventKey: "api:d:2", state: "rejected", reason: "withdrawn")))
        let device = SSEFrame(id: nil, event: "device", data: "{\"id\":\"d1\",\"name\":\"iPhone\",\"paused\":false,\"permission\":\"control\"}")
        guard case .device(let d) = BridgeEventDecoder.decode(device) else { Issue.record("not device"); return }
        #expect(d.id == "d1" && d.canControl && !d.paused)
        let badDevice = SSEFrame(id: nil, event: "device", data: "{\"nope\":1}")
        #expect(BridgeEventDecoder.decode(badDevice) == .unknown(name: "device")) // 形状不对：忽略，不崩
        let odd = SSEFrame(id: nil, event: "mystery", data: "{}")
        #expect(BridgeEventDecoder.decode(odd) == .unknown(name: "mystery"))
    }

    @Test func multilineDataJoinsWithNewline() {
        var p = SSEParser()
        let frames = p.feed(Data("data: a\ndata: b\n\n".utf8))
        #expect(frames == [SSEFrame(id: nil, event: nil, data: "a\nb")])
    }
}
