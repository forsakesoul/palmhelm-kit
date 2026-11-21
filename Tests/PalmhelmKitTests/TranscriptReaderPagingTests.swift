import Foundation
import Testing
@testable import PalmhelmKit

// D1：用户消息折叠是显式 opt-in（默认 assistant 规则与 Mac 不变）；D2：阅读页切页的页预算、无损拼合、块语义保真。
@Suite struct TranscriptReaderPagingTests {
    private func old(_ t: String) -> Bool { t.components(separatedBy: "\n").count > 8 || t.count > 400 }
    private func item(_ role: String, _ text: String) -> TranscriptItem { TranscriptItem(id: "x", role: role, text: text) }

    // MARK: D1 折叠规则

    @Test func userFoldingIsOptInAndAssistantRulesStayTheSame() {
        let long = String(repeating: "字", count: 401)
        #expect(!TranscriptFolding.isFoldable(item("user", long), isLatestStreaming: false), "默认不折叠用户消息（Mac 行为不变）")
        #expect(TranscriptFolding.isFoldable(item("user", long), isLatestStreaming: false, includeUser: true))
        #expect(TranscriptFolding.isFoldable(item("assistant", long), isLatestStreaming: false), "助手默认规则不变")
        #expect(TranscriptFolding.isFoldable(item("assistant", long), isLatestStreaming: false, includeUser: true))
        #expect(!TranscriptFolding.isFoldable(item("assistant", long), isLatestStreaming: true, includeUser: true), "流式尾条不折叠")
        #expect(!TranscriptFolding.isFoldable(item("gap", long), isLatestStreaming: false, includeUser: true), "gap 不折叠")
    }

    @Test func userBoundariesMatchTheAssistantBudget() {
        let cases: [String] = [
            String(repeating: "字", count: 400), String(repeating: "字", count: 401),
            String(repeating: "a\r\n", count: 7) + "a", String(repeating: "a\r\n", count: 8), String(repeating: "a\n", count: 8) + "x",
            String(repeating: "👨‍👩‍👧", count: 400), String(repeating: "👨‍👩‍👧", count: 401), String(repeating: "e\u{301}", count: 401), "", "短",
        ]
        for t in cases {
            #expect(TranscriptFolding.isFoldable(item("user", t), isLatestStreaming: false, includeUser: true) == old(t), "用户 \(t.prefix(6))…")
        }
    }

    @Test func truncatedItemsLabelTheLoadedRange() {
        #expect(TranscriptFolding.characterLabel(String(repeating: "字", count: 4000), truncated: false) == TranscriptFolding.characterLabel(String(repeating: "字", count: 4000)))
        let loaded = TranscriptFolding.characterLabel(String(repeating: "字", count: 4000), truncated: true)
        #expect(loaded != TranscriptFolding.characterLabel(String(repeating: "字", count: 4000)), "截断条目的字数标签写明已加载范围")
        #expect(TranscriptFolding.characterLabel("短", truncated: true) != TranscriptFolding.characterLabel("短"))
    }

    // MARK: D2 纯文本页（用户）

    private func plain(_ pages: [ReaderPage]) -> [String] {
        pages.map { if case .plain(let s, _) = $0.content { return s } else { Issue.record("不是纯文本页"); return "" } }
    }

