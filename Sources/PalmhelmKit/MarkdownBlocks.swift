import Foundation

/// 回执正文的块级 Markdown 切分：围栏代码块、标题、列表、引用、表格、分隔线、段落。各端只负责把块画出来；行内语法交给系统 AttributedString(markdown:)。
/// 不追求完整 CommonMark：表格只认 GFM 的主要写法（见 `table`），且数据行必须带未转义管道（保守边界）；嵌套列表按段落原样显示。
/// 带源范围的块（内部）：range 是 UTF-8 字节偏移；alignments 只对表格块有意义，与表头同序。
struct MarkdownSourceBlock: Equatable, Sendable {
    var block: MarkdownBlock
    var utf8Range: Range<Int>
    var alignments: [MarkdownTableAlignment] = []
}

/// 表格列的对齐（来自分隔行的冒号）。`unspecified` 为无冒号。
enum MarkdownTableAlignment: Equatable, Sendable {
    case unspecified, left, center, right
}

public enum MarkdownBlock: Equatable, Sendable {
    case code(String, lang: String?)
    case heading(level: Int, text: String)
    case bullets([String])
    /// 有序列表：start 为首条的编号（被段落隔开的后段从自己的编号开始，如 2.）；渲染时按 start + 序号显示。
    case numbered(start: Int, items: [String])
    case quote(String)
    /// 表格：header 与每行都已对齐到同一列数（缺列补空）；单元格文本未做行内解析。
    case table(header: [String], rows: [[String]])
    /// 顶层独立的分隔线（`---`、`***`、`___`）。
    case rule
    case paragraph(String)

    public static func parse(_ text: String) -> [MarkdownBlock] { parseRanged(text).map(\.block) }

    /// 同一次解析同时给出每块在源文里的 UTF-8 范围（打字效果片 2 按它选“全新块”）；`parse` 就是它的块投影，没有第二份分类算法。
    /// 范围覆盖块消费的源行（含标记、围栏、分隔行，结尾换行计入所属行）；块按源顺序、互不重叠，都在 0...text.utf8.count 内。
    /// 行以 LF、CRLF、CR 切分；CRLF 是一个换行。
    static func parseRanged(_ text: String) -> [MarkdownSourceBlock] {
        var out: [MarkdownSourceBlock] = []
        var para: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var numberedStart = 1
        var quote: [String] = []
        var code: [String]? = nil
        var lang: String? = nil
        var fence: (char: Character, len: Int)? = nil
        var accStart = 0   // 当前累积块的首行
        var codeStart = 0  // 当前围栏的开栏行
        let (lines, starts) = splitLines(text)
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
                if let f = fence, indentColumns(line) < 4, closes(trimmed, f) { out.append(.init(block: .code(c.joined(separator: "\n"), lang: lang), utf8Range: range(codeStart, idx + 1))); code = nil; lang = nil; fence = nil }
                else { code!.append(line) }
                continue
            }
            if indentColumns(line) < 4, let f = fenceOpen(trimmed) {
                flush(idx)
                lang = f.lang
                fence = (f.char, f.len)
                code = []
                codeStart = idx
                continue
            }
            if trimmed.isEmpty { flush(idx); continue }
            if !isIndented(line), !startsBlock(trimmed), let t = table(lines, at: idx) {
                flush(idx); out.append(.init(block: t.block, utf8Range: range(idx, t.next), alignments: t.alignments)); i = t.next; continue
            }
            // 分隔线只在文档开头或空行之后识别（三种字符一律适用）；段落下的 `---` 是 setext 下划线，保持原有行为。
            let afterBlank = idx == 0 || lines[idx - 1].trimmingCharacters(in: .whitespaces).isEmpty
            if !isIndented(line), isRule(trimmed), afterBlank {
                flush(idx); out.append(.init(block: .rule, utf8Range: range(idx, idx + 1))); continue
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
        if let c = code { out.append(.init(block: .code(c.joined(separator: "\n"), lang: lang), utf8Range: range(codeStart, lines.count))) } // 未闭合的围栏读到段尾
        flush(lines.count)
        return out
    }

    /// 按 LF、CRLF、CR 切行，并给出每行起始的 UTF-8 偏移（末行即使为空也保留）。
    private static func splitLines(_ text: String) -> (lines: [String], starts: [Int]) {
        let bytes = Array(text.utf8)
        var lines: [String] = []
        var starts: [Int] = []
        var cur: [UInt8] = []
        var lineStart = 0
        var k = 0
        while k < bytes.count {
            let b = bytes[k]
            if b == 0x0A || b == 0x0D {
                lines.append(String(decoding: cur, as: UTF8.self)); starts.append(lineStart)
                cur.removeAll(keepingCapacity: true)
                if b == 0x0D, k + 1 < bytes.count, bytes[k + 1] == 0x0A { k += 1 }
                k += 1
                lineStart = k
            } else {
                cur.append(b); k += 1
            }
        }
        lines.append(String(decoding: cur, as: UTF8.self)); starts.append(lineStart)
        return (lines, starts)
    }

    /// 围栏开栏：三个以上的反引号或波浪号；返回字符、长度与信息串（语言）。
    private static func fenceOpen(_ s: String) -> (char: Character, len: Int, lang: String?)? {
        guard let c = s.first, c == "`" || c == "~" else { return nil }
        let run = s.prefix { $0 == c }.count
        guard run >= 3 else { return nil }
        let info = String(s.dropFirst(run)).trimmingCharacters(in: .whitespaces)
        return (c, run, info.isEmpty ? nil : info)
    }

