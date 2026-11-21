import Foundation
import CoreGraphics

// 骨架铺满（A2-000）：纯布局函数。给定绘制 rect 的尺寸，从固定图案生成圆角矩形集合；
// “绘制 rect 被覆盖”是最终条件——静态预算（128 气泡 / 512 行 / 256 行）只是常规窗口的默认量，不是露空的理由，到不了边就继续重复周期。
// 这里只有值与函数：不测量视图、不持 State、不回传尺寸。

/// 对话气泡流的两端真实尺寸差异（只读外观参数，不含业务状态）。
public struct SkeletonThreadMetrics: Equatable, Sendable {
    public var userInset: CGFloat
    public var assistantInset: CGFloat
    public var radius: CGFloat
    /// 对侧 Spacer 的最小值（不含与气泡的间隙）。
    public var oppositeSpacer: CGFloat
    public var rowGap: CGFloat

    public init(userInset: CGFloat, assistantInset: CGFloat, radius: CGFloat, oppositeSpacer: CGFloat, rowGap: CGFloat) {
        self.userInset = userInset; self.assistantInset = assistantInset; self.radius = radius; self.oppositeSpacer = oppositeSpacer; self.rowGap = rowGap
    }
    /// iOS 真实行：padding 10 / 圆角 14 / 对侧 Spacer 40 / 行距 8。
    public static let iOS = SkeletonThreadMetrics(userInset: 10, assistantInset: 10, radius: 14, oppositeSpacer: 40, rowGap: 8)
    /// Mac 真实行：用户 padding 10、助手 padding 12、圆角 12、对侧 Spacer 120、行距 10。
    public static let mac = SkeletonThreadMetrics(userInset: 10, assistantInset: 12, radius: 12, oppositeSpacer: 120, rowGap: 10)
}

/// 列表骨架样式：sidebar = 现有 Rows（22 图标 / 13 / 10）；target = 目标行（9 圆点，两行文字间距 2，最小行距 44）。
public enum SkeletonRowsStyle: Equatable, Sendable { case sidebar, target }

struct SkeletonRRect: Equatable {
    var rect: CGRect
    var radius: CGFloat
}

struct SkeletonDrawing: Equatable {
    var bars: [SkeletonRRect] = []
    var user: [SkeletonRRect] = []
    var assistant: [SkeletonRRect] = []
    var code: [SkeletonRRect] = []
    var dots: [SkeletonRRect] = []
}

enum SkeletonSpec: Equatable {
    case thread(SkeletonThreadMetrics, maxWidth: CGFloat?)
    case lines(thickness: CGFloat, spacing: CGFloat, widths: [CGFloat])
    case rows(SkeletonRowsStyle)
}

enum SkeletonLayout {
    /// 常规窗口只需约 128 气泡 / 512 行 / 256 行；这里是退化尺寸的安全上限，不是露空的理由（覆盖 rect 才是终止条件）。
    static let hardCap = 20_000

    static let barThickness: CGFloat = 12
    static let barGap: CGFloat = 8
    static let codeBarThickness: CGFloat = 10
    static let codeBarGap: CGFloat = 6
    static let codePadding: CGFloat = 8
    static let codeRadius: CGFloat = 8
    static var codeBoxHeight: CGFloat { codePadding * 2 + codeBarThickness * 3 + codeBarGap * 2 }

    static let terminalWidths: [CGFloat] = [0.38, 0.72, 0.64, 0.20, 0.88, 0.55, 0.30, 0.76, 0.46, 0.60, 0.24, 0.82]

    static func valid(_ size: CGSize) -> Bool { size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 }

    static func drawing(_ spec: SkeletonSpec, in size: CGSize) -> SkeletonDrawing {
        guard valid(size) else { return SkeletonDrawing() }
        switch spec {
        case .thread(let m, let maxWidth): return thread(size, metrics: m, maxWidth: maxWidth)
        case .lines(let t, let s, let w): return lines(size, thickness: t, spacing: s, widths: w)
        case .rows(let style): return rows(size, style: style)
        }
    }

    // MARK: 气泡流（下→上，固定循环：助手 3 行 / 用户 2 行 / 助手 2 行 + 代码 3 条 + 末行 / 用户 1 行）

    private enum Item { case bar(CGFloat), code }
    private struct Bubble { let user: Bool; let widthFraction: CGFloat; let items: [Item] }
    private static let recipe: [Bubble] = [
        Bubble(user: false, widthFraction: 1, items: [.bar(0.92), .bar(0.78), .bar(0.55)]),
        Bubble(user: true, widthFraction: 0.72, items: [.bar(1), .bar(0.60)]),
        Bubble(user: false, widthFraction: 1, items: [.bar(0.86), .bar(0.70), .code, .bar(0.48)]),
        Bubble(user: true, widthFraction: 0.46, items: [.bar(1)]),
    ]
    private static let codeFractions: [CGFloat] = [0.80, 0.64, 0.72]

