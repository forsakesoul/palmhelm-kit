#if canImport(SwiftUI)
import SwiftUI

/// 两端共用的动效口径：一条贝塞尔缓动（先快后缓，cubic-bezier(0.2, 0.9, 0.3, 1)）用于展开/收起与状态切换；
/// 骨架屏的流光是线性循环。AppKit 侧用 `controlPoints` 构造 CAMediaTimingFunction，保证窗口动画与 SwiftUI 内容同一条曲线。
public enum PalmhelmMotion {
    public static let controlPoints: (x1: Double, y1: Double, x2: Double, y2: Double) = (0.2, 0.9, 0.3, 1.0)
    public static let expandDuration = 0.28
    public static let collapseDuration = 0.2
    /// 切换目标/会话时骨架停留的毫秒数：够眼睛察觉“换了”，又不至于拖慢。
    public static let switchSkeletonMs = 220
    public static let ease = Animation.timingCurve(controlPoints.x1, controlPoints.y1, controlPoints.x2, controlPoints.y2, duration: expandDuration)
    public static let quick = Animation.timingCurve(controlPoints.x1, controlPoints.y1, controlPoints.x2, controlPoints.y2, duration: collapseDuration)
    public static let shimmer = Animation.linear(duration: 1.1).repeatForever(autoreverses: false)
    /// 展开内容的进出：从上方滑入并淡入（计算属性：AnyTransition 不是 Sendable，不能做全局常量）。
    public static var reveal: AnyTransition { .move(edge: .top).combined(with: .opacity) }
}

/// 系统「减少动态效果」开启时：不做位移/循环动画，只保留淡入或直接切换。两端共用这一个口径。
public struct PalmhelmAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let value: V
    let quick: Bool
    public func body(content: Content) -> some View {
        content.animation(reduce ? nil : (quick ? PalmhelmMotion.quick : PalmhelmMotion.ease), value: value)
    }
}

public struct PalmhelmRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    public func body(content: Content) -> some View { content.transition(reduce ? .opacity : PalmhelmMotion.reveal) }
}

/// 切换目标/会话时先给一小段骨架再换成内容：数据虽在本地，但没有过渡会显得“硬切”。减少动态效果时直接切换。
public struct SkeletonSwitchModifier<Key: Equatable, Placeholder: View>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let key: Key
    let placeholder: () -> Placeholder
    @State private var showing = false
    @State private var gen = 0

    public func body(content: Content) -> some View {
        // placeholder 挂在内容的 overlay 上：只显示、不参与布局，不会反向撑大 List / 内容；铺满骨架因此拿到有限提议尺寸。
        content.opacity(showing ? 0 : 1)
            .overlay(alignment: .topLeading) { if showing { placeholder().transition(.opacity).allowsHitTesting(false) } }
        .onAppear { trigger() }
        .onChange(of: key) { _, _ in trigger() }
        .onChange(of: reduce) { _, r in if r { gen += 1; showing = false } } // 等待期间开启减少动态效果：立即退出，不淡入
    }

    private func trigger() {
        guard !reduce else { showing = false; return }
        showing = true
        gen += 1
        let g = gen
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(PalmhelmMotion.switchSkeletonMs))
            if g == gen { withAnimation(reduce ? nil : PalmhelmMotion.quick) { showing = false } }
        }
    }
}

public extension View {
    /// 切换 key 时短暂显示骨架（约 0.22s），再淡入内容。
    func skeletonSwitch<Key: Equatable, P: View>(key: Key, @ViewBuilder placeholder: @escaping () -> P) -> some View {
        modifier(SkeletonSwitchModifier(key: key, placeholder: placeholder))
    }
    /// 按统一曲线动画；减少动态效果时不动画。
    func palmhelmAnimation<V: Equatable>(_ value: V, quick: Bool = false) -> some View { modifier(PalmhelmAnimationModifier(value: value, quick: quick)) }
    /// 展开/插入内容的进出过渡；减少动态效果时只淡入。
    func palmhelmReveal() -> some View { modifier(PalmhelmRevealModifier()) }
}

