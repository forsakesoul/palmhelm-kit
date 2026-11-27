import Foundation
import Testing
@testable import PalmhelmKit

// #156：GFM 表格的识别规则（Palmhelm 的保守边界写在各用例旁），以及分隔线、代码优先、对齐与源范围。
@Suite struct MarkdownTableRulesTests {
    private func table(_ md: String) -> (header: [String], rows: [[String]])? {
        for b in MarkdownBlock.parse(md) { if case .table(let h, let r) = b { return (h, r) } }
        return nil
    }
    private func aligns(_ md: String) -> [MarkdownTableAlignment] {
        MarkdownBlock.parseRanged(md).first { if case .table = $0.block { return true } else { return false } }?.alignments ?? []
    }

    @Test func issueStandardExampleHasThreeColumnsAndTwoDataRows() {
        let md = "| 结论 | 依据 | 备注 |\n| --- | --- | --- |\n| 通过 | **测试** 全绿 | 无 |\n| 待定 | 等待 `review` | 见下文 |"
        let t = table(md)
        #expect(t?.header == ["结论", "依据", "备注"])
        #expect(t?.rows == [["通过", "**测试** 全绿", "无"], ["待定", "等待 `review`", "见下文"]])
    }

    @Test func fourAlignmentsAreKeptFromTheSeparator() {
        let md = "| a | b | c | d |\n|:---|:---:|---:|---|\n| 1 | 2 | 3 | 4 |"
        #expect(aligns(md) == [.left, .center, .right, .unspecified])
    }

    @Test func lfCrlfAndCrGiveTheSameTable() {
        let base = ["| a | b |", "| --- | --- |", "| 1 | 2 |", "| 3 | 4 |"]
        let lf = table(base.joined(separator: "\n"))
        let crlf = table(base.joined(separator: "\r\n"))
        let cr = table(base.joined(separator: "\r"))
        #expect(lf?.rows == [["1", "2"], ["3", "4"]])
        #expect(crlf?.header == lf?.header && crlf?.rows == lf?.rows)
        #expect(cr?.header == lf?.header && cr?.rows == lf?.rows)
    }

    @Test func mixedPipeStylesAndSpacesAreAccepted() {
        let md = "a | b |\n|---|---\n 1 |2| \n| 3 | 4"
        #expect(table(md)?.header == ["a", "b"])
        #expect(table(md)?.rows == [["1", "2"], ["3", "4"]])
    }

    @Test func emptyDeclaredCellsStayInPlace() {
        #expect(table("| a |  | c |\n|---|---|---|\n| 1 |  | 3 |")?.rows == [["1", "", "3"]])
    }

    @Test func escapedPipesAreLiteralAndCodeSpanPipesMustBeEscaped() {
        #expect(table("| a \\| b | c |\n|---|---|\n| `x \\| y` | z |")?.rows == [["`x | y`", "z"]])
        // 偶数个反斜杠后的管道仍分列；只去掉转义管道的那一个反斜杠
        #expect(table("| a\\\\ | b |\n|---|---|\n| 1 | 2 |")?.header == ["a\\\\", "b"])
        #expect(table("| a \\\\\\| b | c |\n|---|---|\n| 1 | 2 |")?.header == ["a \\\\| b", "c"])
    }

    @Test func singleColumnTableNeedsADelimiterPipe() {
        #expect(table("| a |\n| --- |\n| 1 |")?.rows == [["1"]])
        #expect(MarkdownBlock.parse("a\n---") == [.paragraph("a\n---")]) // setext 下划线：保持原有行为
    }

    @Test func ordinaryPipesAndNoDelimiterDoNotOpenATable() {
        #expect(MarkdownBlock.parse("a | b") == [.paragraph("a | b")])
        #expect(MarkdownBlock.parse("| a | b |\n| 1 | 2 |") == [.paragraph("| a | b |\n| 1 | 2 |")])
    }

    @Test func headerAndDelimiterColumnMismatchKeepsTheOriginalText() {
        // 截图形状：表头两列、分隔行与数据行三列——不补表头，整段按原文
        let md = "| 结论 | 依据 |\n|---|---|---|\n| 通过 | 测试 | 无 |"
        #expect(MarkdownBlock.parse(md) == [.paragraph(md)])
    }

    @Test func rowsWithoutUnescapedPipeEndTheTableAndTheRowStaysText() {
        #expect(MarkdownBlock.parse("| a | b |\n|---|---|\n| 1 | 2 |\n\\| 3 \\|") == [.table(header: ["a", "b"], rows: [["1", "2"]]), .paragraph("\\| 3 \\|")])
    }

    @Test func blankLinesAndNewBlocksEndTheTable() {
        #expect(table("| a | b |\n|---|---|\n| 1 | 2 |\n\n| 3 | 4 |")?.rows == [["1", "2"]])
        #expect(MarkdownBlock.parse("| a | b |\n|---|---|\n| 1 | 2 |\n# 标题").last == .heading(level: 1, text: "标题"))
    }

    @Test func pipesInWavyAndBacktickFencesAndIndentedCodeAreNotTables() {
        let wavy = "~~~\n| a | b |\n|---|---|\n~~~"
        #expect(MarkdownBlock.parse(wavy) == [.code("| a | b |\n|---|---|", lang: nil)])
        let ticks = "```\n| a | b |\n|---|---|\n```"
        #expect(MarkdownBlock.parse(ticks) == [.code("| a | b |\n|---|---|", lang: nil)])
        let indented = "    | a | b |\n    |---|---|"
        #expect(MarkdownBlock.parse(indented) == [.paragraph("    | a | b |\n    |---|---|")]) // 缩进代码行保持原文
    }