    /// 围栏闭栏：同字符、长度不短于开栏，且除空白外没有其它内容。
    private static func closes(_ s: String, _ f: (char: Character, len: Int)) -> Bool {
        let run = s.prefix { $0 == f.char }.count
        return run >= f.len && s.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// 行首缩进的列数：空格各占一列，Tab 展开到下一个 4 列制表位。
    private static func indentColumns(_ line: String) -> Int {
        var col = 0
        for ch in line {
            if ch == " " { col += 1 } else if ch == "\t" { col = (col / 4 + 1) * 4 } else { break }
        }
        return col
    }

    /// 顶层标准缩进代码（缩进 4 列及以上）：不识别为表格、分隔线或围栏。
    private static func isIndented(_ line: String) -> Bool { indentColumns(line) >= 4 }

    /// 分隔线：去掉空格后至少三个同字符（`-`、`*`、`_`）。
    private static func isRule(_ s: String) -> Bool {
        let chars = s.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let f = chars.first, f == "-" || f == "*" || f == "_" else { return false }
        return chars.allSatisfy { $0 == f }
    }

    /// 能打断表格或段落、开始其它块的行（标题、列表、引用、围栏、分隔线）。
    private static func startsBlock(_ t: String) -> Bool {
        t.hasPrefix("```") || t.hasPrefix("~~~") || heading(t) != nil || bullet(t) != nil || number(t) != nil || t.hasPrefix(">") || isRule(t)
    }

    /// 表格（GFM 写法）：表头行与分隔行的列数须相等，分隔单元格为 `-+`、`:-+`、`-+:`、`:-+:`；表头与分隔行都须带未转义管道；唯一例外是单列表头配冒号分隔行（如 `:-:`），分隔行可以不带管道。
    /// 数据行须带未转义管道，遇到空行、新块、缩进行、列数多于表头的行时表格结束（该行按原文显示）；缺格补空。
    /// 表头与分隔行列数不符、或没有分隔行时，整段保持原文。
    private static func table(_ lines: [String], at start: Int) -> (block: MarkdownBlock, alignments: [MarkdownTableAlignment], next: Int)? {
        guard start + 1 < lines.count else { return nil }
        let head = scanRow(lines[start])
        guard head.pipes >= 1, !head.cells.isEmpty else { return nil }
        let sepLine = lines[start + 1]
        guard !isIndented(sepLine) else { return nil }
        let sep = scanRow(sepLine)
        // 分隔行：带管道时列数须相等；不带管道时只接受“表头一列 + 带冒号的一格”（如 `:---:`），其余仍按原文（保护 setext 与横线）。
        let sepOK: Bool
        if sep.pipes >= 1 {
            sepOK = sep.cells.count == head.cells.count && sep.cells.allSatisfy(isAlignCell)
        } else {
            sepOK = head.cells.count == 1 && sep.cells.count == 1 && isAlignCell(sep.cells[0]) && sep.cells[0].contains(":")
        }
        guard sepOK else { return nil }
        var rows: [[String]] = []
        var j = start + 2
        // 补格上限：补出的单元格不超过 min(4096, 4 × 已出现的实际单元格)；超过即结束表格，后续源行按段落显示。
        var padded = 0
        var actual = head.cells.count
        while j < lines.count {
            let line = lines[j]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || isIndented(line) || startsBlock(t) { break }
            let r = scanRow(line)
            if r.pipes < 1 || r.cells.count > head.cells.count { break }
            let pad = head.cells.count - r.cells.count
            if padded + pad > min(4096, 4 * (actual + r.cells.count)) { break }
            padded += pad
            actual += r.cells.count
            rows.append((0..<head.cells.count).map { $0 < r.cells.count ? r.cells[$0] : "" })
            j += 1
        }
        return (.table(header: head.cells, rows: rows), sep.cells.map(alignment), j)
    }

    /// 一行的扫描结果：单元格（去掉外侧管道与转义管道的反斜杠，trim）与未转义管道数。
    /// 奇数个连续反斜杠后的 `|` 是字面量（只去掉其中一个反斜杠）；偶数个后的 `|` 分列。
    private static func scanRow(_ line: String) -> (cells: [String], pipes: Int) {
        let t = Array(line.trimmingCharacters(in: .whitespaces).unicodeScalars)
        var cells: [String] = []
        var cur = String.UnicodeScalarView()
        var run = 0
        var pipes = 0
        var lastCut = -1
        for (k, s) in t.enumerated() {
            if s == "\\" { cur.append(s); run += 1; continue }
            if s == "|" {
                if run % 2 == 1 {
                    cur.removeLast()   // 去掉转义用的那个反斜杠，管道作为字面量保留
                    cur.append(s)
                } else {
                    pipes += 1
                    lastCut = k
                    if k > 0 { cells.append(String(cur).trimmingCharacters(in: .whitespaces)) }   // 行首管道不产生空单元格
                    cur = String.UnicodeScalarView()
                }
                run = 0
                continue
            }
            cur.append(s)
            run = 0
        }
        if lastCut != t.count - 1 { cells.append(String(cur).trimmingCharacters(in: .whitespaces)) }   // 行尾管道不产生空单元格
        return (cells, pipes)
    }

    /// 分隔单元格：可选的首 `:`、至少一个 `-`、可选的尾 `:`。
    private static func isAlignCell(_ s: String) -> Bool {
        let core = s.hasPrefix(":") ? s.dropFirst() : Substring(s)
        let body = core.hasSuffix(":") ? core.dropLast() : core
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    private static func alignment(_ s: String) -> MarkdownTableAlignment {
        let left = s.hasPrefix(":"), right = s.hasSuffix(":")
        switch (left, right) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        default: return .unspecified
        }
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
}
