import Testing
import Foundation
@testable import PalmhelmKit

// W2-137 / #99 C：超大记录的 gap 带 reason，客户端显示“这条消息过大，未显示”；其它 gap 与旧 Bridge 保持服务端文本。
@Suite struct TranscriptGapTests {
    @Test func oversizedGapShowsItsOwnCopy() throws {
        let json = #"{"id":"g1","role":"gap","text":"此条记录无法展示","truncated":false,"reason":"oversized_record"}"#
        let item = try JSONDecoder().decode(TranscriptItem.self, from: Data(json.utf8))
        #expect(item.reason == "oversized_record")
        #expect(TranscriptCopy.gapText(item) == "这条消息过大，未显示")
    }

    @Test func otherGapsKeepTheServerText() throws {
        let plain = try JSONDecoder().decode(TranscriptItem.self, from: Data(#"{"id":"g2","role":"gap","text":"此条记录无法展示","truncated":false}"#.utf8))
        #expect(plain.reason == nil)
        #expect(TranscriptCopy.gapText(plain) == "此条记录无法展示")
        let unknown = TranscriptItem(id: "g3", role: "gap", text: "压缩边界之前的历史无法接续", reason: "future_reason")
        #expect(TranscriptCopy.gapText(unknown) == "压缩边界之前的历史无法接续")
    }
}
