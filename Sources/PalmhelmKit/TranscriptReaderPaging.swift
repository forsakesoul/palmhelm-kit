import Foundation

// D2（A1-013 §7）：长文按页阅读的纯切页规则（两端可共用，本期只有 iOS 消费）。
// 只改变展示：页不删除、不改写正文，所有页按顺序拼回即原文（用户纯文本逐字符；助手 Markdown 逐块语义，被切开的块按下面的规则拼合）。
// 页预算同时限制源字符数（Character）与 Text 叶子数；单个超长段 / 代码 / 表格单元格也被切开，不留无界大块。

/// 一段带行内样式的显示文字（已解析的 AttributedString）及其在“全文显示流”中的起始偏移（Character）。
/// 分页在显示字符上切，被切开的 strong / code / link 样式随片保留；复制全文另用源正文，不从这里拼。
public struct ReaderText: Equatable, Sendable {
    public let text: AttributedString
    public let offset: Int
    public let count: Int
    public init(_ text: AttributedString, offset: Int) {
        self.text = text; self.offset = offset; self.count = text.characters.count
    }
    public var plain: String { String(text.characters) }
    public var span: Range<Int> { offset..<(offset + count) }
}

/// 阅读页里的一个块（显示口径）。代码块没有行内样式，直接保留字符串。
public enum ReaderBlock: Equatable, Sendable {
    case code(String, lang: String?, offset: Int)
    case heading(level: Int, ReaderText)
    case bullets([ReaderText])
    case numbered(start: Int, [ReaderText])
    case quote(ReaderText)
    case table(header: [ReaderText], rows: [[ReaderText]])
    case paragraph(ReaderText)
}

public struct ReaderPage: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// 用户消息：纯文本页（不解析 Markdown）；offset 为本页在全文中的起始偏移。
        case plain(String, offset: Int)
        /// 助手回复：一页的块（已按块语义与显示字符切分）。
        case markdown([ReaderBlock])
    }

    public let content: Content
    /// 本页显示字符数（Character）与实际会挂载的 Text 叶子数（列表标记、语言标签、表格单元格各算一个），预算核验用。
    public let characters: Int
    public let leaves: Int
    /// 本页各段文字在全文显示流中的区间（按偏移升序，不相交）：搜索命中按它定位页并分段高亮。
    public let spans: [Range<Int>]
}

/// 一篇正文的切页结果：页 + 全文显示流（各叶子文字按源顺序拼接，叶子之间 "\n"，同一叶子被切开的片相邻无分隔），搜索按它匹配。
public struct ReaderDocument: Equatable, Sendable {
    public let pages: [ReaderPage]
    public let display: String

    /// `query`（不分大小写）在显示流中的所有命中区间（Character 偏移，互不重叠）。
    public func matches(for query: String) -> [Range<Int>] {
        guard !query.isEmpty else { return [] }
        var out: [Range<Int>] = []
        var from = display.startIndex
        var fromOffset = 0
        while let r = display.range(of: query, options: .caseInsensitive, range: from..<display.endIndex) {
            let lo = fromOffset + display.distance(from: from, to: r.lowerBound)
            let len = display.distance(from: r.lowerBound, to: r.upperBound)
            out.append(lo..<(lo + len))
            from = r.upperBound; fromOffset = lo + len
        }
        return out
    }

    /// 阅读顺序里第一个实际含命中的页：每个命中按其起始显示字符落在哪个页的哪一段（跨页命中落在起始页）。
    /// 不假定偏移单调——表格按列组分页时页与页之间、页内的偏移都不连续，只认真正包含命中起点的段。
    public func firstPage(containing query: String) -> Int? {
        let hits = matches(for: query)
        guard !hits.isEmpty else { return nil }
        var index: [(span: Range<Int>, page: Int)] = []
        for (i, page) in pages.enumerated() { for sp in page.spans where !sp.isEmpty { index.append((sp, i)) } } // 空 / 零宽占位 span 不参与
        index.sort { $0.span.lowerBound < $1.span.lowerBound }
        var best: Int?
        for m in hits {
            // 二分：最后一个 lowerBound <= 命中起点的段，且命中起点在其中
            var lo = 0, hi = index.count
            while lo < hi { let mid = (lo + hi) / 2; if index[mid].span.lowerBound <= m.lowerBound { lo = mid + 1 } else { hi = mid } }
            // 重复的表头在每个表格页都带着同一段显示区间：这些相同区间里取最早的页
            var k = lo - 1
            while k >= 0, index[k].span.contains(m.lowerBound) {
                if best == nil || index[k].page < best! { best = index[k].page }
                k -= 1
            }
        }
        return best
    }
}

