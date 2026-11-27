import Foundation

/// 一段 Markdown 的准备结果：块切分与行内解析（含搜索高亮）一次做完，视图只负责画。
/// 同一个 PalmhelmMarkdownText 的重复 body 求值经 `PreparedMarkdownMemo` 复用它；不缓存高度、宽度或字号。
struct PreparedMarkdown {
    enum Block {
        case code(AttributedString, lang: String?)
        case heading(level: Int, AttributedString)
        case bullets([AttributedString])
        case numbered(start: Int, [AttributedString])
        case quote(AttributedString)
        case table(header: [AttributedString], rows: [[AttributedString]], alignments: [MarkdownTableAlignment])
        case rule
        case paragraph(AttributedString)
    }

    let blocks: [Block]
    /// 与 blocks 同序的源范围（UTF-8）；阅读页等没有 transcript 源文的构造为 nil，不可做块淡入。
    let ranges: [Range<Int>?]

    init(text: String, highlight: String?) {
        self.init(source: MarkdownDiagnostics.measure(block: true) { MarkdownBlock.parseRanged(text) }, highlight: highlight)
    }

    init(source: [MarkdownSourceBlock], highlight: String?) {
        self.init(blocks: source.map(\.block), ranges: source.map { Optional($0.utf8Range) }, alignments: source.map(\.alignments), highlight: highlight)
    }

    /// 源块：行内解析与高亮。
    init(blocks source: [MarkdownBlock], ranges: [Range<Int>?]? = nil, alignments: [[MarkdownTableAlignment]] = [], highlight: String?) {
        self.ranges = ranges ?? Array(repeating: nil, count: source.count)
        func inline(_ s: String) -> AttributedString {
            MarkdownDiagnostics.measure(block: false) {
                SearchText.marking((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s), query: highlight)
            }
        }
        blocks = source.enumerated().map { idx, b in
            switch b {
            case .code(let s, let lang): .code(AttributedString(s), lang: lang)
            case .heading(let level, let t): .heading(level: level, inline(t))
            case .bullets(let items): .bullets(items.map(inline))
            case .numbered(let start, let items): .numbered(start: start, items.map(inline))
            case .quote(let s): .quote(inline(s))
            case .table(let header, let rows):
                .table(header: header.map(inline), rows: rows.map { $0.map(inline) }, alignments: idx < alignments.count ? alignments[idx] : Array(repeating: .unspecified, count: header.count))
            case .rule: .rule
            case .paragraph(let s): .paragraph(inline(s))
            }
        }
    }

    /// 已切好的块（阅读页的一页）：行内样式已在切页时解析并随片保留，这里只按全文显示流的命中区间做高亮。
    init(readerBlocks source: [ReaderBlock], matches: [Range<Int>]) {
        func mark(_ t: ReaderText) -> AttributedString { SearchText.marking(t.text, offset: t.offset, matches: matches) }
        ranges = Array(repeating: nil, count: source.count)
        blocks = source.map { b in
            switch b {
            case .code(let s, let lang, let offset): .code(SearchText.marking(s, offset: offset, matches: matches), lang: lang) // 代码页同样按命中区间高亮（等宽、可选择不变）
            case .heading(let level, let t): .heading(level: level, mark(t))
            case .bullets(let items): .bullets(items.map(mark))
            case .numbered(let start, let items): .numbered(start: start, items.map(mark))
            case .quote(let t): .quote(mark(t))
            case .table(let header, let rows): .table(header: header.map(mark), rows: rows.map { $0.map(mark) }, alignments: header.map(\.alignment))
            case .rule: .rule
            case .paragraph(let t): .paragraph(mark(t))
            }
        }
    }
}

/// 一次准备的只读句柄（A1-002 §3）：App 末行叶子按 scope/text/highlight 复用同一份，字符与块两种模式共用，避免每批解析两次。
/// 不公开内部 Block 枚举，不持有动画状态或 Session。
public struct MarkdownRenderSnapshot {
    let prepared: PreparedMarkdown
    public let text: String
    public let highlight: String?
    /// 每个顶层块在源文里的 UTF-8 范围，与渲染块同序。
    public var sourceRanges: [Range<Int>?] { prepared.ranges }
    /// 源文恰是一个无行内格式 / 链接的普通段落时，它的行内解析结果（同一份解析，不再二次 AttributedString(markdown:)）。
    public let plainParagraph: AttributedString?

    public static func prepare(text: String, highlight: String? = nil) -> MarkdownRenderSnapshot {
        let source = MarkdownDiagnostics.measure(block: true) { MarkdownBlock.parseRanged(text) }
        let prepared = PreparedMarkdown(source: source, highlight: highlight)
        var plain: AttributedString?
        if source.count == 1, case .paragraph(let s) = source[0].block, s == text, case .paragraph(let a)? = prepared.blocks.first,
           String(a.characters) == text, a.runs.allSatisfy({ $0.inlinePresentationIntent == nil && $0.link == nil }) {
            plain = a
        }
        return MarkdownRenderSnapshot(prepared: prepared, text: text, highlight: highlight, plainParagraph: plain)
    }
}

/// 视图生命周期内的最后一次准备结果：相同 text/highlight 直接复用，任一变化即重做。
/// 引用语义、不被观察：在 body 里读写它不会触发失效。超过留存上限的超大展开文本不驻留解析副本（只复用到下一次变化前也不保留），
/// 让它不绕过会话 / 展开的内存上限；那种文本本来就是少见的展开压力形态。
final class PreparedMarkdownMemo {
    /// 留存上限（UTF-8 字节）：与首页 4000 UTF-16 / 8192 字节预算同量级的 32 倍，覆盖正常展开。
    static let retainLimitUTF8 = 256 * 1024
    private var text: String?
    private var highlight: String?
    private var value: PreparedMarkdown?

    /// 阅读页：同一页块与高亮重复求值时复用（一页至多约 1200 字，仍按块相等判断，不驻留超限内容）。
    private var pageBlocks: [ReaderBlock]?
    private var pageMatches: [Range<Int>]?
    private var pageValue: PreparedMarkdown?
    func prepared(readerBlocks blocks: [ReaderBlock], matches: [Range<Int>]) -> PreparedMarkdown {
        if let pageValue, pageBlocks == blocks, pageMatches == matches { return pageValue }
        let fresh = PreparedMarkdown(readerBlocks: blocks, matches: matches)
        pageBlocks = blocks; pageMatches = matches; pageValue = fresh
        return fresh
    }

    func prepared(_ text: String, highlight: String?) -> PreparedMarkdown {
        if let value, self.text == text, self.highlight == highlight { return value }
        let fresh = PreparedMarkdown(text: text, highlight: highlight)
        if text.utf8.count <= Self.retainLimitUTF8 {
            self.text = text; self.highlight = highlight; value = fresh
        } else {
            self.text = nil; self.highlight = nil; value = nil
        }
        return fresh
    }
}
