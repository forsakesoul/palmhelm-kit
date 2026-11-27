import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct MarkdownBlocksTests {
    @Test func splitsFencesHeadingsListsQuotesParagraphs() {
        let md = "# 标题\n正文第一行\n第二行\n\n- a\n- b\n1. one\n2. two\n> 引用\n```swift\nlet x = 1\n\nprint(x)\n```\n尾段"
        #expect(MarkdownBlock.parse(md) == [
            .heading(level: 1, text: "标题"),
            .paragraph("正文第一行\n第二行"),
            .bullets(["a", "b"]),
            .numbered(start: 1, items: ["one", "two"]),
            .quote("引用"),
            .code("let x = 1\n\nprint(x)", lang: "swift"),
            .paragraph("尾段"),
        ])
    }

    @Test func orderedListKeepsItsStartNumberAfterAParagraph() {
        // 第二段被段落隔开：编号从 2 继续，而不是重新从 1 开始
        #expect(MarkdownBlock.parse("1. a\n\n中间段落\n\n2. b\n3. c") == [
            .numbered(start: 1, items: ["a"]),
            .paragraph("中间段落"),
            .numbered(start: 2, items: ["b", "c"]),
        ])
    }

    @Test func unclosedFenceAndPlainTextSurvive() {
        #expect(MarkdownBlock.parse("```\nraw") == [.code("raw", lang: nil)])
        #expect(MarkdownBlock.parse("纯文本 **粗** `code`") == [.paragraph("纯文本 **粗** `code`")])
        #expect(MarkdownBlock.parse("#无空格不是标题") == [.paragraph("#无空格不是标题")])
    }

    @Test func tableWithAlignmentAndRows() {
        let md = "| 名称 | 状态 |\n|:---|---:|\n| build | 通过 |\n| test | 失败 |"
        #expect(MarkdownBlock.parse(md) == [.table(header: ["名称", "状态"], rows: [["build", "通过"], ["test", "失败"]])])
    }

    @Test func tableNeedsSeparatorWithSameColumnCount() {
        #expect(MarkdownBlock.parse("| a | b |\n| 1 | 2 |") == [.paragraph("| a | b |\n| 1 | 2 |")]) // 第二行不是分隔行
        #expect(MarkdownBlock.parse("| a | b |\n|---|---|---|") == [.paragraph("| a | b |\n|---|---|---|")]) // 表头与分隔行列数不符：整段原文
        #expect(MarkdownBlock.parse("a | b\n--|--") == [.table(header: ["a", "b"], rows: [])]) // 外侧管道可选
    }

    @Test func escapedPipeIsLiteralAndPadsRowsButEndsOnExtraCells() {
        // 缺格补空；格数多于表头时表格在该行之前结束，该行按原文显示（不静默丢格）
        let md = "| a \\| b | c |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |"
        #expect(MarkdownBlock.parse(md) == [.table(header: ["a | b", "c"], rows: [["1", ""]]), .paragraph("| 1 | 2 | 3 |")])
    }

    @Test func outerPipesAreOptionalAndDataRowsNeedAPipe() {
        // 外侧管道可有可无，允许混用
        #expect(MarkdownBlock.parse("| a | b\n|---|---|\n| 1 | 2 |") == [.table(header: ["a", "b"], rows: [["1", "2"]])])
        #expect(MarkdownBlock.parse("| a | b |\n|---|---") == [.table(header: ["a", "b"], rows: [])]) // 分隔行缺尾部管道，列数相同仍成表
        #expect(MarkdownBlock.parse("| a | b |\n|---") == [.paragraph("| a | b |\n|---")]) // 分隔行只有一列，与表头不符
        // 数据行没有未转义管道：表格在它之前结束，该行按段落处理
        #expect(MarkdownBlock.parse("| a | b |\n|---|---|\n| 1 | 2 |\n只是一句话") == [.table(header: ["a", "b"], rows: [["1", "2"]]), .paragraph("只是一句话")])
    }

    @Test func pipesInsideFenceAreNotATable() {
        let md = "```\n| a | b |\n|---|---|\n```"
        #expect(MarkdownBlock.parse(md) == [.code("| a | b |\n|---|---|", lang: nil)])
    }

    @Test func tableWithoutBlankLinesAroundIsSplit() {
        let md = "正文\n| a | b |\n|---|---|\n| 1 | 2 |\n尾段"
        #expect(MarkdownBlock.parse(md) == [.paragraph("正文"), .table(header: ["a", "b"], rows: [["1", "2"]]), .paragraph("尾段")])
    }
}