public enum TranscriptReaderPaging {
    /// 每页显示字符数上限（Character）。起点沿折叠预览的 400 字对照，阅读页取 1200：一页约两三屏，由矩阵测量收口。
    public static let pageCharacters = 1200
    /// 每页 Text 叶子数上限（实际挂载的 Text：列表标记、表格单元格都算）：防止“字符少但叶子多”的页重新变成大布局。
    public static let pageLeaves = 24
    /// 代码块语言标签的显示上限（Character，超出截断加省略号）。
    public static let maxLanguageLabel = 40

    /// 按角色切页：用户（`markdown == false`）纯文本；助手按 Markdown 块语义。空文本给一页空页（阅读页总有一页）。
    public static func pages(for text: String, markdown: Bool, pageCharacters: Int = TranscriptReaderPaging.pageCharacters, pageLeaves: Int = TranscriptReaderPaging.pageLeaves) -> [ReaderPage] {
        document(for: text, markdown: markdown, pageCharacters: pageCharacters, pageLeaves: pageLeaves).pages
    }

    public static func document(for text: String, markdown: Bool, pageCharacters: Int = TranscriptReaderPaging.pageCharacters, pageLeaves: Int = TranscriptReaderPaging.pageLeaves) -> ReaderDocument {
        if !markdown {
            var offset = 0
            let pages = plainChunks(text, limit: pageCharacters).map { chunk -> ReaderPage in
                defer { offset += chunk.count }
                return ReaderPage(content: .plain(chunk, offset: offset), characters: chunk.count, leaves: 1, spans: [offset..<(offset + chunk.count)])
            }
            return ReaderDocument(pages: pages, display: text)
        }
        var flow = Flow()
        var builder = PageBuilder(limit: max(1, pageCharacters), maxLeaves: max(1, pageLeaves))
        for block in MarkdownBlock.parse(text) {
            for piece in split(flow.lower(block), limit: builder.limit, maxLeaves: builder.maxLeaves) { builder.place(piece) }
        }
        return ReaderDocument(pages: builder.finish(), display: flow.display)
    }

    /// 含 `query`（不分大小写）的第一页下标；没有命中或 query 为空返回 nil（按各页自己的显示文字，不处理跨页命中；跨页用 ReaderDocument.firstPage）。
    public static func firstPage(containing query: String, in pages: [ReaderPage]) -> Int? {
        guard !query.isEmpty else { return nil }
        for (i, page) in pages.enumerated() where page.visibleText.range(of: query, options: .caseInsensitive) != nil { return i }
        return nil
    }

    // MARK: 纯文本切页