    static func thread(_ size: CGSize, metrics m: SkeletonThreadMetrics, maxWidth: CGFloat?) -> SkeletonDrawing {
        var d = SkeletonDrawing()
        let column = min(size.width, max(0, maxWidth ?? .infinity))
        let x0 = (size.width - column) / 2
        let avail = max(0, column - m.oppositeSpacer - 8) // 对侧留白 + 内容间隙 8；窄窗不出现负宽
        var y = size.height
        var n = 0
        while y > 0, n < hardCap {
            let b = recipe[n % recipe.count]
            let inset = b.user ? m.userInset : m.assistantInset
            let contentH = b.items.reduce(CGFloat(0)) { $0 + height(of: $1) } + barGap * CGFloat(b.items.count - 1)
            let h = inset * 2 + contentH
            let bw = avail * b.widthFraction
            let bx = b.user ? x0 + column - bw : x0
            y -= h
            if bw > 0 {
                let bubble = SkeletonRRect(rect: CGRect(x: bx, y: y, width: bw, height: h), radius: m.radius)
                if b.user { d.user.append(bubble) } else { d.assistant.append(bubble) }
                let inner = max(0, bw - inset * 2)
                var iy = y + inset
                for item in b.items {
                    switch item {
                    case .bar(let f):
                        if inner * f > 0 { d.bars.append(SkeletonRRect(rect: CGRect(x: bx + inset, y: iy, width: inner * f, height: barThickness), radius: barThickness / 2)) }
                        iy += barThickness + barGap
                    case .code:
                        d.code.append(SkeletonRRect(rect: CGRect(x: bx + inset, y: iy, width: inner, height: codeBoxHeight), radius: codeRadius))
                        let cw = max(0, inner - codePadding * 2)
                        for (k, f) in codeFractions.enumerated() where cw * f > 0 {
                            let cy = iy + codePadding + CGFloat(k) * (codeBarThickness + codeBarGap)
                            d.bars.append(SkeletonRRect(rect: CGRect(x: bx + inset + codePadding, y: cy, width: cw * f, height: codeBarThickness), radius: codeBarThickness / 2))
                        }
                        iy += codeBoxHeight + barGap
                    }
                }
            }
            y -= m.rowGap
            n += 1
        }
        return d
    }

    private static func height(of item: Item) -> CGFloat {
        switch item { case .bar: barThickness; case .code: codeBoxHeight }
    }

    // MARK: 文字行 / 终端行（自上而下）

    static func lines(_ size: CGSize, thickness: CGFloat, spacing: CGFloat, widths: [CGFloat]) -> SkeletonDrawing {
        var d = SkeletonDrawing()
        let t = max(0.5, thickness)
        let pitch = t + max(0, spacing)
        let w = widths.isEmpty ? [0.92, 0.78] : widths
        var y: CGFloat = 0
        var i = 0
        while y < size.height, i < hardCap {
            let bw = size.width * w[i % w.count]
            if bw > 0 { d.bars.append(SkeletonRRect(rect: CGRect(x: 0, y: y, width: bw, height: t), radius: min(6, t / 2))) }
            y += pitch
            i += 1
        }
        return d
    }

    // MARK: 列表行（自上而下）

    static func rows(_ size: CGSize, style: SkeletonRowsStyle) -> SkeletonDrawing {
        var d = SkeletonDrawing()
        let icon: CGFloat = style == .target ? 9 : 22
        let textGap: CGFloat = style == .target ? 2 : 6
        let textBlock: CGFloat = 13 + textGap + 10
        let content = max(icon, textBlock)
        // target：最小行距 44（交互最小行口径，真实 List 行高自适应，不是项目常量）；sidebar：沿用现有 Rows 的行距 14。
        let pitch: CGFloat = style == .target ? max(44, content) : content + 14
        let textX = icon + 10
        let room = max(0, size.width - textX)
        var y: CGFloat = 0
        var i = 0
        while y < size.height, i < hardCap {
            let top = style == .target ? y + (pitch - content) / 2 : y
            d.dots.append(SkeletonRRect(rect: CGRect(x: 0, y: top + (content - icon) / 2, width: min(icon, size.width), height: icon), radius: style == .target ? icon / 2 : 6)) // 窄到容不下图标：收窄，不出界
            let textTop = top + (content - textBlock) / 2
            let tw = min(room, CGFloat(110 + (i * 37) % 70)), sw = min(room, CGFloat(160 + (i * 53) % 90))
            if tw > 0 { d.bars.append(SkeletonRRect(rect: CGRect(x: textX, y: textTop, width: tw, height: 13), radius: 6)) }
            if sw > 0 { d.bars.append(SkeletonRRect(rect: CGRect(x: textX, y: textTop + 13 + textGap, width: sw, height: 10), radius: 5)) }
            y += pitch
            i += 1
        }
        return d
    }
}
