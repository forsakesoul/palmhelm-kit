import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct BridgeDisplayTextTests {
    private func en<T>(_ body: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "en"), operation: body) }
    private func zh<T>(_ body: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "zh-Hans"), operation: body) }
    private func span(_ raw: String, _ needle: String, _ key: String) -> DisplaySpan {
        let r = raw.range(of: needle)!
        let s = raw.utf16.distance(from: raw.utf16.startIndex, to: r.lowerBound.samePosition(in: raw.utf16)!)
        return DisplaySpan(startUTF16: s, endUTF16: s + needle.utf16.count, key: key)
    }

    @Test func replacesOnlyMarkedAtomsAndLeavesLiteralLookalikes() {
        let raw = "看 （链接） 和用户写的（链接）"
        let spans = [span(raw, "（链接）", "link")]
        let e = en { BridgeDisplayText.render(raw, spans: spans) }
        #expect(e.text == "看 (link) 和用户写的（链接）")
        let z = zh { BridgeDisplayText.render(raw, spans: spans) }
        #expect(z.text == raw)
    }

    @Test func noSpansIsIdentity() {
        let d = en { BridgeDisplayText.render("plain（链接）", spans: nil) }
        #expect(d.text == "plain（链接）" && d.map == .identity)
        #expect(en { BridgeDisplayText.render("x", spans: []) }.text == "x")
    }

    @Test func invalidSpansFallBackIndividually() {
        let raw = "A（图片）B（链接）C"
        let good = span(raw, "（链接）", "link")
        let bad: [DisplaySpan] = [
            DisplaySpan(startUTF16: 1, endUTF16: 5, key: "nope"),         // 未知 key
            DisplaySpan(startUTF16: 1, endUTF16: 4, key: "image"),        // 与原文不符
            DisplaySpan(startUTF16: 40, endUTF16: 44, key: "image"),      // 越界
            DisplaySpan(startUTF16: 5, endUTF16: 5, key: "image"),        // 空
        ]
        #expect(en { BridgeDisplayText.render(raw, spans: bad + [good]) }.text == "A（图片）B(link)C")
        // 重叠/乱序：后者丢弃
        let img = span(raw, "（图片）", "image")
        #expect(en { BridgeDisplayText.render(raw, spans: [good, img]) }.text == "A（图片）B(link)C")
    }

    @Test func surrogatePairsAndOffsetMapping() {
        let raw = "😀（链接）😀（图片）end"
        let spans = [span(raw, "（链接）", "link"), span(raw, "（图片）", "image")]
        let d = en { BridgeDisplayText.render(raw, spans: spans) }
        #expect(d.text == "😀(link)😀(image)end")
        let rawUnits = Array(raw.utf16), shownUnits = Array(d.text.utf16)
        // 原子之外的每个偏移往返一致
        for o in 0...rawUnits.count {
            let inside = spans.contains { o > $0.startUTF16 && o < $0.endUTF16 }
            if inside { continue }
            let s = d.map.shown(forRaw: o)
            #expect(d.map.raw(forShown: s) == o)
        }
        // 尾部文字 "end" 的位置
        let rawEnd = rawUnits.count - 3, shownEnd = shownUnits.count - 3
        #expect(d.map.shown(forRaw: rawEnd) == shownEnd)
        // 原子内部按边缘吸附
        let a = spans[0]
        #expect(d.map.shown(forRaw: a.startUTF16 + 1, edge: .start) == a.startUTF16)
        #expect(d.map.shown(forRaw: a.startUTF16 + 1, edge: .end) == a.startUTF16 + "(link)".utf16.count)
    }

    @Test func everyAtomHasEnglish() {
        for a in DisplayAtom.allCases { #expect(en { a.shown } != a.canonical, "\(a.rawValue)") ; #expect(zh { a.shown } == a.canonical) }
        #expect(en { DisplayAtom.localCommand.shown } == "Local terminal command:")
    }
}

