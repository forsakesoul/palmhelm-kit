#if canImport(SwiftUI)
import SwiftUI

/// 块级 Markdown 视图（两端共用）：块由 MarkdownBlock 切分，行内语法交给系统 AttributedString(markdown:)。
/// 只渲染文字，不加载任何远程资源（计划正文里的图片/链接已由 Bridge 降级为纯文本）。
/// `highlight` 给出时，段落/列表/引用/标题/表格单元格里的命中词（不分大小写）加底色；代码块不高亮；只改样式，不改文字。
public struct PalmhelmMarkdownText: View {
    let text: String
    let codeBackground: Color
    let highlight: String?
    /// App 末行叶子给的已准备句柄：直接消费，不再解析（A1-002 §3）。nil = 走下面的 text 入口与内部 memo。
    let snapshot: MarkdownRenderSnapshot?
    /// 新块淡入请求；默认 nil（Mac 与所有旧调用点不变）。只在 snapshot 入口生效。
    let blockReveal: MarkdownBlockReveal?
    /// 解析结果的生命周期 memo：body 重复求值时相同 text/highlight 不重做块切分与行内解析。
    @State private var memo = PreparedMarkdownMemo()

    public init(text: String, codeBackground: Color = Color.secondary.opacity(0.12), highlight: String? = nil) {
        self.text = text
        self.codeBackground = codeBackground
        self.highlight = highlight
        self.snapshot = nil
        self.blockReveal = nil
    }

    /// 已准备句柄入口：每批只准备一次由调用方保证；`blockReveal` 非 nil 时按其排期淡入全新块，其余原样。
    public init(snapshot: MarkdownRenderSnapshot, codeBackground: Color = Color.secondary.opacity(0.12), blockReveal: MarkdownBlockReveal? = nil) {
        self.text = snapshot.text
        self.codeBackground = codeBackground
        self.highlight = snapshot.highlight
        self.snapshot = snapshot
        self.blockReveal = blockReveal
    }

    public var body: some View {
        if let snapshot {
            let schedule = blockReveal.flatMap { MarkdownBlockSchedule(ranges: snapshot.sourceRanges, utf8Count: snapshot.text.utf8.count, reveal: $0) }
            PreparedBlocksView(blocks: snapshot.prepared.blocks, codeBackground: codeBackground, revealable: true, schedule: schedule)
        } else {
            PreparedBlocksView(blocks: memo.prepared(text, highlight: highlight).blocks, codeBackground: codeBackground)
        }
    }
}

/// 阅读页的一页（D2）：渲染已切好的块（`TranscriptReaderPaging`），样式与 `PalmhelmMarkdownText` 完全相同；每页独立可选择。
/// 被切开的代码块的非末片以换行结尾（拼回即原文），这里显示时去掉这一个收尾换行，避免页内多出空行。
public struct PalmhelmMarkdownPageText: View {
    let blocks: [ReaderBlock]
    let codeBackground: Color
    let matches: [Range<Int>]
    @State private var memo = PreparedMarkdownMemo()

    public init(blocks: [ReaderBlock], codeBackground: Color = Color.secondary.opacity(0.12), matches: [Range<Int>] = []) {
        self.blocks = blocks
        self.codeBackground = codeBackground
        self.matches = matches
    }

    public var body: some View {
        PreparedBlocksView(blocks: memo.prepared(readerBlocks: blocks, matches: matches).blocks, codeBackground: codeBackground, trimsCodeTail: true)
    }
}

struct PreparedBlocksView: View {
    /// 表格单元格的适读宽度（pt）：超过则换行，整表仍横向滚动；防止连续长 URL 或长说明撑出很宽的一列。
    let blocks: [PreparedMarkdown.Block]
    let codeBackground: Color
    var trimsCodeTail = false
    /// 块淡入入口（snapshot 重载）为真时每块都带淡入修饰（无排期 = 恒 1），视图身份在生命周期内不变；其余调用点不带它。
    var revealable = false
    var schedule: MarkdownBlockSchedule?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                if revealable { block(b).modifier(BlockRevealFade(slot: schedule?.slot(for: i))) } else { block(b) }
            }
        }
    }

    /// 被切开的代码片以换行结尾：显示时去掉这一个收尾换行（高亮等属性随字符保留）。
    private static func trimmingTail(_ a: AttributedString) -> AttributedString {
        guard let last = a.characters.last, last == "\n" else { return a }
        return AttributedString(a[a.startIndex..<a.characters.index(before: a.endIndex)])
    }

    @ViewBuilder private func block(_ b: PreparedMarkdown.Block) -> some View {
        switch b {
        case .code(let s, let lang):
            VStack(alignment: .leading, spacing: 2) {
                if let lang { Text(lang).font(.caption2).foregroundStyle(.secondary) }
                Text(trimsCodeTail ? Self.trimmingTail(s) : s).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(codeBackground, in: RoundedRectangle(cornerRadius: 6))
        case .heading(let level, let t):
            Text(t).font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold)).textSelection(.enabled)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 2) { ForEach(Array(items.enumerated()), id: \.offset) { _, it in HStack(alignment: .top, spacing: 6) { Text("•"); Text(it).textSelection(.enabled) } } }
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 2) { ForEach(Array(items.enumerated()), id: \.offset) { i, it in HStack(alignment: .top, spacing: 6) { Text("\(start + i).").font(.system(.body, design: .monospaced)); Text(it).textSelection(.enabled) } } }
        case .quote(let s):
            HStack(spacing: 8) { RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.5)).frame(width: 3); Text(s).foregroundStyle(.secondary).textSelection(.enabled) }
        case .table(let header, let rows, let alignments):
            // 宽表横向滚动而不是挤压列宽：列数不固定，窄屏上挤压会让单元格逐字断行。列对齐随分隔行的冒号；表头是读屏的标题。
            ScrollView(.horizontal, showsIndicators: false) {
                MarkdownTableGrid(header: header, rows: rows, alignments: alignments)
            }
        case .rule:
            Divider()
        case .paragraph(let s):
            Text(s).textSelection(.enabled)
        }
    }
}

