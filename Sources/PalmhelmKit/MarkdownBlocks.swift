import Foundation

/// 回执正文的块级 Markdown 切分：围栏代码块、标题、列表、引用、表格、段落。各端只负责把块画出来；行内语法交给系统 AttributedString(markdown:)。
/// 不追求完整 CommonMark：表格只认左右都带管道、有分隔行的写法；嵌套列表按段落原样显示。
/// 带源范围的块（内部）：range 是 UTF-8 字节偏移。
struct MarkdownSourceBlock: Equatable, Sendable {
    var block: MarkdownBlock
    var utf8Range: Range<Int>
}

public enum MarkdownBlock: Equatable, Sendable {
    case code(String, lang: String?)
    case heading(level: Int, text: String)
    case bullets([String])
    /// 有序列表：start 为首条的编号（被段落隔开的后段从自己的编号开始，如 2.）；渲染时按 start + 序号显示。
    case numbered(start: Int, items: [String])
    case quote(String)
    /// 表格：header 与每行都已对齐到同一列数（缺列补空、多列截断）；单元格文本未做行内解析。
    case table(header: [String], rows: [[String]])
    case paragraph(String)

    public static func parse(_ text: String) -> [MarkdownBlock] { parseRanged(text).map(\.block) }

    /// 同一次解析同时给出每块在源文里的 UTF-8 范围（打字效果片 2 按它选“全新块”）；`parse` 就是它的块投影，没有第二份分类算法。
    /// 范围覆盖块消费的源行（含标记、围栏、分隔行，结尾换行计入所属行）；块按源顺序、互不重叠，都在 0...text.utf8.count 内。
    static func parseRanged(_ text: String) -> [MarkdownSourceBlock] {
        var out: [MarkdownSourceBlock] = []
        var para: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var numberedStart = 1
        var quote: [String] = []
        var code: [String]? = nil
        var lang: String? = nil
        var accStart = 0   // 当前累积块的首行
        var codeStart = 0  // 当前围栏的开栏行
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var starts: [Int] = []
        var pos = 0
        for l in lines { starts.append(pos); pos += l.utf8.count + 1 }
        let total = text.utf8.count
        /// 源行 [a, b) 的字节范围。
        func range(_ a: Int, _ b: Int) -> Range<Int> { min(starts[a], total) ..< (b < lines.count ? min(starts[b], total) : total) }
        func flush(_ upTo: Int) {
            let r = range(accStart, upTo)
            if !para.isEmpty { out.append(.init(block: .paragraph(para.joined(separator: "\n")), utf8Range: r)); para = [] }
            if !bullets.isEmpty { out.append(.init(block: .bullets(bullets), utf8Range: r)); bullets = [] }
            if !numbered.isEmpty { out.append(.init(block: .numbered(start: numberedStart, items: numbered), utf8Range: r)); numbered = [] }
            if !quote.isEmpty { out.append(.init(block: .quote(quote.joined(separator: "\n")), utf8Range: r)); quote = [] }
        }
        func mark(_ idx: Int) { if para.isEmpty && bullets.isEmpty && numbered.isEmpty && quote.isEmpty { accStart = idx } }
        var i = 0
        while i < lines.count {
            let idx = i
            let line = lines[idx]
            i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let c = code {
                if trimmed.hasPrefix("```") { out.append(.init(block: .code(c.joined(separator: "\n"), lang: lang), utf8Range: range(codeStart, idx + 1))); code = nil; lang = nil }
                else { code!.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush(idx)
                let l = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                lang = l.isEmpty ? nil : l
                code = []
                codeStart = idx
                continue
            }
            if trimmed.isEmpty { flush(idx); continue }
            if trimmed.hasPrefix("|"), let t = table(lines, at: idx) {
                flush(idx); out.append(.init(block: t.block, utf8Range: range(idx, t.next))); i = t.next; continue
            }
            if let h = heading(trimmed) { flush(idx); out.append(.init(block: .heading(level: h.0, text: h.1), utf8Range: range(idx, idx + 1))); continue }
            if let b = bullet(trimmed) { if !para.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush(idx) }; mark(idx); bullets.append(b); continue }
            if let n = number(trimmed) {
                if !para.isEmpty || !bullets.isEmpty || !quote.isEmpty { flush(idx) }
                mark(idx)
                if numbered.isEmpty { numberedStart = n.start }
                numbered.append(n.text); continue
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" { if !para.isEmpty || !bullets.isEmpty || !numbered.isEmpty { flush(idx) }; mark(idx); quote.append(String(trimmed.dropFirst(trimmed == ">" ? 1 : 2))); continue }
            if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush(idx) }
            mark(idx)
            para.append(line)
        }
        if let c = code { out.append(.init(block: .code(c.joined(separator: "\n"), lang: lang), utf8Range: range(codeStart, lines.count))) } // 未闭合的围栏按代码块处理
        flush(lines.count)
        return out
    }