@Suite struct DisplaySpansDecodingTests {
    private func decode(_ json: String) throws -> TranscriptItem { try JSONDecoder().decode(TranscriptItem.self, from: Data(json.utf8)) }
    private let base = #""id":"i1","role":"assistant","text":"见（链接）","truncated":false"#

    @Test func decodesSpansAndRendersEnglish() throws {
        let it = try decode(#"{\#(base),"displaySpans":[{"startUTF16":1,"endUTF16":5,"key":"link"}]}"#)
        #expect(KitL10n.$locale.withValue(Locale(identifier: "en")) { it.displayed.text } == "见(link)")
        #expect(it.text == "见（链接）") // 原文与内容版本不变
    }

    @Test func missingOrMalformedSpansNeverFailTheItem() throws {
        #expect(try decode("{\(base)}").displaySpans == nil)
        for bad in [#""x""#, "42", "{}", #"[1,"a",{"startUTF16":"1"}]"#, "null"] {
            let it = try decode("{\(base),\"displaySpans\":\(bad)}")
            #expect(KitL10n.$locale.withValue(Locale(identifier: "en")) { it.displayed.text } == "见（链接）", "\(bad)")
        }
        // 一项畸形、一项合法：只丢畸形那项
        let mixed = try decode(#"{\#(base),"displaySpans":[{"bad":1},{"startUTF16":1,"endUTF16":5,"key":"link"}]}"#)
        #expect(KitL10n.$locale.withValue(Locale(identifier: "en")) { mixed.displayed.text } == "见(link)")
    }

    @Test func segmentCarriesSpansToo() throws {
        let seg = try JSONDecoder().decode(TranscriptItemSegment.self, from: Data(#"{"status":"ok","text":"（图片）","displaySpans":[{"startUTF16":0,"endUTF16":4,"key":"image"}]}"#.utf8))
        #expect(BridgeDisplayText.render(seg.text ?? "", lossy: seg.displaySpans).text.isEmpty == false)
        #expect(KitL10n.$locale.withValue(Locale(identifier: "en")) { BridgeDisplayText.render(seg.text ?? "", lossy: seg.displaySpans).text } == "(image)")
    }
}

@Suite struct FinalSourceHeaderTests {
    @Test func headerIsLocalizedAndReplyBodyIsVerbatim() throws {
        let raw = "（屏幕摘要，来源未验证）\n用户屏幕里的（链接）和 done"
        let spans = [DisplaySpan(startUTF16: 0, endUTF16: "（屏幕摘要，来源未验证）\n".utf16.count, key: "source_screen_unverified")]
        let d = KitL10n.$locale.withValue(Locale(identifier: "en")) { BridgeDisplayText.render(raw, spans: spans) }
        #expect(d.text == "(Screen summary; source unverified)\n用户屏幕里的（链接）和 done")
        #expect(KitL10n.$locale.withValue(Locale(identifier: "en")) { DisplayAtom.sourceTranscript.shown } == "(Transcript)\n")
        let item = try JSONDecoder().decode(HistoryItem.self, from: Data(#"{"seq":1,"uuid":"final:a","text":"（会话记录）\n你好","kind":"text","displaySpans":[{"startUTF16":0,"endUTF16":7,"key":"source_transcript"}]}"#.utf8))
        #expect(KitL10n.$locale.withValue(Locale(identifier: "en")) { BridgeDisplayText.render(item.text, lossy: item.displaySpans).text } == "(Transcript)\n你好")
    }
}

@Suite struct FinalGeneratedFragmentTests {
    private func en(_ raw: String, _ spans: [DisplaySpan]) -> String { KitL10n.$locale.withValue(Locale(identifier: "en")) { BridgeDisplayText.render(raw, spans: spans).text } }
    private func span(_ key: String, _ canonical: String, at: Int) -> DisplaySpan { DisplaySpan(startUTF16: at, endUTF16: at + canonical.utf16.count, key: key) }

    @Test func everyFinalAtomRendersEnglishAndKeepsTheRuleName() {
        let head = DisplayAtom.finalFilteredHead.canonical, tail = DisplayAtom.finalFilteredTail.canonical
        let raw = head + "secret-rule" + tail
        let out = en(raw, [span("final_filtered_head", head, at: 0), span("final_filtered_tail", tail, at: head.utf16.count + "secret-rule".utf16.count)])
        #expect(out == "⚠️ **Completed; the content was not sent back automatically**\n\nSecurity filter matched: `secret-rule`. Check the terminal for the full reply.")
        for a in [DisplayAtom.finalNoText, .finalIdleNoCapture, .finalGroupDone, .finalMemberRevoked, .finalMemberHead] {
            #expect(en(a.canonical, [span(a.rawValue, a.canonical, at: 0)]) != a.canonical, "\(a.rawValue)")
        }
        #expect(en(DisplayAtom.finalNoText.canonical, [span("final_no_text", DisplayAtom.finalNoText.canonical, at: 0)]) == "Completed (no text reply).")
    }

    @Test func memberHeadKeepsTheAskerAndReplyVerbatim() {
        let head = DisplayAtom.finalMemberHead.canonical, raw = head + "张三\n\n（链接）原样"
        #expect(en(raw, [span("final_member_head", head, at: 0)]) == "Member Q&A | read-only mode provided by the target | asked by 张三\n\n（链接）原样")
    }

    @Test func forgedSpanOverUserTextIsIgnored() {
        #expect(en("用户自己写的：完成（无文字回复）", [DisplaySpan(startUTF16: 0, endUTF16: 9, key: "final_no_text")]) == "用户自己写的：完成（无文字回复）")
    }
}

@Suite struct DisplayHighlightMappingTests {
    private func shown(_ raw: String, _ needle: String, _ key: String) -> DisplayedText {
        let r = raw.range(of: needle)!; let s = raw.utf16.distance(from: raw.utf16.startIndex, to: r.lowerBound.samePosition(in: raw.utf16)!)
        return KitL10n.$locale.withValue(Locale(identifier: "en")) { BridgeDisplayText.render(raw, spans: [DisplaySpan(startUTF16: s, endUTF16: s + needle.utf16.count, key: key)]) }
    }
    @Test func hitsOutsideAtomsMapToTheShiftedPosition() {
        let raw = "前（链接）后 target"
        let d = shown(raw, "（链接）", "link")
        let m = SearchText.mappedRanges(raw: raw, shown: d, query: "target")
        #expect(m.count == 1)
        let u = Array(d.text.utf16); #expect(String(decoding: u[m[0][0]..<(m[0][0] + m[0][1])], as: UTF16.self) == "target")
        #expect(SearchText.consistentQuery(raw: raw, shown: d, query: "target") == "target")
    }
    @Test func hitInsideOrAcrossAnAtomIsNotHighlighted() {
        let raw = "前（链接）后"
        let d = shown(raw, "（链接）", "link")
        #expect(SearchText.mappedRanges(raw: raw, shown: d, query: "链接").isEmpty)      // 切开原子
        #expect(SearchText.consistentQuery(raw: raw, shown: d, query: "链接") == nil)
        #expect(SearchText.mappedRanges(raw: raw, shown: d, query: "前（").isEmpty)
    }
    @Test func displayWordContainingTheQueryDoesNotFakeAHit() {
        let raw = "只有（链接）"
        let d = shown(raw, "（链接）", "link")   // 显示为 "(link)"，查询 "link" 在原文里没有命中
        #expect(SearchText.localRanges(in: raw, query: "link").isEmpty)
        #expect(SearchText.consistentQuery(raw: raw, shown: d, query: "link") == nil)
    }
    @Test func identityMapKeepsTheQuery() {
        let d = DisplayedText(text: "abc", map: .identity)
        #expect(SearchText.consistentQuery(raw: "abc", shown: d, query: "b") == "b")
        #expect(SearchText.consistentQuery(raw: "abc", shown: d, query: nil) == nil)
    }
}