/// 只改 opacity 的块淡入：完整排版与高度始终在位，不条件插入 / 不 transition。排期 slot 为 nil（无排期 / 已跳过 / idle）时当轮即 1，并取消未走完的淡入。
/// 中间值由系统动画驱动（animatableData），不每帧写 @State。
private struct BlockRevealFade: ViewModifier {
    let slot: MarkdownBlockSchedule.Slot?
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .modifier(FadeOpacity(opacity: slot == nil || shown ? 1 : 0))
            .onChange(of: slot, initial: true) { _, slot in
                // 无排期（跳过 / idle / 非新块）时 opacity 恒为 1，当轮全显、不等 delay；有排期且尚未显露才起一次淡入。
                guard let slot, !shown else { return }
                withAnimation(.linear(duration: slot.duration).delay(slot.delay)) { shown = true }
            }
    }
}

private struct FadeOpacity: @preconcurrency Animatable, ViewModifier {
    var opacity: Double
    var animatableData: Double { get { opacity } set { opacity = newValue } }

    func body(content: Content) -> some View {
        #if DEBUG
        let _ = { if opacity > 0.001 && opacity < 0.999 { MarkdownBlockRevealProbe.recordIntermediate() } }()
        #endif
        content.opacity(opacity)
    }
}

/// 表格列对齐：分隔行的冒号同时决定三处取值。Grid 的列方向、单元格 frame 的对齐、多行文字的对齐必须一致；
/// 只设列方向时，frame 仍按左对齐，同列有长格把列撑满时短格会靠左（#156 h30a3）。无冒号或越界按左对齐。
struct TableCellAlignment: Equatable {
    let column: HorizontalAlignment
    let frame: Alignment
    let text: TextAlignment
}

func tableCellAlignment(_ alignments: [MarkdownTableAlignment], _ index: Int) -> TableCellAlignment {
    let alignment = index < alignments.count ? alignments[index] : .unspecified
    switch alignment {
    case .unspecified, .left: return TableCellAlignment(column: .leading, frame: .leading, text: .leading)
    case .center: return TableCellAlignment(column: .center, frame: .center, text: .center)
    case .right: return TableCellAlignment(column: .trailing, frame: .trailing, text: .trailing)
    }
}
/// 表格的 Grid 本体（不含横向 ScrollView）：生产表格与离屏渲染测试共用，修饰顺序只在这里定义。
struct MarkdownTableGrid: View {
    /// 单元格文字宽度的上限（pt）：超过的长格按这个宽度换行，换行后的完整高度参与测量。
    static let cellMaxWidth: CGFloat = 280

    let header: [AttributedString]
    let rows: [[AttributedString]]
    let alignments: [MarkdownTableAlignment]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { i, h in
                    cell(h, column: i, font: .body.weight(.semibold)).accessibilityAddTraits(.isHeader)
                }
            }
            Divider().gridCellColumns(header.count)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    ForEach(Array(r.enumerated()), id: \.offset) { i, c in cell(c, column: i, font: nil) }
                }
            }
        }
    }

    private func cell(_ text: AttributedString, column i: Int, font: Font?) -> some View {
        let a = tableCellAlignment(alignments, i)
        return BoundedWidthCell(cap: Self.cellMaxWidth, alignment: a.frame) {
            Text(text).font(font).multilineTextAlignment(a.text).textSelection(.enabled)
        }
        .gridColumnAlignment(a.column)
    }
}

/// 单子视图的表格单元格：测量时宽度提议以 cap 为上限（提议为无限宽时取 cap），高度按该宽度下的完整换行高度给出；
/// 摆放时用同一个宽度，并按列对齐在 bounds 内定位。替代 fixedSize 与 frame(maxWidth:)，二者不叠加使用。
struct BoundedWidthCell: Layout {
    let cap: CGFloat
    let alignment: Alignment

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified).width
        let width = min(ideal, proposal.width ?? cap, cap)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let ideal = child.sizeThatFits(.unspecified).width
        let width = min(ideal, bounds.width, cap)
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let x: CGFloat
        switch alignment.horizontal {
        case .trailing: x = bounds.maxX - size.width
        case .center: x = bounds.midX - size.width / 2
        default: x = bounds.minX
        }
        child.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
    }
}
#endif
