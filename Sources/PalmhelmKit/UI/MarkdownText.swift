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
        case .table(let header, let rows):
            // 宽表横向滚动而不是挤压列宽：列数不固定，窄屏上挤压会让单元格逐字断行
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, h in Text(h).font(.body.weight(.semibold)).textSelection(.enabled) } }
                    Divider().gridCellColumns(header.count)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in Text(c).textSelection(.enabled) } }
                    }
                }
            }
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
#endif
