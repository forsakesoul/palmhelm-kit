import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct ReceiptDisplayTests {
    private func en<T>(_ b: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "en"), operation: b) }
    private func zh<T>(_ b: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "zh-Hans"), operation: b) }
    private let blocked = HistoryItem(seq: 1, uuid: "nblocked:x", text: "[login-page] agent 正在等待审批或回答问题，请到终端处理（Bridge 不会代答）。", kind: "text",
        displayMessage: LossyDisplayMessage(DisplayMessage(key: "native.blocked", params: ["target": .text("login-page")])))

    @Test func englishUsesSemanticsChineseKeepsTheOriginalText() {
        #expect(en { ReceiptText.summary(blocked) }.hasPrefix("[login-page] The agent is waiting"))
        #expect(zh { ReceiptText.summary(blocked) } == blocked.text)
        #expect(en { ReceiptText.display(blocked) } != blocked.text)
    }

    @Test func itemsWithoutMetadataBehaveAsBefore() {
        let plain = HistoryItem(seq: 2, uuid: "ack:k", text: "queued:abc", kind: "text")
        #expect(en { ReceiptText.summary(plain) == ReceiptText.summary("queued:abc") })
        let user = HistoryItem(seq: 3, uuid: "final:y", text: "用户写了（链接）", kind: "text")
        #expect(en { ReceiptText.display(user) } == "用户写了（链接）")
    }

    @Test func invalidMetadataFallsBackToTheOriginalTextOnly() {
        let bad = HistoryItem(seq: 4, uuid: "nblocked:x", text: "原文", kind: "text", displayMessage: LossyDisplayMessage(DisplayMessage(key: "native.blocked", params: [:])))
        #expect(en { ReceiptText.summary(bad) } == "原文")
    }

    @Test func rejectionItemMatchesTheStringLookup() {
        let rej = HistoryItem(seq: 5, uuid: "ack:r", text: "rejected:target_changed\n…", kind: "text", replyTo: "k1")
        #expect(ReceiptText.rejectionItem(replyTo: "k1", in: [blocked, rej])?.seq == 5)
        #expect(ReceiptText.rejection(replyTo: "k1", in: [blocked, rej]) == rej.text)
    }

    @Test func finalSourceHeaderIsLocalizedInTheDisplayedReply() {
        let it = HistoryItem(seq: 6, uuid: "final:z", text: "（会话记录）\n好了", kind: "text", displaySpans: LossyDisplaySpans([DisplaySpan(startUTF16: 0, endUTF16: 7, key: "source_transcript")]))
        #expect(en { ReceiptText.display(it) } == "(Transcript)\n好了")
        #expect(zh { ReceiptText.display(it) } == it.text)
    }
}

@Suite struct GapDisplayTests {
    private func gap(_ json: String) throws -> TranscriptItem {
        try JSONDecoder().decode(TranscriptItem.self, from: Data(#"{"id":"g1","role":"gap","text":"此条记录无法展示","truncated":false\#(json)}"#.utf8))
    }
    @Test func gapUsesSemanticsInEnglishOnly() throws {
        let g = try gap(#","displayMessage":{"key":"transcript.gap.broken_chain"}"#)
        #expect(KitL10n.$locale.withValue(Locale(identifier: "en")) { TranscriptCopy.gapText(g) } == "Earlier records are unavailable on this Mac; the history cannot be continued")
        #expect(KitL10n.$locale.withValue(Locale(identifier: "zh-Hans")) { TranscriptCopy.gapText(g) } == "此条记录无法展示")
        let o = try JSONDecoder().decode(TranscriptItem.self, from: Data(#"{"id":"g2","role":"gap","text":"x","truncated":false,"reason":"oversized_record","displayMessage":{"key":"transcript.gap.unavailable"}}"#.utf8))
        #expect(TranscriptCopy.gapText(o) == TranscriptCopy.oversizedGap) // 既有 oversized_record 不动
        #expect(KitL10n.$locale.withValue(Locale(identifier: "en")) { TranscriptCopy.gapText(try! gap(#","displayMessage":{"key":"nope"}"#)) } == "此条记录无法展示")
    }
}