    /// 逐字符切成不超过 limit 个 Character 的片段，所有片段拼回即原文（不丢、不重、不 trim）。
    /// 优先在换行、其次空白之后断开（只看每页末尾四分之一的窗口），都没有再在字符边界硬切；"\r\n"、emoji 组合序列是单个 Character，不会被拆开。
    static func plainChunks(_ text: String, limit: Int) -> [String] {
        let limit = max(1, limit)
        var out: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let hardEnd = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            var end = hardEnd
            if hardEnd < text.endIndex, limit >= 8 {
                let windowStart = text.index(start, offsetBy: limit * 3 / 4)
                let window = text[windowStart..<hardEnd]
                if let i = window.lastIndex(where: { $0.isNewline }) ?? window.lastIndex(where: { $0.isWhitespace }) { end = text.index(after: i) }
            }
            out.append(String(text[start..<end]))
            start = end
        }
        return out.isEmpty ? [""] : out
    }

    /// 带样式的文字按显示字符切片：同 plainChunks 的断点偏好；每片保留自己范围内的全部属性 run（strong / code / link 不丢）。
    static func attributedChunks(_ a: AttributedString, limit: Int) -> [AttributedString] {
        let limit = max(1, limit)
        let chars = a.characters
        guard chars.count > limit else { return [a] }
        var out: [AttributedString] = []
        var start = a.startIndex
        while start < a.endIndex {
            let hardEnd = chars.index(start, offsetBy: limit, limitedBy: a.endIndex) ?? a.endIndex
            var end = hardEnd
            if hardEnd < a.endIndex, limit >= 8 {
                let windowStart = chars.index(start, offsetBy: limit * 3 / 4)
                let window = chars[windowStart..<hardEnd]
                if let i = window.lastIndex(where: { $0.isNewline }) ?? window.lastIndex(where: { $0.isWhitespace }) { end = chars.index(after: i) }
            }
            out.append(AttributedString(a[start..<end]))
            start = end
        }
        return out
    }

    // MARK: 源块 → 显示块（行内解析一次，并分配全文显示流偏移）

    fileprivate struct Flow {
        var display = ""
        var count = 0

        mutating func text(_ source: String) -> ReaderText {
            let a = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
            return append(a)
        }
        /// 把一段（可能被切开的）显示文字记入显示流：同一叶子的片相邻无分隔；叶子结束时由 endLeaf 加分隔。
        mutating func append(_ a: AttributedString) -> ReaderText {
            let t = ReaderText(a, offset: count)
            display += t.plain; count += t.count
            return t
        }
        mutating func endLeaf() { display += "\n"; count += 1 }

        mutating func lower(_ b: MarkdownBlock) -> ReaderBlock {
            defer { /* 叶子分隔在各分支内按叶子结束加入 */ }
            switch b {
            case .code(let s, let lang):
                // 语言标签也是实际渲染的 Text：显示时有界（围栏信息串可以任意长）；源正文与复制不受影响。
                let shown = lang.map { $0.count > TranscriptReaderPaging.maxLanguageLabel ? String($0.prefix(TranscriptReaderPaging.maxLanguageLabel - 1)) + "…" : $0 }
                let r = ReaderBlock.code(s, lang: shown, offset: count)
                display += s; count += s.count; endLeaf(); return r
            case .heading(let l, let t): let r = text(t); endLeaf(); return .heading(level: l, r)
            case .bullets(let items): return .bullets(items.map { let r = text($0); endLeaf(); return r })
            case .numbered(let n, let items): return .numbered(start: n, items.map { let r = text($0); endLeaf(); return r })
            case .quote(let s): let r = text(s); endLeaf(); return .quote(r)
            case .table(let h, let rows):
                let header = h.map { let r = text($0); endLeaf(); return r }
                return .table(header: header, rows: rows.map { $0.map { let r = text($0); endLeaf(); return r } })
            case .paragraph(let s): let r = text(s); endLeaf(); return .paragraph(r)
            }
        }
    }

    // MARK: 预算（显示字符 + 实际 Text 叶子）

    fileprivate struct Cost { var characters = 0; var leaves = 0 }

    fileprivate static func cost(_ b: ReaderBlock) -> Cost {
        switch b {
        case .code(let s, let lang, _): return Cost(characters: s.count + (lang?.count ?? 0), leaves: 1 + (lang == nil ? 0 : 1))
        case .heading(_, let t), .quote(let t), .paragraph(let t): return Cost(characters: t.count, leaves: 1)
        // 列表每项实际挂载两个 Text：标记 + 正文
        case .bullets(let items), .numbered(_, let items): return Cost(characters: items.reduce(0) { $0 + $1.count }, leaves: items.count * 2)
        case .table(let header, let rows):
            let cells = header + rows.flatMap { $0 }
            return Cost(characters: cells.reduce(0) { $0 + $1.count }, leaves: cells.count)
        }
    }

    fileprivate static func spans(_ b: ReaderBlock) -> [Range<Int>] {
        switch b {
        case .code(let s, _, let o): return [o..<(o + s.count)]
        case .heading(_, let t), .quote(let t), .paragraph(let t): return [t.span]
        case .bullets(let items), .numbered(_, let items): return items.map(\.span)
        case .table(let header, let rows): return (header + rows.flatMap { $0 }).map(\.span)
        }
    }

    /// 一个块切成若干各自不超过预算的块（拼回即原块；显示字符与样式不变）。已在预算内的块原样返回。
    fileprivate static func split(_ b: ReaderBlock, limit: Int, maxLeaves: Int) -> [ReaderBlock] {
        let c = cost(b)
        if c.characters <= limit && c.leaves <= maxLeaves { return [b] }
        func texts(_ t: ReaderText) -> [ReaderText] {
            var offset = t.offset
            return attributedChunks(t.text, limit: limit).map { chunk in defer { offset += chunk.characters.count }; return ReaderText(chunk, offset: offset) }
        }
        switch b {
        case .paragraph(let t): return texts(t).map { .paragraph($0) }
        case .quote(let t): return texts(t).map { .quote($0) }
        case .heading(let level, let t):
            return texts(t).enumerated().map { $0.offset == 0 ? .heading(level: level, $0.element) : .paragraph($0.element) }
        case .code(let s, let lang, let offset):
            var o = offset
            // 每一片都带语言标签（标签也是 Text）：正文额度要扣掉标签
            return codeChunks(s, limit: max(1, limit - (lang?.count ?? 0))).map { chunk in defer { o += chunk.count }; return .code(chunk, lang: lang, offset: o) }
        case .bullets(let items):
            var out: [ReaderBlock] = []
            for group in groupItems(items, limit: limit, maxLeaves: maxLeaves) {
                var head: [ReaderText] = []
                for piece in group {
                    if piece.continues {
                        if !head.isEmpty { out.append(.bullets(head)); head = [] }
                        out.append(.paragraph(piece.text))
                    } else { head.append(piece.text) }
                }
                if !head.isEmpty { out.append(.bullets(head)) }
            }
            return out
        case .numbered(let start, let items):
            var out: [ReaderBlock] = []
            var number = start
            for group in groupItems(items, limit: limit, maxLeaves: maxLeaves) {
                var head: [ReaderText] = []
                var headStart = number
                for piece in group {
                    if piece.continues {
                        if !head.isEmpty { out.append(.numbered(start: headStart, head)); head = [] }
                        out.append(.paragraph(piece.text))
                    } else {
                        if head.isEmpty { headStart = number }
                        head.append(piece.text); number += 1
                    }
                }
                if !head.isEmpty { out.append(.numbered(start: headStart, head)) }
            }
            return out
        case .table(let header, let rows):
            return splitTable(header: header, rows: rows, limit: limit, maxLeaves: maxLeaves)
        }
    }

    fileprivate struct ItemPiece { let text: ReaderText; let continues: Bool }

    /// 列表项分组：每组 ≤ limit 字符且 ≤ maxLeaves 个 Text（每项两个）；超过 limit 的单项切成片段，首片仍是列表项，后续片段 continues。
    fileprivate static func groupItems(_ items: [ReaderText], limit: Int, maxLeaves: Int) -> [[ItemPiece]] {
        var groups: [[ItemPiece]] = []
        var current: [ItemPiece] = []
        var chars = 0
        var leaves = 0
        func flush() { if !current.isEmpty { groups.append(current); current = []; chars = 0; leaves = 0 } }
        for item in items {
            var offset = item.offset
            let pieces = attributedChunks(item.text, limit: limit).enumerated().map { i, chunk -> ItemPiece in
                defer { offset += chunk.characters.count }
                return ItemPiece(text: ReaderText(chunk, offset: offset), continues: i > 0)
            }
            for p in pieces {
                let l = p.continues ? 1 : 2
                if !current.isEmpty && (chars + p.text.count > limit || leaves + l > maxLeaves) { flush() }
                current.append(p); chars += p.text.count; leaves += l
            }
        }
        flush()
        return groups
    }

    /// 代码按行切；单行超过 limit 再在行内切。非末片以 "\n" 结尾（拼回即原代码）。
    fileprivate static func codeChunks(_ code: String, limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        var count = 0
        func flush() { if !current.isEmpty { out.append(current); current = ""; count = 0 } }
        var lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for i in lines.indices where i < lines.count - 1 { lines[i] += "\n" }
        for line in lines {
            let n = line.count
            if n > limit {
                flush()
                let parts = plainChunks(line, limit: limit)
                out.append(contentsOf: parts.dropLast())
                current = parts.last ?? ""; count = current.count
                continue
            }
            if count + n > limit { flush() }
            current += line; count += n
        }
        flush()
        return out.isEmpty ? [""] : out
    }

    /// 表格切页，预算同时约束表头与行：
    /// - 列数过多时按列分组（每组表头 + 至少一行不超叶子上限），每个分片都带着自己那些列的表头，列归属不变；
    /// - 超长表头单元格先分片：前面的分片各占一页（只有表头、没有行），最后一片与行同页；
    /// - 表头字符不超过页预算的一半，行预算 = 页预算 − 表头；单元格超长时按列切成后续行（其它列留空）。
    fileprivate static func splitTable(header: [ReaderText], rows: [[ReaderText]], limit: Int, maxLeaves: Int) -> [ReaderBlock] {
        let colsPerGroup = max(1, maxLeaves / 2)
        var out: [ReaderBlock] = []
        var start = 0
        repeat {
            let end = min(header.count, start + colsPerGroup)
            let cols = Array(start..<max(end, start + 1)).filter { $0 < header.count }
            out.append(contentsOf: splitTableColumns(header: cols.map { header[$0] }, rows: rows.map { r in cols.map { $0 < r.count ? r[$0] : ReaderText(AttributedString(""), offset: 0) } }, limit: limit, maxLeaves: maxLeaves))
            start = end
        } while start < header.count
        return out
    }

    private static func splitTableColumns(header: [ReaderText], rows: [[ReaderText]], limit: Int, maxLeaves: Int) -> [ReaderBlock] {
        let cols = max(1, header.count)
        // 表头单元格上限：整行表头不超过页预算的一半
        let headerCell = max(1, limit / 2 / cols)
        var headerChunks: [[ReaderText]] = header.map { h in
            var o = h.offset
            return attributedChunks(h.text, limit: headerCell).map { c in defer { o += c.characters.count }; return ReaderText(c, offset: o) }
        }
        let depth = headerChunks.map(\.count).max() ?? 1
        for i in headerChunks.indices { while headerChunks[i].count < depth { headerChunks[i].append(ReaderText(AttributedString(""), offset: header[i].offset + header[i].count)) } }
        var out: [ReaderBlock] = []
        for k in 0..<(depth - 1) { out.append(.table(header: headerChunks.map { $0[k] }, rows: [])) }
        let finalHeader = headerChunks.map { $0[depth - 1] }
        let headerCost = finalHeader.reduce(0) { $0 + $1.count }
        let rowBudget = max(cols, limit - headerCost)
        let cellLimit = max(1, rowBudget / cols)
        // 行叶子预算：页内表头也占叶子
        let rowLeafBudget = max(cols, maxLeaves - cols)
        var expanded: [[ReaderText]] = []
        for row in rows {
            let chunks = row.map { cell -> [ReaderText] in
                var o = cell.offset
                return attributedChunks(cell.text, limit: cellLimit).map { c in defer { o += c.characters.count }; return ReaderText(c, offset: o) }
            }
            let d = chunks.map(\.count).max() ?? 1
            for k in 0..<d { expanded.append(chunks.map { k < $0.count ? $0[k] : ReaderText(AttributedString(""), offset: 0) }) }
        }
        var group: [[ReaderText]] = []
        var chars = headerCost
        for row in expanded {
            let rc = row.reduce(0) { $0 + $1.count }
            if !group.isEmpty && (chars + rc > limit || (group.count + 1) * cols > rowLeafBudget) {
                out.append(.table(header: finalHeader, rows: group)); group = []; chars = headerCost
            }
            group.append(row); chars += rc
        }
        if !group.isEmpty || rows.isEmpty { out.append(.table(header: finalHeader, rows: group)) }
        return out
    }

    fileprivate struct PageBuilder {
        let limit: Int
        let maxLeaves: Int
        private var pages: [ReaderPage] = []
        private var blocks: [ReaderBlock] = []
        private var cost = Cost()

        init(limit: Int, maxLeaves: Int) { self.limit = limit; self.maxLeaves = maxLeaves }

        private mutating func flush() {
            guard !blocks.isEmpty else { return }
            pages.append(ReaderPage(content: .markdown(blocks), characters: cost.characters, leaves: cost.leaves, spans: blocks.flatMap(TranscriptReaderPaging.spans).filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }))
            blocks = []; cost = Cost()
        }

        /// 贪心装页；任何块（含迁移的标题）加入前都核对剩余预算，末次放置也不例外。
        /// 页尾的标题不孤立：有前文时带到下一页；无论是带过去的还是文首 / 新页上的单独标题，下一块放不下时都按“扣掉标题后的剩余额度”
        /// 再切一次，让它的第一片与标题同页（1200 字 / 24 叶硬上限不放宽；标题本身占满页的极端预算才单独成页）。
        mutating func place(_ b: ReaderBlock) {
            let c = TranscriptReaderPaging.cost(b)
            if !blocks.isEmpty && (cost.characters + c.characters > limit || cost.leaves + c.leaves > maxLeaves) {
                guard case .heading? = blocks.last else { flush(); blocks.append(b); cost.characters += c.characters; cost.leaves += c.leaves; return }
                if blocks.count > 1 {
                    let carried = blocks.removeLast()
                    cost = recompute()
                    flush()
                    blocks = [carried]; cost = TranscriptReaderPaging.cost(carried)
                }
                if cost.characters + c.characters > limit || cost.leaves + c.leaves > maxLeaves {
                    let room = limit - cost.characters, leafRoom = maxLeaves - cost.leaves
                    if room >= 8, leafRoom >= 2 {
                        let pieces = TranscriptReaderPaging.split(b, limit: room, maxLeaves: leafRoom)
                        if pieces.count > 1 || TranscriptReaderPaging.cost(pieces[0]).characters <= room {
                            for piece in pieces { place(piece) }
                            return
                        }
                    }
                    flush()
                }
            }
            blocks.append(b)
            cost.characters += c.characters; cost.leaves += c.leaves
        }

        private func recompute() -> Cost {
            var c = Cost()
            for b in blocks { let x = TranscriptReaderPaging.cost(b); c.characters += x.characters; c.leaves += x.leaves }
            return c
        }

        mutating func finish() -> [ReaderPage] {
            flush()
            return pages.isEmpty ? [ReaderPage(content: .markdown([]), characters: 0, leaves: 0, spans: [])] : pages
        }
    }
}

extension ReaderPage {
    /// 本页可见文字（不含 Markdown 语法字符）。
    public var visibleText: String {
        switch content {
        case .plain(let s, _): return s
        case .markdown(let blocks):
            return blocks.map { b -> String in
                switch b {
                case .code(let s, _, _): return s
                case .heading(_, let t), .quote(let t), .paragraph(let t): return t.plain
                case .bullets(let items), .numbered(_, let items): return items.map(\.plain).joined(separator: "\n")
                case .table(let header, let rows): return ([header] + rows).map { $0.map(\.plain).joined(separator: " ") }.joined(separator: "\n")
                }
            }.joined(separator: "\n")
        }
    }
}
