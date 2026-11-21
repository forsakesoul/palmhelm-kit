import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct QueueDeadlineTests {
    @Test func menuRequiresExplicitCapability() throws {
        #expect(SendTimingRules.menu(steer: .unknown).count == 2)
        let menu = SendTimingRules.menu(steer: .unavailable, direct: true, queueDeadline: true)
        #expect(menu.map(\.choice.queueTTLSeconds) == [nil, nil, 3600, 86400])
        #expect(menu[2].enabled && menu[3].enabled)
        #expect(!menu[1].enabled)
        let old = try JSONDecoder().decode(TargetCapabilities.self, from: Data(#"{"steer":false}"#.utf8))
        #expect(old.queueDeadline == nil)
    }
    @Test func requestKeepsOldShapeAndFiniteDuration() throws {
        let plain = SendMessageBody(clientMsgId: "id", text: "use: 原文", mode: nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
        #expect(Set(object.keys) == ["clientMsgId", "text"])
        let finite = SendMessageBody(clientMsgId: "id", text: "原文", mode: nil, queueTTLSeconds: 3600)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(finite)) as! [String: Any]
        #expect(wire["queueTTLSeconds"] as? Int == 3600)
        #expect(wire["mode"] == nil)
    }
    @Test func transcriptKeepsUnsentDeadlineRowsWithoutLocalSendHistory() {
        let expired = ApiCommand(key: "expired", inboxSeq: 2, text: "原文", origin: "api", state: "paused", reason: "queue_expired")
        var queued = ApiCommand(key: "queued", inboxSeq: 1, text: "原文", origin: "api", state: "queued")
        queued.queueDeadlineT = 1000
        let sent = ApiCommand(key: "sent", inboxSeq: 3, text: "原文", origin: "api", state: "started")
        #expect(SendTimingRules.deadlineRows([expired, sent, queued]).map(\.key) == ["queued", "expired"])
        #expect(OutgoingStatus.phase(OutgoingFacts(commandState: "paused", commandReason: "queue_expired")) == .expired)
        #expect(OutgoingStatus.label(.queueStopped, locale: zhHansLocale) == "停止后续排队，之前的结果待确认")
    }
    @Test func expiryCopyAndLateProgress() {
        let text = SendTimingCopy.commandStatus(state: "queued", reason: nil, lane: "ordinary", queueDeadlineT: 1_800_000_000_000)
        #expect(text.contains("前开始，否则不发"))
        #expect(SendTimingCopy.commandStatus(state: "paused", reason: "queue_expired", lane: "ordinary", locale: zhHansLocale) == "已过期，未发出")
        #expect(SendTimingCopy.commandStatus(state: "paused", reason: "queue_expired_uncertain", lane: nil, locale: zhHansLocale) == "停止后续排队，之前的结果待确认")
        let old = ApiCommand(key: "a", inboxSeq: 1, text: "x", origin: "api", state: "paused", reason: "queue_expired")
        #expect(CommandMerge.progressed(old, state: "queued", reason: nil) == old)
        #expect(SendTimingRules.queuedActions(state: "paused", reason: "queue_expired", steer: .available) == [.resend])
        #expect(SendTimingRules.queuedActions(state: "paused", reason: "queue_expired_uncertain", steer: .available).isEmpty)
    }
}
