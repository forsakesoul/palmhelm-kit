import Testing
import Foundation
@testable import PalmhelmKit

// #96：owner 指令的回显没有排队指令记录，由系统回执 ack:<eventKey> 收敛；普通排队消息仍按 queued 显示。
@Suite struct OutgoingAckTests {
    private func item(_ uuid: String, _ text: String) throws -> HistoryItem {
        try JSONDecoder().decode(HistoryItem.self, from: Data(#"{"seq":1,"uuid":"\#(uuid)","text":"\#(text)","kind":"text"}"#.utf8))
    }

    private func withReplyTo(_ uuid: String, _ text: String, _ replyTo: String) throws -> HistoryItem {
        try JSONDecoder().decode(HistoryItem.self, from: Data(#"{"seq":1,"uuid":"\#(uuid)","text":"\#(text)","kind":"text","replyTo":"\#(replyTo)"}"#.utf8))
    }

    @Test func ackIsFoundByItsEventKeyOnly() throws {
        let items = [try withReplyTo("ack:k1", "switched:t@3", "k1"), try withReplyTo("ack:k2", "queued:task:x", "k2")]
        #expect(OutgoingFacts.ackText(eventKey: "k1", in: items) == "switched:t@3")
        #expect(OutgoingFacts.ackText(eventKey: "k9", in: items) == nil)
    }

    @Test func switchAckSettlesAnEchoWithoutACommand() {
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "switched:t@3")) == .done)
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "rejected:no_match")) == .rejected)
    }

    @Test func queuedAckAndNoAckKeepTheQueuedPhase() {
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, ackText: "queued:task:x")) == .queued)
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true)) == .queued)
    }

    @Test func aCommandStillDecidesWhenItExists() {
        // 有指令记录时以指令为准：ack 不覆盖排队指令的阶段。
        #expect(OutgoingStatus.phase(OutgoingFacts(hasEventKey: true, commandState: "queued", ackText: "switched:t@3")) == .queued)
    }

    // A1-011：原生直达的投递 ack 与气泡状态行同义，按精确 key 身份过滤；其余阶段 / 其它 key / 非 ack 不受影响。
    @Test func nativeDeliveryAckIsCoveredOnlyByItsOwnStatusLine() {
        for p in [OutgoingPhase.nativeDelivered, .nativeSendRequested, .nativeSendSkipped] {
            #expect(QueueStatusPresentation.statusCoversAck(uuid: "ack:k1", eventKey: "k1", phase: p), "\(p)")
        }
        #expect(!QueueStatusPresentation.statusCoversAck(uuid: "ack:k2", eventKey: "k1", phase: .nativeDelivered))
        #expect(!QueueStatusPresentation.statusCoversAck(uuid: "u1", eventKey: "k1", phase: .nativeDelivered))
        #expect(!QueueStatusPresentation.statusCoversAck(uuid: "busy:k1", eventKey: "k1", phase: .nativeDelivered))
        for p in [OutgoingPhase.done, .merged, .nativePaused, .rejected, .failed, .unknown, .queued] {
            #expect(!QueueStatusPresentation.statusCoversAck(uuid: "ack:k1", eventKey: "k1", phase: p), "\(p)")
        }
        #expect(!QueueStatusPresentation.statusCoversAck(uuid: "ack:k1", eventKey: "k1", phase: nil))
    }
}