    @Test func plainPagesAreBoundedAndLossless() {
        let limit = TranscriptReaderPaging.pageCharacters
        var corpus = [
            String(repeating: "长", count: 19_500), String(repeating: "a\r\n", count: 5000), String(repeating: "👨‍👩‍👧x", count: 3000),
            String(repeating: "e\u{301}", count: 4000), String(repeating: "词 ", count: 3000), "短文", "",
            (0..<200).map { "第 \($0) 行：" + String(repeating: "内容", count: 30) }.joined(separator: "\n"),
        ]
        var seed: UInt64 = 7
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let atoms = ["a", "中", "\n", "\r\n", "😀", "👨‍👩‍👧", "e\u{301}", " ", "，", "🇨🇳"]
        for _ in 0..<200 { corpus.append((0..<(next() % 6000)).map { _ in atoms[next() % atoms.count] }.joined()) }
        for text in corpus {
            let pages = TranscriptReaderPaging.pages(for: text, markdown: false)
            let chunks = plain(pages)
            #expect(chunks.joined() == text, "所有页拼回原文，不丢不重不 trim")
            #expect(chunks.allSatisfy { $0.count <= limit }, "每页不超过 \(limit) 字符")
            #expect(pages.count >= 1)
            if text.count > limit { #expect(pages.count >= text.count / limit, "超长单行 / 无换行文本也被切开") }
        }
    }

    @Test func plainPagesPreferLineAndWordBoundaries() {
        let text = (0..<120).map { "第 \($0) 行：" + String(repeating: "字", count: 20) }.joined(separator: "\n")
        let chunks = plain(TranscriptReaderPaging.pages(for: text, markdown: false))
        #expect(chunks.dropLast().allSatisfy { $0.hasSuffix("\n") }, "有换行时在换行之后断页")
    }

    // MARK: D2 Markdown 页（助手）

    /// 页里的块（显示口径）。
    private func blocks(_ pages: [ReaderPage]) -> [[ReaderBlock]] {
        pages.map { if case .markdown(let b) = $0.content { return b } else { Issue.record("不是 Markdown 页"); return [] } }
    }
    private func plainOf(_ b: ReaderBlock) -> [String] {
        switch b {
        case .code(let s, _, _): [s]
        case .heading(_, let t), .quote(let t), .paragraph(let t): [t.plain]
        case .bullets(let i), .numbered(_, let i): i.map(\.plain)
        case .table(let h, let r): (h + r.flatMap { $0 }).map(\.plain)
        }
    }

    /// 独立于分页自报数字的“实际渲染输入”口径：PreparedBlocksView 会为每个块创建多少个 Text、总显示字符多少。
    private func rendered(_ page: ReaderPage) -> (characters: Int, leaves: Int) {
        guard case .markdown(let bs) = page.content else { return (0, 0) }
        var chars = 0, leaves = 0
        for b in bs {
            switch b {
            case .code(let s, let lang, _): chars += s.count + (lang?.count ?? 0); leaves += 1 + (lang == nil ? 0 : 1) // 语言标签也是实际渲染的 Text
            case .heading(_, let t), .quote(let t), .paragraph(let t): chars += t.count; leaves += 1
            case .bullets(let items), .numbered(_, let items): chars += items.reduce(0) { $0 + $1.count }; leaves += items.count * 2 // 标记 + 正文
            case .table(let h, let r): let cells = h + r.flatMap { $0 }; chars += cells.reduce(0) { $0 + $1.count }; leaves += cells.count
            }
        }
        return (chars, leaves)
    }

    private func checkBudget(_ pages: [ReaderPage], _ label: String, characters: Int = TranscriptReaderPaging.pageCharacters, leaves: Int = TranscriptReaderPaging.pageLeaves) {
        for (i, p) in pages.enumerated() {
            let r = rendered(p)
            #expect(r.characters <= characters, "\(label) 第 \(i) 页实际字符 \(r.characters)")
            #expect(r.leaves <= leaves, "\(label) 第 \(i) 页实际叶子 \(r.leaves)")
            #expect(p.characters == r.characters && p.leaves == r.leaves, "\(label) 第 \(i) 页自报预算与实际渲染输入一致")
        }
    }

    @Test func aShortReplyIsASinglePageWithTheSameBlocks() {
        let text = "# 标题\n正文 **粗**\n\n- 一\n- 二\n\n```swift\nlet a = 1\n```"
        let pages = blocks(TranscriptReaderPaging.pages(for: text, markdown: true))
        #expect(pages.count == 1)
        #expect(pages[0].flatMap(plainOf) == ["标题", "正文 粗", "一", "二", "let a = 1"], "显示文字去掉语法字符，样式在 run 里")
    }

    @Test func aHugeParagraphIsSplitAndLossless() {
        let big = String(repeating: "这是没有换行也没有空格的巨段落内容。", count: 2000)
        let pages = TranscriptReaderPaging.pages(for: big, markdown: true)
        checkBudget(pages, "巨段")
        #expect(blocks(pages).flatMap { $0 }.flatMap(plainOf).joined() == big)
        #expect(pages.count >= big.count / TranscriptReaderPaging.pageCharacters)
    }

    @Test func aHugeCodeBlockKeepsLanguageAndConcatenatesBack() {
        let longLine = String(repeating: "x", count: 5000)
        let code = ["let a = 1", longLine, "print(a)", "", "tail"].joined(separator: "\n")
        let pages = TranscriptReaderPaging.pages(for: "```swift\n\(code)\n```", markdown: true)
        checkBudget(pages, "代码")
        let chunks = blocks(pages).flatMap { $0 }.map { b -> (String, String?) in if case .code(let s, let l, _) = b { return (s, l) } else { return ("?", nil) } }
        #expect(chunks.map(\.0).joined() == code)
        #expect(chunks.allSatisfy { $0.1 == "swift" })
    }

    @Test func numberedListsKeepStartNumbersAcrossPages() {
        let items = (1...200).map { "第 \($0) 项：" + String(repeating: "说明", count: 12) }
        let text = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
        checkBudget(pages, "编号列表")
        var seen = 0
        for block in blocks(pages).flatMap({ $0 }) {
            guard case .numbered(let start, let its) = block else { Issue.record("应只有编号列表"); continue }
            #expect(start == seen + 1)
            seen += its.count
        }
        #expect(seen == 200)
    }

    @Test func anOversizedListItemIsSplitWithoutLosingText() {
        let huge = String(repeating: "超长项目文字", count: 800)
        let pages = TranscriptReaderPaging.pages(for: "- 前\n- \(huge)\n- 后", markdown: true)
        checkBudget(pages, "超长项")
        var texts: [String] = []
        for block in blocks(pages).flatMap({ $0 }) {
            switch block {
            case .bullets(let items): texts += items.map(\.plain)
            case .paragraph(let t): texts.append(t.plain)
            default: Issue.record("意外块")
            }
        }
        #expect(texts.first == "前" && texts.last == "后")
        #expect(texts.dropFirst().dropLast().joined() == huge)
    }

    @Test func tablesRepeatTheHeaderAndKeepEveryRow() {
        let header = ["名称", "编号", "说明", "数量"]
        let rows = (0..<60).map { ["行\($0)", "\($0)", "说明文字\($0)", "x"] }
        let text = "| " + header.joined(separator: " | ") + " |\n|---|---|---|---|\n" + rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
        let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
        checkBudget(pages, "表格")
        var got: [[String]] = []
        for block in blocks(pages).flatMap({ $0 }) {
            guard case .table(let h, let r) = block else { Issue.record("应只有表格"); continue }
            #expect(h.map(\.plain) == header, "每页重复表头")
            got += r.map { $0.map(\.plain) }
        }
        #expect(got == rows)
        #expect(pages.count > 1)
    }

    @Test func anOversizedTableCellIsSplitIntoContinuationRows() {
        let big = String(repeating: "单元格里很长的文字", count: 600)
        let text = "| 名 | 值 |\n|---|---|\n| a | \(big) |\n| b | 2 |"
        let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
        checkBudget(pages, "巨单元格")
        var rows: [[String]] = []
        for block in blocks(pages).flatMap({ $0 }) { if case .table(_, let r) = block { rows += r.map { $0.map(\.plain) } } }
        #expect(rows.first?.first == "a" && rows.last == ["b", "2"])
        #expect(rows.dropLast().map { $0[1] }.joined() == big)
        #expect(rows.dropFirst().dropLast().allSatisfy { $0[0].isEmpty })
    }

    @Test func aHeadingIsNotLeftAloneAtTheEndOfAPage() {
        let first = String(repeating: "甲", count: 1150)
        let text = first + "\n\n## 小节标题\n后续段落内容" + String(repeating: "乙", count: 100)
        let pages = blocks(TranscriptReaderPaging.pages(for: text, markdown: true))
        #expect(pages.count >= 2)
        for p in pages.dropLast() { if case .heading? = p.last { Issue.record("标题孤立在页尾") } }
    }

    @Test func aNarrowBudgetStillRespectsBothLimitsOnAMixedDocument() {
        var doc = "# 总览\n\n"
        doc += (0..<40).map { "- 项目 \($0)：" + String(repeating: "说明", count: 20) }.joined(separator: "\n") + "\n\n"
        doc += "| a | b | c |\n|---|---|---|\n" + (0..<30).map { "| \($0) | 值\($0) | 文字文字文字 |" }.joined(separator: "\n") + "\n\n"
        doc += "```\n" + (0..<150).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n") + "\n```\n"
        let pages = TranscriptReaderPaging.pages(for: doc, markdown: true, pageCharacters: 600, pageLeaves: 12)
        #expect(pages.count > 5)
        checkBudget(pages, "混合窄预算", characters: 600, leaves: 12)
    }

    // MARK: D-R1（A1-019）：表头 / 行 / 列 / 标题迁移都消费页预算；列表标记 Text 计入叶子

    @Test func aWideHeaderIsSplitAndStaysWithinTheBudget() {
        let h = String(repeating: "H", count: 2500)
        let pages = TranscriptReaderPaging.pages(for: "| \(h) | v |\n|---|---|\n| a | b |", markdown: true)
        checkBudget(pages, "超宽表头")
        var header = "", vHeader = ""
        var rows: [[String]] = []
        for case .table(let hh, let rr) in blocks(pages).flatMap({ $0 }) {
            header += hh[0].plain; vHeader += hh[1].plain
            rows += rr.map { $0.map(\.plain) }
        }
        #expect(header.count >= 2500, "表头文字完整保留（含分片）：\(header.count)")
        #expect(rows.first == ["a", "b"])
        #expect(pages.count > 1)
    }

    @Test func aThirtyColumnHeaderIsSplitIntoColumnGroupsKeepingOwnership() {
        let cols = 30
        let text = "|" + (0..<cols).map { " h\($0) " }.joined(separator: "|") + "|\n|" + (0..<cols).map { _ in "---" }.joined(separator: "|") + "|\n|" + (0..<cols).map { " v\($0) " }.joined(separator: "|") + "|"
        let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
        checkBudget(pages, "30 列表头")
        var pairs: [String: String] = [:]
        for case .table(let h, let r) in blocks(pages).flatMap({ $0 }) {
            for row in r { for (i, c) in row.enumerated() { pairs[h[i].plain] = c.plain } }
        }
        #expect(pairs.count == cols)
        for i in 0..<cols { #expect(pairs["h\(i)"] == "v\(i)", "列 \(i) 的单元格仍在自己的表头下") }
        #expect(pages.count > 1)
    }

    @Test func headerPlusBigCellsRespectTheRowBudget() {
        let text = "| name | value |\n|---|---|\n| \(String(repeating: "a", count: 600)) | \(String(repeating: "b", count: 600)) |"
        let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
        checkBudget(pages, "表头 + 大单元格")
        var a = "", b = ""
        for case .table(_, let r) in blocks(pages).flatMap({ $0 }) { for row in r { a += row[0].plain; b += row[1].plain } }
        #expect(a == String(repeating: "a", count: 600) && b == String(repeating: "b", count: 600))
    }

    @Test func aMigratedHeadingConsumesThePageBudget() {
        let text = String(repeating: "x", count: 1150) + "\n\n# " + String(repeating: "h", count: 38) + "\n\n" + String(repeating: "y", count: 1200)
        let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
        checkBudget(pages, "标题迁移")
        #expect(blocks(pages).flatMap { $0 }.flatMap(plainOf).joined().count == 1150 + 38 + 1200)
    }

    @Test func listMarkersCountAsTextLeaves() {
        let bullets = (0..<24).map { "- b\($0)" }.joined(separator: "\n")
        let pages = TranscriptReaderPaging.pages(for: bullets, markdown: true)
        checkBudget(pages, "24 条短列表")
        #expect(pages.count >= 2, "24 项实际 48 个 Text，不能挤在一页")
        #expect(pages.allSatisfy { rendered($0).leaves <= 24 })
    }

    @Test func everyDefaultBudgetCorpusRendersWithinBudget() {
        var corpus: [String] = []
        for cols in [1, 2, 6, 13, 30] {
            let h = "|" + (0..<cols).map { " 头\($0) " }.joined(separator: "|") + "|\n|" + (0..<cols).map { _ in "---" }.joined(separator: "|") + "|"
            for cell in [3, 300, 1500] {
                let row = "|" + (0..<cols).map { _ in " " + String(repeating: "格", count: cell) + " " }.joined(separator: "|") + "|"
                corpus.append(h + "\n" + row + "\n" + row)
            }
        }
        for n in [1, 11, 12, 13, 25, 100] { corpus.append((0..<n).map { "- 项 \($0) " + String(repeating: "字", count: $0 % 7 * 90) }.joined(separator: "\n")) }
        for n in [1150, 1190, 1199, 1200] { corpus.append(String(repeating: "x", count: n) + "\n\n## 标题\n\n" + String(repeating: "y", count: 1200)) }
        for text in corpus { checkBudget(TranscriptReaderPaging.pages(for: text, markdown: true), String(text.prefix(12))) }
    }

    // MARK: D-R2：按显示字符 / 属性 run 切分，行内样式跨页不丢

    private func runs(_ t: ReaderText) -> (strong: Int, code: Int, links: Int) {
        var s = 0, c = 0, l = 0
        for r in t.text.runs {
            let n = t.text.characters[r.range].count
            if r.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { s += n }
            if r.inlinePresentationIntent?.contains(.code) == true { c += n }
            if r.link != nil { l += n }
        }
        return (s, c, l)
    }

    @Test func aHugeStrongSpanKeepsItsStyleOnEveryPage() {
        let text = "**" + String(repeating: "a", count: 1500) + "**"
        let whole = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))!
        let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
        checkBudget(pages, "巨 strong")
        var shown = 0
        for case .paragraph(let t) in blocks(pages).flatMap({ $0 }) {
            #expect(runs(t).strong == t.count, "每页都是加粗，没有字面 ** 字符")
            #expect(!t.plain.contains("*"))
            shown += t.count
        }
        #expect(shown == whole.characters.count && pages.count == 2, "显示字符与整段系统解析一致")
    }

    @Test func linksAndInlineCodeSurviveAcrossPageBoundaries() {
        let url = "https://example.com/very/long/path"
        let text = String(repeating: "前", count: 1190) + " [" + String(repeating: "链", count: 40) + "](\(url)) `" + String(repeating: "c", count: 1300) + "` 尾"
        let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
        var link = 0, code = 0
        var urls = Set<URL>()
        for case .paragraph(let t) in blocks(pages).flatMap({ $0 }) {
            link += runs(t).links; code += runs(t).code
            for r in t.text.runs { if let u = r.link { urls.insert(u) } }
        }
        #expect(link == 40 && urls == [URL(string: url)!], "跨页的链接文字完整且保留同一链接")
        #expect(code == 1300, "跨页的 inline code 完整保留样式")
    }

    @Test func styledCellsAndItemsAreSplitByDisplayCharactersToo() {
        let strongItem = "**" + String(repeating: "列", count: 1500) + "**"
        let list = TranscriptReaderPaging.pages(for: "- " + strongItem, markdown: true)
        var strong = 0, total = 0
        for b in blocks(list).flatMap({ $0 }) {
            switch b {
            case .bullets(let items): for t in items { strong += runs(t).strong; total += t.count }
            case .paragraph(let t): strong += runs(t).strong; total += t.count
            default: break
            }
        }
        #expect(strong == 1500 && total == 1500, "列表项被切开后每片仍是加粗")
        let table = TranscriptReaderPaging.pages(for: "| a | b |\n|---|---|\n| x | \(strongItem) |", markdown: true)
        checkBudget(table, "样式单元格")
        var cellStrong = 0
        for case .table(_, let rows) in blocks(table).flatMap({ $0 }) { for row in rows { cellStrong += runs(row[1]).strong } }
        #expect(cellStrong == 1500)
    }

    // MARK: 搜索命中页（D-R3：显示口径 + 跨页）

    @Test func searchHitsMapToTheirPage() {
        let text = (0..<400).map { $0 == 300 ? "这一行含有 Needle 关键词" : "普通行 \($0) " + String(repeating: "字", count: 30) }.joined(separator: "\n")
        for markdown in [false, true] {
            let doc = TranscriptReaderPaging.document(for: text, markdown: markdown)
            let hit = doc.firstPage(containing: "needle")
            #expect(hit != nil && hit! > 0, "命中不在首页（markdown=\(markdown)）")
            #expect(doc.pages[hit!].visibleText.localizedCaseInsensitiveContains("needle"))
            for i in 0..<hit! { #expect(!doc.pages[i].visibleText.localizedCaseInsensitiveContains("needle")) }
            #expect(doc.firstPage(containing: "不存在的词") == nil)
            #expect(doc.firstPage(containing: "") == nil)
        }
    }

    @Test func aHitCrossingAPageBoundaryLandsOnItsStartPageAndHighlightsBothParts() {
        let text = String(repeating: "x", count: 2398) + "NEEDLE" + String(repeating: "z", count: 100)
        let doc = TranscriptReaderPaging.document(for: text, markdown: false)
        #expect(doc.pages.count == 3)
        #expect(doc.firstPage(containing: "NEEDLE") == 1, "跨页命中落在起始页（不是 nil / 首页）")
        let ms = doc.matches(for: "needle")
        #expect(ms == [2398..<2404])
        // 两页各自能标出自己的那一部分
        var marked = 0
        for p in doc.pages {
            guard case .plain(let s, let o) = p.content else { continue }
            #expect(o == doc.pages.prefix(while: { $0 != p }).reduce(0) { $0 + $1.characters })
            let a = SearchText.marking(s, offset: o, matches: ms)
            marked += a.runs.filter { $0.backgroundColor != nil }.reduce(0) { $0 + a.characters[$1.range].count }
        }
        #expect(marked == 6, "跨页命中的 6 个字符在两页上合计全部标出")
    }

    @Test func markdownSearchUsesTheDisplayTextAcrossMarkupAndPages() {
        let text = String(repeating: "x", count: 1200) + "\n\nalpha **beta**"
        let doc = TranscriptReaderPaging.document(for: text, markdown: true)
        #expect(doc.firstPage(containing: "alpha beta") == 1, "显示文字口径：跨粗体标记的命中，落在含它的页")
        #expect(doc.matches(for: "alpha beta").count == 1)
        // 命中跨 strong 边界、同一页内也成立
        let two = TranscriptReaderPaging.document(for: "前 **加粗词** 后", markdown: true)
        #expect(two.firstPage(containing: "加粗词 后") == 0)
    }

    // MARK: v3（A1-020）：语言标签预算 / 标题不孤立 / 宽表定位

    @Test func aHugeLanguageLabelCannotBypassTheCharacterBudget() {
        let text = "```" + String(repeating: "L", count: 2500) + "\nx\n```"
        let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
        checkBudget(pages, "超长语言标签")
        for case .code(let body, let lang, _) in blocks(pages).flatMap({ $0 }) {
            #expect((lang?.count ?? 0) <= 40, "语言标签有界呈现：\(lang?.count ?? 0)")
            #expect(body.count <= TranscriptReaderPaging.pageCharacters)
        }
        let normal = TranscriptReaderPaging.pages(for: "```swift\nlet a = 1\n```", markdown: true)
        guard case .code(_, let lang, _)? = blocks(normal).first?.first else { Issue.record("应是代码块"); return }
        #expect(lang == "swift", "正常语言标签不变")
    }

    @Test func aHeadingIsNeverLeftAtThePageEndEvenWhenTheNextBlockIsBig() {
        for (before, headingLen, after) in [(1150, 40, 1200), (1190, 4, 1200), (1100, 90, 5000), (600, 20, 1190)] {
            let text = String(repeating: "x", count: before) + "\n\n## " + String(repeating: "h", count: headingLen) + "\n\n" + String(repeating: "y", count: after)
            let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
            checkBudget(pages, "标题 \(before)/\(headingLen)/\(after)")
            for (i, p) in blocks(pages).enumerated() where i < pages.count - 1 { if case .heading? = p.last { Issue.record("标题孤立在第 \(i) 页末（\(before)/\(headingLen)/\(after)）") } }
            #expect(blocks(pages).flatMap { $0 }.flatMap(plainOf).joined().count == before + headingLen + after, "不丢字")
        }
    }

    @Test func searchInAWideTableOpensThePageThatActuallyContainsTheHit() {
        let cols = 30
        let text = "|" + (0..<cols).map { " H\($0) " }.joined(separator: "|") + "|\n|" + (0..<cols).map { _ in "---" }.joined(separator: "|") + "|\n"
            + (0..<2).map { r in "|" + (0..<cols).map { " R\(r)C\($0) " }.joined(separator: "|") + "|" }.joined(separator: "\n")
        let doc = TranscriptReaderPaging.document(for: text, markdown: true)
        #expect(doc.pages.count > 2)
        for q in ["H29", "R0C29", "R0C15", "R1C0", "H0"] {
            guard let i = doc.firstPage(containing: q) else { Issue.record("\(q) 没有命中页"); continue }
            #expect(doc.pages[i].visibleText.contains(q), "\(q)：返回的第 \(i) 页必须含命中")
            // 且是阅读顺序里第一个含命中的页
            for j in 0..<i { #expect(!doc.pages[j].visibleText.contains(q), "\(q)：更早的第 \(j) 页也含命中 hit=\(i) page\(j)=\(doc.pages[j].visibleText.prefix(120).replacingOccurrences(of: "\n", with: "|"))") }
        }
    }

    @Test func codePagesHighlightTheHitAndKeepTheTrailingNewlineTrim() throws {
        let code = (0..<300).map { $0 == 250 ? "let NEEDLE = \($0)" : "line \($0) " + String(repeating: "x", count: 30) }.joined(separator: "\n")
        let doc = TranscriptReaderPaging.document(for: "```swift\n\(code)\n```", markdown: true)
        let ms = doc.matches(for: "needle")
        #expect(ms.count == 1)
        let page = try #require(doc.firstPage(containing: "needle"))
        #expect(page > 0 && doc.pages[page].visibleText.contains("NEEDLE"))
        guard case .markdown(let blocks) = doc.pages[page].content else { Issue.record("应是 Markdown 页"); return }
        let prepared = PreparedMarkdown(readerBlocks: blocks, matches: ms)
        var marked = 0
        for case .code(let a, _) in prepared.blocks { marked += a.runs.filter { $0.backgroundColor != nil }.reduce(0) { $0 + a.characters[$1.range].count } }
        #expect(marked == 6, "代码页里的命中被标出（\(marked)）")
        let other = PreparedMarkdown(readerBlocks: blocks, matches: [])
        for case .code(let a, _) in other.blocks { #expect(a.runs.allSatisfy { $0.backgroundColor == nil }, "无命中不标") }
    }

    // MARK: v4（A1-021）：文首标题 / 空 span

    @Test func aHeadingAtTheStartOfTheDocumentIsNotLeftAloneEither() {
        let h = "## " + String(repeating: "H", count: 40)
        let nexts: [(String, Int)] = [
            (String(repeating: "y", count: 1200), 1200),
            ((0..<60).map { "- 项 \($0) " + String(repeating: "字", count: 30) }.joined(separator: "\n"), 0),
            ("```swift\n" + (0..<200).map { "line \($0) xxxxxxxx" }.joined(separator: "\n") + "\n```", 0),
            ("| a | b |\n|---|---|\n" + (0..<80).map { "| \($0) | 值\($0) |" }.joined(separator: "\n"), 0),
        ]
        for (next, _) in nexts {
            let pages = TranscriptReaderPaging.pages(for: h + "\n\n" + next, markdown: true)
            checkBudget(pages, "文首标题 + " + String(next.prefix(6)))
            #expect(pages.count > 1)
            for (i, p) in blocks(pages).enumerated() where i < pages.count - 1 {
                if case .heading? = p.last { Issue.record("文首标题（\(String(next.prefix(6)))…）孤立在第 \(i) 页末") }
            }
            if case .heading? = blocks(pages)[0].first { #expect(blocks(pages)[0].count > 1, "第一页除标题外还有后续内容") }
        }
        // 无损：文首标题 + 长段落
        let text = h + "\n\n" + String(repeating: "y", count: 1200)
        let pages = TranscriptReaderPaging.pages(for: text, markdown: true)
        #expect(blocks(pages).flatMap { $0 }.flatMap(plainOf).joined().count == 40 + 1200)
    }

    @Test func emptyTablePlaceholderSpansNeverBlockTheEarliestRealHit() {
        let text = "| NAME | VALUE |\n|---|---|\n| a | " + String(repeating: "x", count: 7000) + " |\n| NAME | tail |"
        let doc = TranscriptReaderPaging.document(for: text, markdown: true)
        let containing = doc.pages.indices.filter { doc.pages[$0].visibleText.contains("NAME") }
        #expect(containing.count > 1)
        #expect(doc.firstPage(containing: "NAME") == containing.first, "阅读顺序里最早含命中的页（实际 \(String(describing: doc.firstPage(containing: "NAME")))，含命中的页 \(containing)）")
        #expect(doc.pages.allSatisfy { $0.spans.allSatisfy { !$0.isEmpty } }, "空 / 零宽占位 span 不参与")
    }
}
