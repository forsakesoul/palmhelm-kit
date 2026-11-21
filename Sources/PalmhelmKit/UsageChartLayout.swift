import Foundation
import CoreGraphics

/// 用量柱图的标签布局（#30 / #30 S1，两端共用）：标签按可用宽度与字号自适应减少，底部预留高度随字号变化。
/// 纯函数：不依赖视图；字号倍率由调用方按动态字体换算后传入（iOS 用 DynamicTypeSize，Mac 用 1）。
public enum UsageChartLayout {
    /// 相邻两个标签之间的最小留白（pt）。
    public static let labelGap: CGFloat = 6
    /// 底部标签区的基础高度（pt，字号倍率 1 时）。
    public static let baseLabelBand: CGFloat = 18
    /// 数字 / 中文字符的近似宽度占字号的比例（用于估计标签宽度；保守取大）。
    public static let charWidthRatio: CGFloat = 0.62

    /// 标注步长：保证相邻被标注柱子的中心距 ≥ 标签宽 + gap。至少 1（全部标注）；柱子很少时也是 1。
    public static func labelStride(count: Int, plotWidth: CGFloat, labelWidth: CGFloat) -> Int {
        guard count > 1, plotWidth > 0, labelWidth > 0 else { return 1 }
        let slot = plotWidth / CGFloat(count) // 相邻柱子的中心距
        return max(1, Int(ceil((labelWidth + labelGap) / slot)))
    }

    /// 估计一段标签的宽度：最长标签的字符数 × 字号 × 字符宽比例。
    public static func labelWidth(maxChars: Int, pointSize: CGFloat) -> CGFloat {
        CGFloat(max(maxChars, 1)) * pointSize * charWidthRatio
    }

    /// 底部标签区高度：随字号倍率缩放（大字号时标签更高，不被裁掉）。
    public static func labelBand(scale: CGFloat) -> CGFloat { baseLabelBand * max(scale, 1) }
}