/// 准备结果（块切分 + 行内解析 + 高亮）与旧的“视图里逐 Text 解析”逐块一致，并且视图生命周期 memo 只在输入变化时重做。
@Suite(.serialized) struct PreparedMarkdownTests {
    private func oldInline(_ s: String, _ q: String?) -> AttributedString {
        SearchText.marking((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s), query: q)
    }

    private static let corpus = [
        "# 标题 **粗**\n正文 `code` 与 emoji 😀👍🏽\n\n- 项一 *斜*\n- 项二\n3. 三\n4. 四\n> 引用 [链接](x)\n```swift\nlet a = 1 * 2\n```\n| 名 | 值 |\n|---|---|\n| a | **1** |\n| b | 2 |\n尾段",
        "只有一行", "", "```\n未闭合代码\n**不解析**", "| a | b |\n|---|---|\n| 1 |", "中文 **未闭合粗体",
    ]

    @Test func preparedBlocksMatchTheOldPerTextParsing() {
        for text in Self.corpus {
            for q in [nil, "", "项", "CODE"] as [String?] {
                let prepared = PreparedMarkdown(text: text, highlight: q).blocks
                let source = MarkdownBlock.parse(text)
                #expect(prepared.count == source.count)
                for (p, s) in zip(prepared, source) {
                    switch (p, s) {
                    case (.code(let a, let l1), .code(let b, let l2)): #expect(String(a.characters) == b && l1 == l2)
                    case (.heading(let l1, let a), .heading(let l2, let b)): #expect(l1 == l2 && a == oldInline(b, q))
                    case (.bullets(let a), .bullets(let b)): #expect(a == b.map { oldInline($0, q) })
                    case (.numbered(let s1, let a), .numbered(let s2, let b)): #expect(s1 == s2 && a == b.map { oldInline($0, q) })
                    case (.quote(let a), .quote(let b)): #expect(a == oldInline(b, q))
                    case (.table(let h1, let r1, _), .table(let h2, let r2)): #expect(h1 == h2.map { oldInline($0, q) } && r1 == r2.map { $0.map { oldInline($0, q) } })
                    case (.rule, .rule): #expect(true)
                    case (.paragraph(let a), .paragraph(let b)): #expect(a == oldInline(b, q))
                    default: Issue.record("块类型不一致：\(p) vs \(s)")
                    }
                }
            }
        }
    }

    @Test func theMemoReparsesOnlyWhenTextOrHighlightChanges() {
        MarkdownDiagnostics.enabled = true
        defer { MarkdownDiagnostics.enabled = false }
        let memo = PreparedMarkdownMemo()
        MarkdownDiagnostics.reset()
        for _ in 0..<20 { _ = memo.prepared("段落 **一**\n\n- a", highlight: "段") }
        #expect(MarkdownDiagnostics.snapshot().blockParses == 1, "相同 text/highlight 20 轮只解析一次")
        _ = memo.prepared("段落 **一**\n\n- a\n- b", highlight: "段") // 同 ID 增长（改文）
        #expect(MarkdownDiagnostics.snapshot().blockParses == 2)
        _ = memo.prepared("段落 **一**\n\n- a\n- b", highlight: "b") // 高亮变化
        #expect(MarkdownDiagnostics.snapshot().blockParses == 3)
        _ = memo.prepared("段落 **一**\n\n- a\n- b", highlight: nil)
        #expect(MarkdownDiagnostics.snapshot().blockParses == 4)
        let again = memo.prepared("段落 **一**\n\n- a\n- b", highlight: nil)
        #expect(MarkdownDiagnostics.snapshot().blockParses == 4, "回到稳定输入后又复用")
        #expect(again.blocks.count == 2)
    }

    @Test func oversizedTextIsNotRetained() {
        MarkdownDiagnostics.enabled = true
        defer { MarkdownDiagnostics.enabled = false }
        let memo = PreparedMarkdownMemo()
        let huge = String(repeating: "长", count: PreparedMarkdownMemo.retainLimitUTF8 / 3 + 10)
        MarkdownDiagnostics.reset()
        _ = memo.prepared(huge, highlight: nil)
        _ = memo.prepared(huge, highlight: nil)
        #expect(MarkdownDiagnostics.snapshot().blockParses == 2, "超过留存上限的文本不驻留解析副本")
    }
}
