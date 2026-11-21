import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct SearchTextTests {
    /// 片段里被标了底色的文字（按出现顺序）。
    private func highlightedPieces(_ a: AttributedString) -> [String] {
        a.runs.compactMap { run in run.backgroundColor == nil ? nil : String(a[run.range].characters) }
    }

    @Test func highlightsUTF16RangeAndKeepsText() {
        let snippet = "the zeta-marker is here"
        let out = SearchText.highlighted(snippet: snippet, ranges: [[4, 11]])
        #expect(String(out.characters) == snippet)
        #expect(highlightedPieces(out) == ["zeta-marker"])
    }

    @Test func proxyPairIsHighlightedAsAWhole() {
        // "a😀b"：😀 占 UTF-16 的 [1, 2)。
        let out = SearchText.highlighted(snippet: "a😀b", ranges: [[1, 2]])
        #expect(highlightedPieces(out) == ["😀"])
    }

    @Test func rangeInsideProxyPairIsIgnored() {
        #expect(highlightedPieces(SearchText.highlighted(snippet: "a😀b", ranges: [[2, 1]])).isEmpty)
        #expect(highlightedPieces(SearchText.highlighted(snippet: "a😀b", ranges: [[1, 1]])).isEmpty)
    }

    @Test func invalidRangesAreIgnoredWithoutCrashing() {
        let snippet = "abcdef"
        let bad: [[Int]] = [[-1, 2], [0, 0], [0, -3], [5, 3], [3, 5], [0, 100], [7, 1], [0], [0, 1, 2], []]
        let out = SearchText.highlighted(snippet: snippet, ranges: bad)
        #expect(String(out.characters) == snippet)
        #expect(highlightedPieces(out).isEmpty)
    }

    @Test func overlappingRangeIsSkippedAndUnorderedRangesAreSorted() {
        let snippet = "abcdefgh"
        let overlap = SearchText.highlighted(snippet: snippet, ranges: [[0, 4], [2, 4]])
        #expect(highlightedPieces(overlap) == ["abcd"])
        let unordered = SearchText.highlighted(snippet: snippet, ranges: [[5, 2], [0, 2]])
        #expect(highlightedPieces(unordered) == ["ab", "fg"])
    }

    @Test func localRangesAreCaseInsensitiveUTF16Offsets() {
        #expect(SearchText.localRanges(in: "Zeta zeta ZETA", query: "zeta") == [[0, 4], [5, 4], [10, 4]])
        #expect(SearchText.localRanges(in: "😀Zeta", query: "zeta") == [[2, 4]])
        #expect(SearchText.localRanges(in: "aaaa", query: "aa") == [[0, 2], [2, 2]])
        #expect(SearchText.localRanges(in: "anything", query: "").isEmpty)
        #expect(SearchText.localRanges(in: "没有", query: "找到").isEmpty)
    }

    @Test func highlightedTextMarksLocalMatches() {
        let out = SearchText.highlightedText("Foo bar FOO", query: "foo")
        #expect(String(out.characters) == "Foo bar FOO")
        #expect(highlightedPieces(out) == ["Foo", "FOO"])
    }

    @Test func normalizedQueryTrimsAndEnforcesUTF16Length() {
        #expect(SearchText.normalizedQuery("  a ") == nil)
        #expect(SearchText.normalizedQuery(" ab ") == "ab")
        #expect(SearchText.normalizedQuery("测试") == "测试")
        #expect(SearchText.normalizedQuery(String(repeating: "x", count: 128)) != nil)
        #expect(SearchText.normalizedQuery(String(repeating: "x", count: 129)) == nil)
        #expect(SearchText.normalizedQuery("   ") == nil)
    }

    @Test func busyIsTheOnlyConflictMessage() {
        #expect(SearchText.failure(BridgeError.http(status: 409)) == "上一次搜索还在进行，稍后再试")
        #expect(SearchText.failure(BridgeError.http(status: 500)) == "搜索失败，请稍后再试")
        #expect(SearchText.failure(URLError(.timedOut)) == "搜索失败，请稍后再试")
    }

    @Test func targetFilterMatchesAcrossFieldsCaseInsensitively() {
        let t = TargetSummary(
            projectName: "reins", agentName: "Alpha", topic: TargetTopic(text: "Zeta Marker", source: "pane"),
            location: TargetLocation(workspace: "W1", tab: nil, pane: nil),
            repo: TargetRepo(name: "Repo", branch: "feature/x"))
        #expect(TargetFilter.matches(t, query: "alpha"))
        #expect(TargetFilter.matches(t, query: "MARKER"))
        #expect(TargetFilter.matches(t, query: "feature"))
        #expect(TargetFilter.matches(t, query: "repo"))
        #expect(TargetFilter.matches(t, query: "reins"))
        #expect(TargetFilter.matches(t, query: "w1"))
        #expect(!TargetFilter.matches(t, query: "nope"))
        #expect(TargetFilter.matches(t, query: ""))
        #expect(TargetFilter.matches(t, query: "   "))
    }

    @Test func decodesSearchResponseWithOptionalPageBefore() throws {
        let json = """
        {"results":[{"targetId":"t1","itemId":"i1","sessionEpoch":"e1","role":"assistant","t":1756880000000,"snippet":"…the zeta-marker is here…","ranges":[[4,11]]},
          {"targetId":"t2","itemId":"i1","sessionEpoch":"e2","pageBefore":"cur","role":"user","snippet":"x","ranges":[]}],
         "partial":true,"scanned":{"targets":2,"pages":3},"skipped":[{"targetId":"t3","reason":"budget"}]}
        """
        let r = try JSONDecoder().decode(SearchResponse.self, from: Data(json.utf8))
        #expect(r.results.count == 2)
        #expect(r.results[0].pageBefore == nil)
        #expect(r.results[0].ranges == [[4, 11]])
        #expect(r.results[1].pageBefore == "cur")
        #expect(r.results[0].id != r.results[1].id)
        #expect(r.partial && r.scanned.pages == 3 && r.skipped.first?.reason == "budget")
    }

    @Test func markdownHighlightIgnoresSyntaxAndKeepsStyleOnly() {
        // 渲染后的可见文字是 "Foo bar foo"；** 与反引号不参与匹配，代码与粗体文字照常标。
        let parsed = try! AttributedString(markdown: "**Foo** bar `foo`", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let out = SearchText.marking(parsed, query: "foo")
        #expect(String(out.characters) == "Foo bar foo")
        #expect(highlightedPieces(out) == ["Foo", "foo"])
        #expect(highlightedPieces(SearchText.marking(parsed, query: nil)).isEmpty)
        #expect(highlightedPieces(SearchText.marking(parsed, query: "")).isEmpty)
    }

    @Test func searchPathAndLimitMatchContract() {
        #expect(BridgeAPI.Path.search == "/v1/search")
        #expect(BridgeAPI.searchLimit == 30)
    }
}