/// 骨架块：圆角灰块 + 一道从左到右的流光。加载态用它代替转圈，布局与真实内容同形。
public struct SkeletonBlock: View {
    public var width: CGFloat?
    public var height: CGFloat
    public var cornerRadius: CGFloat
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    public init(width: CGFloat? = nil, height: CGFloat = 14, cornerRadius: CGFloat = 6) {
        self.width = width; self.height = height; self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.14))
            .frame(width: width, height: height)
            .overlay(GeometryReader { g in
                let band = g.size.width * 0.6
                LinearGradient(colors: [.clear, Color.primary.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: -band + phase * (g.size.width + band))
            })
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear { shimmer(reduce) }
            .onChange(of: reduce) { _, r in shimmer(r) }
            .accessibilityHidden(true)
    }

    // 减少动态效果：停掉流光（用不带动画的事务覆盖 repeatForever）；否则循环。
    private func shimmer(_ reduce: Bool) {
        if reduce {
            var t = Transaction(animation: nil); t.disablesAnimations = true
            withTransaction(t) { phase = 0 }
        } else {
            withAnimation(PalmhelmMotion.shimmer) { phase = 1 }
        }
    }
}

/// 几行文字的骨架（宽度递减，像一段话）。整块对辅助技术是一个“正在加载”元素，内部灰块不逐个播报。
/// `fill: true`：铺满有限提议区域（终端加载面板）——单 Shape 画静态条形 + 整组一道流光；默认调用（卡片内小骨架）版式与行为不变。
public struct SkeletonLines: View {
    public var count: Int
    public var lineHeight: CGFloat
    public var label: String
    public var fill: Bool
    public var spacing: CGFloat
    public var widths: [CGFloat]?
    public var barColor: Color?
    public var shimmerColor: Color?
    public init(count: Int = 3, lineHeight: CGFloat = 12, label: String? = nil, fill: Bool = false, spacing: CGFloat = 8, widths: [CGFloat]? = nil, barColor: Color? = nil, shimmerColor: Color? = nil) {
        self.count = count; self.lineHeight = lineHeight; self.label = label ?? KitL10n.string("正在加载")
        self.fill = fill; self.spacing = spacing; self.widths = widths; self.barColor = barColor; self.shimmerColor = shimmerColor
    }
    /// 终端面板的宽度序列（取自设计稿）。
    public static let terminalWidths: [CGFloat] = SkeletonLayout.terminalWidths

