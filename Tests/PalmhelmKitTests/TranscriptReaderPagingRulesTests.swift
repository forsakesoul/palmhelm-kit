import Foundation
import Testing
@testable import PalmhelmKit

// #156：阅读页分页对新表格与分隔线的要求：对齐随页保留、重复表头仍是同一列组、分隔线计入预算。
@Suite struct TranscriptReaderPagingRulesTests {
    private func pages(_ md: String, chars: Int = 1200, leaves: Int = 24) -> [ReaderPage] {
        TranscriptReaderPaging.pages(for: md, markdown: true, pageCharacters: chars, pageLeaves: leaves)
    }
    private func blocksOf(_ p: [ReaderPage]) -> [ReaderBlock] {
        p.flatMap { page -> [ReaderBlock] in if case .markdown(let b) = page.content { return b } else { return [] } }
    }

    @Test func alignmentSurvivesEveryRepeatedHeaderPage() {
        var md = "| 左 | 中 | 右 |\n|:---|:---:|---:|\n"
        for i in 0..<30 { md += "| 第\(i)行左 | 中\(i) | 右\(i) |\n" }
        let ps = pages(md, chars: 120, leaves: 12)
        let tables = blocksOf(ps).compactMap { b -> [ReaderText]? in if case .table(let h, _) = b { return h } else { return nil } }
        #expect(tables.count > 1, "长表应被切成多页")
        for header in tables {
            #expect(header.map(\.alignment) == [.left, .center, .right])
            #expect(header.map(\.plain) == ["左", "中", "右"])
        }
    }

    @Test func issueSampleStaysThreeColumnsAfterPaging() {
        let md = "| 结论 | 依据 | 备注 |\n| --- | --- | --- |\n| 通过 | 测试全绿 | 无 |\n| 待定 | 等待评审 | 见下文 |"
        let ps = pages(md, chars: 20, leaves: 12)
        for case .table(let header, let rows) in blocksOf(ps) {
            #expect(header.count == 3)
            #expect(rows.allSatisfy { $0.count == 3 })
        }
        let allRows = blocksOf(ps).flatMap { b -> [[ReaderText]] in if case .table(_, let r) = b { return r } else { return [] } }
        #expect(allRows.map { $0.map(\.plain) } == [["通过", "测试全绿", "无"], ["待定", "等待评审", "见下文"]])
    }

    @Test func ruleIsAPageLeafAndHasNoText() {
        let ps = pages("前文\n\n---\n\n后文")
        let all = blocksOf(ps)
        #expect(all.contains(.rule))
        #expect(ps.reduce(0) { $0 + $1.leaves } == 3, "前文、分隔线、后文各一个叶子")
        #expect(ps.allSatisfy { $0.visibleText.isEmpty == false || $0.leaves == 0 })
    }

    @Test func manyRulesRespectTheLeafBudgetAcrossPages() {
        let md = (0..<40).map { "段\($0)\n\n---" }.joined(separator: "\n\n")
        let ps = pages(md, chars: 1200, leaves: 24)
        #expect(ps.count > 1, "分隔线也计入叶子预算，不能全部堆进一页")
        #expect(ps.allSatisfy { $0.leaves <= 24 })
    }

    @Test func tableEmptyCellsDoNotShiftColumnsWhenPaged() {
        let md = "| a | b | c |\n|---|---|---|\n|  | 中 |  |\n| 1 |  | 3 |"
        let rows = blocksOf(pages(md, chars: 8, leaves: 6)).flatMap { b -> [[ReaderText]] in if case .table(_, let r) = b { return r } else { return [] } }
        #expect(rows.map { $0.map(\.plain) } == [["", "中", ""], ["1", "", "3"]], "空单元格的位置与文字逐格保留")
    }
}