    private static func heading(_ s: String) -> (Int, String)? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(s.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }
    private static func bullet(_ s: String) -> String? {
        for m in ["- ", "* ", "• ", "+ "] where s.hasPrefix(m) { return String(s.dropFirst(m.count)) }
        return nil
    }
    private static func number(_ s: String) -> (start: Int, text: String)? {
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, s.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (Int(digits) ?? 1, String(s.dropFirst(digits.count + 2)))
    }

    /// 从 `start` 行起的表格：表头行 + 分隔行（列数须与表头相等）+ 连续以 `|` 开头的数据行。
    /// 分隔行不成立时返回 nil，由调用方按段落处理。
    private static func table(_ lines: [String], at start: Int) -> (block: MarkdownBlock, next: Int)? {
        guard start + 1 < lines.count, hasOuterPipes(lines[start]) else { return nil }
        let header = cells(lines[start])
        let sepLine = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard hasOuterPipes(sepLine) else { return nil }
        let sep = cells(sepLine)
        guard sep.count == header.count, sep.allSatisfy(isAlignCell) else { return nil }
        var rows: [[String]] = []
        var j = start + 2
        // 缺右侧管道的行不属于表格：表格在此结束，该行按普通文本处理
        while j < lines.count, hasOuterPipes(lines[j]) {
            let r = cells(lines[j])
            rows.append((0..<header.count).map { $0 < r.count ? r[$0] : "" })
            j += 1
        }
        return (.table(header: header, rows: rows), j)
    }

    /// 左右都有未转义的 `|`（表头、分隔行与数据行都要求）。
    private static func hasOuterPipes(_ line: String) -> Bool {
        let t = Array(line.trimmingCharacters(in: .whitespaces))
        guard t.count >= 2, t.first == "|", t.last == "|" else { return false }
        return t[t.count - 2] != "\\"
    }

    /// 分隔行的单元格：`-` 至少一个，可带首尾 `:` 表示对齐。
    private static func isAlignCell(_ s: String) -> Bool {
        let core = s.hasPrefix(":") ? s.dropFirst() : Substring(s)
        let body = core.hasSuffix(":") ? core.dropLast() : core
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    /// 切分一行表格的单元格：去掉外侧管道，`\|` 为字面竖线，单元格 trim。
    private static func cells(_ line: String) -> [String] {
        var t = Array(line.trimmingCharacters(in: .whitespaces))
        if t.first == "|" { t.removeFirst() }
        if t.last == "|", t.count < 2 || t[t.count - 2] != "\\" { t.removeLast() }
        var out: [String] = []
        var cur = ""
        var k = 0
        while k < t.count {
            if t[k] == "\\", k + 1 < t.count, t[k + 1] == "|" { cur.append("|"); k += 2; continue }
            if t[k] == "|" { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; k += 1; continue }
            cur.append(t[k])
            k += 1
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }
}