    @Test func fenceClosesOnlyWithSameCharAndAtLeastTheOpeningLength() {
        let md = "````\n```\n| a | b |\n|---|---|\n```\n| c |\n````\n| d | e |\n|---|---|"
        #expect(MarkdownBlock.parse(md).first == .code("```\n| a | b |\n|---|---|\n```\n| c |", lang: nil))
        #expect(MarkdownBlock.parse(md).last == .table(header: ["d", "e"], rows: []))
    }

    @Test func unclosedFenceReadsToTheEnd() {
        #expect(MarkdownBlock.parse("~~~swift\nlet x = 1\n| a | b |") == [.code("let x = 1\n| a | b |", lang: "swift")])
    }

    @Test func thematicBreaksAreSeparatedFromListsAndSetextUnderlines() {
        #expect(MarkdownBlock.parse("---") == [.rule])
        #expect(MarkdownBlock.parse("正文\n\n***") == [.paragraph("正文"), .rule])
        #expect(MarkdownBlock.parse("* * *") == [.rule])
        #expect(MarkdownBlock.parse("- a\n\n---") == [.bullets(["a"]), .rule])
        #expect(MarkdownBlock.parse("正文\n---") == [.paragraph("正文\n---")])
        #expect(MarkdownBlock.parse("    ---") == [.paragraph("    ---")])
    }

    @Test func cjkAndEmojiBeforeCrlfKeepSourceRangesExact() {
        let md = "中文😀段落\r\n| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n结尾"
        let blocks = MarkdownBlock.parseRanged(md)
        let bytes = Array(md.utf8)
        #expect(blocks.count == 3)
        for b in blocks {
            let slice = String(decoding: bytes[b.utf8Range], as: UTF8.self)
            #expect(!slice.isEmpty)
        }
        #expect(String(decoding: bytes[blocks[1].utf8Range], as: UTF8.self) == "| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n")
        #expect(blocks[0].utf8Range.upperBound == blocks[1].utf8Range.lowerBound)
    }

    // MARK: h30a2（A2-030）

    @Test func paddingIsBoundedForWideTablesAndSourceRowsStayReadable() {
        // 512 列表头、512 个只写一格的数据行：补出的单元格有界，其余数据行仍以原文可读
        var md = "| " + (0..<512).map { "c\($0)" }.joined(separator: " | ") + " |\n|" + Array(repeating: "---", count: 512).joined(separator: "|") + "|\n"
        for i in 0..<512 { md += "| r\(i) |\n" }
        let blocks = MarkdownBlock.parse(md)
        var cells = 0
        var text = ""
        for b in blocks {
            switch b {
            case .table(_, let rows): cells += rows.reduce(0) { $0 + $1.count }
            case .paragraph(let s): text += s + "\n"
            default: break
            }
        }
        #expect(cells <= 4096, "补格的总量必须有上限：\(cells)")
        #expect(text.contains("| r511 |"), "未进入表格的数据行仍按原文显示")
    }

    @Test func fourBacktickFenceIsNotClosedByAnIndentedRun() {
        // 缩进 4 列的四反引号不能关闭外层四反引号围栏；外层围栏内的表格仍是代码
        let md = "````\n| a | b |\n|---|---|\n    ````\n| c | d |\n|---|---|\n````"
        #expect(MarkdownBlock.parse(md) == [.code("| a | b |\n|---|---|\n    ````\n| c | d |\n|---|---|", lang: nil)])
    }

    @Test func spaceThenTabIndentIsNotATable() {
        // 一个空格加一个 Tab 展开到第 4 列：属于缩进代码，不识别为表格
        #expect(MarkdownBlock.parse("| a | b |\n|---|---|\n \t| 1 | 2 |") == [.table(header: ["a", "b"], rows: []), .paragraph(" \t| 1 | 2 |")])
        #expect(MarkdownBlock.parse(" \t| a | b |\n|---|---|") == [.paragraph(" \t| a | b |\n|---|---|")])
    }

    @Test func singleColumnTableMayOmitPipesOnItsAlignedDelimiter() {
        let md = "| a |\n:---:\n| 1 |"
        #expect(MarkdownBlock.parseRanged(md).first?.block == .table(header: ["a"], rows: [["1"]]))
        #expect(MarkdownBlock.parseRanged(md).first?.alignments == [.center])
        // 没有冒号的无管道分隔行仍不成表，保持原文
        #expect(MarkdownBlock.parse("| a |\n---\n| 1 |") == [.paragraph("| a |\n---\n| 1 |")])
    }

    @Test func rulesNeedABlankLineBeforeThemForEveryMarker() {
        #expect(MarkdownBlock.parse("前文\n***\n后文") == [.paragraph("前文\n***\n后文")])
        #expect(MarkdownBlock.parse("前文\n___\n后文") == [.paragraph("前文\n___\n后文")])
        #expect(MarkdownBlock.parse("- a\n***") == [.bullets(["a"]), .paragraph("***")])
        #expect(MarkdownBlock.parse("- a\n\n***") == [.bullets(["a"]), .rule])
        #expect(MarkdownBlock.parse("***") == [.rule])
    }

    @Test func evenBackslashesRightBeforeThePipeStillSplitCells() {
        // 两个反斜杠紧贴管道：偶数个，管道分列，反斜杠原样保留
        let md = "| a\\\\| b |\n|---|---|\n| 1 | 2 |"
        #expect(table(md)?.header == ["a\\\\", "b"])
    }
}