    public var body: some View {
        if fill {
            SkeletonFillView(spec: .lines(thickness: lineHeight, spacing: spacing, widths: widths ?? Self.terminalWidths), barColor: barColor, shimmerColor: shimmerColor)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<count, id: \.self) { i in
                    GeometryReader { g in SkeletonBlock(width: g.size.width * (i == count - 1 ? 0.55 : i % 2 == 0 ? 0.92 : 0.78), height: lineHeight) }
                        .frame(height: lineHeight)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }
}

/// 列表行骨架：圆点/头像 + 标题 + 副标题。`fill: true` 铺满有限提议区域（style 决定行型）；默认不变。
public struct SkeletonRows: View {
    public var count: Int
    public var label: String
    public var fill: Bool
    public var style: SkeletonRowsStyle
    public init(count: Int = 3, label: String? = nil, fill: Bool = false, style: SkeletonRowsStyle = .sidebar) {
        self.count = count; self.label = label ?? KitL10n.string("正在加载"); self.fill = fill; self.style = style
    }
    public var body: some View {
        if fill {
            SkeletonFillView(spec: .rows(style), barColor: nil, shimmerColor: nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<count, id: \.self) { i in
                    HStack(spacing: 10) {
                        SkeletonBlock(width: 22, height: 22, cornerRadius: 6)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBlock(width: CGFloat(110 + (i * 37) % 70), height: 13)
                            SkeletonBlock(width: CGFloat(160 + (i * 53) % 90), height: 10)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }
}

/// 打开会话的气泡流骨架：贴底、从下往上铺满有限提议区域（助手 / 用户交替，含代码块示意），整组只有一道流光。
/// 外观参数由调用端给（Mac 传 bubbleAgent，iOS 传 card）；`maxContentWidth` 为 nil = 填满当前提议宽度（两端真实消息列都没有宽度上限）。
public struct SkeletonThread: View {
    public var userBubble: Color
    public var card: Color
    public var maxContentWidth: CGFloat?
    public var metrics: SkeletonThreadMetrics
    public var label: String
    public init(userBubble: Color, card: Color, maxContentWidth: CGFloat? = nil, metrics: SkeletonThreadMetrics = .iOS, label: String? = nil) {
        self.userBubble = userBubble; self.card = card; self.maxContentWidth = maxContentWidth; self.metrics = metrics
        self.label = label ?? KitL10n.string("正在加载")
    }
    public var body: some View {
        SkeletonFillView(spec: .thread(metrics, maxWidth: maxContentWidth), barColor: nil, shimmerColor: nil, userBubble: userBubble, card: card)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}

// MARK: 单 Shape 绘制（无 GeometryReader、无逐块 State、无几何回调；rect 只是 path(in:) 的绘制 proposal）

private enum SkeletonLayer { case bars, user, assistant, code, dots }

private struct SkeletonLayerShape: Shape {
    let spec: SkeletonSpec
    let layer: SkeletonLayer

    func path(in rect: CGRect) -> Path {
        let d = SkeletonLayout.drawing(spec, in: rect.size)
        let items: [SkeletonRRect]
        switch layer { case .bars: items = d.bars; case .user: items = d.user; case .assistant: items = d.assistant; case .code: items = d.code; case .dots: items = d.dots }
        var p = Path()
        for r in items {
            p.addRoundedRect(in: r.rect.offsetBy(dx: rect.minX, dy: rect.minY), cornerSize: CGSize(width: r.radius, height: r.radius), style: .continuous)
        }
        return p
    }
}

/// 静态层 + 唯一的流光叶子。父级与根页面不读 phase。
private struct SkeletonFillView: View {
    let spec: SkeletonSpec
    let barColor: Color?
    let shimmerColor: Color?
    var userBubble: Color?
    var card: Color?

    var body: some View {
        ZStack {
            if let userBubble { SkeletonLayerShape(spec: spec, layer: .user).fill(userBubble) }
            if let card { SkeletonLayerShape(spec: spec, layer: .assistant).fill(card) }
            SkeletonLayerShape(spec: spec, layer: .code).fill(Color.secondary.opacity(0.10))
            SkeletonLayerShape(spec: spec, layer: .dots).fill(barColor ?? Color.secondary.opacity(0.14))
            SkeletonShimmerBars(spec: spec, barColor: barColor ?? Color.secondary.opacity(0.14), shimmerColor: shimmerColor ?? Color.primary.opacity(0.07))
        }
        .clipped() // 图案为盖满有限提议区域刻意超量（顶部 / 底边的最后一块会越界）：背景、代码框、圆点、灰条与流光一起裁在提议边界内
    }
}

/// 灰条层 + 一道流光：渐变铺满整个区域，用同一灰条 Shape 做 mask（气泡背景不跟着闪）。减少动态效果时没有渐变分支。
private struct SkeletonShimmerBars: View {
    let spec: SkeletonSpec
    let barColor: Color
    let shimmerColor: Color
    @State private var phase: CGFloat = -0.6
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let bars = SkeletonLayerShape(spec: spec, layer: .bars)
        ZStack {
            bars.fill(barColor)
            if !reduce {
                LinearGradient(colors: [.clear, shimmerColor, .clear], startPoint: UnitPoint(x: phase - 0.3, y: 0.5), endPoint: UnitPoint(x: phase + 0.3, y: 0.5))
                    .mask(bars.fill(Color.black))
            }
        }
        .onAppear { run(reduce) }
        .onChange(of: reduce) { _, r in run(r) }
    }

    private func run(_ reduce: Bool) {
        var t = Transaction(animation: nil); t.disablesAnimations = true
        withTransaction(t) { phase = -0.6 } // 先无动画复位到起点，再（仅非减弱动态）启动一次循环
        guard !reduce else { return }
        withAnimation(PalmhelmMotion.shimmer) { phase = 1.6 }
    }
}
#endif
