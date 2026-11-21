import Foundation
import Testing
@testable import PalmhelmKit

// #89 片 B 联验（producer→consumer 契约字节）：Bridge v2 真实投影代码产出的字节（见 QueueV2WireBytes）经 Kit 真实解码。
@Suite struct QueueV2WireContractTests {
    private struct Commands: Decodable { var commands: [ApiCommand] }

    private func frames() -> [ProgressPayload] {
        var parser = SSEParser()
        return parser.feed(Data(QueueV2WireBytes.progressSSE.utf8)).compactMap {
            if case .progress(let p) = BridgeEventDecoder.decode($0) { return p }
            return nil
        }
    }

    @Test func stateCommandsHistoryAndProgressAgreeOnTheSameKeys() throws {
        let commands = try JSONDecoder().decode(Commands.self, from: Data(QueueV2WireBytes.commands.utf8)).commands
        let byKey = Dictionary(uniqueKeysWithValues: commands.map { ($0.key, $0) })
        #expect(byKey["e2e:np"]?.stopDisposition == .notDispatched, "暂停且无 commands")
        #expect(byKey["e2e:unc"]?.stopDisposition == .uncertain, "暂停且有 abandoned commands")
        #expect(byKey["e2e:dl"]?.stopDisposition == nil && byKey["e2e:fin"]?.stopDisposition == nil, "非暂停态无该键")
        #expect(byKey["e2e:dl"]?.queueDeadlineT == 1790000000000)

        let page = try JSONDecoder().decode(TargetHistoryPage.self, from: Data(QueueV2WireBytes.history.utf8))
        let rows = Dictionary(uniqueKeysWithValues: page.items.compactMap { r in r.command.map { (r.command!.key, $0) } })
        for k in ["e2e:np", "e2e:unc", "e2e:dl", "e2e:fin"] {
            #expect(rows[k]?.stopDisposition == byKey[k]?.stopDisposition, "\(k)：history 与 state.commands 同值")
            #expect(rows[k]?.queueDeadlineT == byKey[k]?.queueDeadlineT)
            #expect(rows[k].map(MessageStatusRules.standalone) == byKey[k].map(MessageStatusRules.standalone), "\(k)：同一 Kit 语义求值同结果")
        }

        let paused = frames().filter { $0.state == "paused" }
        #expect(Dictionary(uniqueKeysWithValues: paused.map { ($0.eventKey, $0.stop) }) == ["e2e:np": .notDispatched, "e2e:unc": .uncertain], "progress 暂停同帧带同一分类")
    }

    @Test func progressPhasesWalkDispatchAwaitingRunningAndTheDeadlineLeavesWithStarted() throws {
        let dl = frames().filter { $0.eventKey == "e2e:dl" }
        #expect(dl.map { $0.queue?.phase } == ["dispatch", "awaiting", "running"])
        #expect(dl.allSatisfy { $0.state == "started" })
        let queued = try JSONDecoder().decode(Commands.self, from: Data(QueueV2WireBytes.commands.utf8)).commands.first { $0.key == "e2e:dl" }!
        #expect(QueueStatusPresentation.card(for: queued, phase: .queued)?.deadlineText != nil, "queued 带真实期限")
        var started = queued
        started.state = "started"; started.queue = dl[1].queue
        #expect(QueueStatusPresentation.card(for: started, phase: .awaiting)?.deadlineText == nil, "已开始后期限消失")
    }

    @Test func anOldClientDecodesTheNewKeyLeniently() throws {
        // 旧客户端：对新增键宽松解码（这里用“忽略未知键”的最小结构模拟）。
        struct Old: Decodable { var key: String; var state: String }
        struct Wrap: Decodable { var commands: [Old] }
        let old = try JSONDecoder().decode(Wrap.self, from: Data(QueueV2WireBytes.commands.utf8))
        #expect(old.commands.count == 4 && old.commands.first { $0.key == "e2e:np" }?.state == "paused")
    }

    @Test func missingNullAndUnknownKeysStayConservativeForTheNewClient() throws {
        func cmd(_ extra: String) throws -> ApiCommand {
            try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"k","inboxSeq":1,"text":"x","truncated":false,"origin":"api","state":"paused","targetId":"t"\#(extra)}"#.utf8))
        }
        for extra in ["", #","stopDisposition":null"#, #","stopDisposition":"from_the_future""#] {
            let c = try cmd(extra)
            #expect(MessageStatusRules.standalone(c).phase == .stoppedUncertain, "\(extra.isEmpty ? "缺键" : extra)")
        }
    }
}
