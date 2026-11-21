import CoreGraphics
import Testing
@testable import PalmhelmKit

// #30 S1：标签步长随可用宽度与字号自适应；底部预留随字号变化。
@Suite struct UsageChartLabelLayoutTests {
    @Test func everyBarLabelledWhenThereIsRoom() {
        // 7 天、每根柱子 ~50pt，标签 5 字符 @11pt（约 34pt）：全部标注
        #expect(UsageChartLayout.labelStride(count: 7, plotWidth: 350, labelWidth: 34) == 1)
    }

    @Test func strideGrowsOnNarrowWidths() {
        // 24 小时、SE 宽度（约 280pt 绘图区）：每根约 11.7pt，标签 3 字符 ≈ 21pt → 每 3 根
        let w = UsageChartLayout.labelWidth(maxChars: 3, pointSize: 11)
        let narrow = UsageChartLayout.labelStride(count: 24, plotWidth: 280, labelWidth: w)
        let wide = UsageChartLayout.labelStride(count: 24, plotWidth: 700, labelWidth: w)
        #expect(narrow > wide)
        #expect(narrow >= 2)
        // 相邻标注的中心距确实够放下标签
        let slot: CGFloat = 280 / 24
        #expect(CGFloat(narrow) * slot >= w + UsageChartLayout.labelGap)
    }

    @Test func largeTypeIncreasesStride() {
        let base = UsageChartLayout.labelStride(count: 24, plotWidth: 300, labelWidth: UsageChartLayout.labelWidth(maxChars: 3, pointSize: 11))
        let big = UsageChartLayout.labelStride(count: 24, plotWidth: 300, labelWidth: UsageChartLayout.labelWidth(maxChars: 3, pointSize: 11 * 2.35))
        #expect(big > base)
    }

    @Test func degenerateInputsAreSafe() {
        #expect(UsageChartLayout.labelStride(count: 0, plotWidth: 300, labelWidth: 20) == 1)
        #expect(UsageChartLayout.labelStride(count: 1, plotWidth: 300, labelWidth: 20) == 1)
        #expect(UsageChartLayout.labelStride(count: 24, plotWidth: 0, labelWidth: 20) == 1)
        #expect(UsageChartLayout.labelBand(scale: 0.5) == UsageChartLayout.baseLabelBand, "不会因为缩小字号而变矮")
        #expect(UsageChartLayout.labelBand(scale: 2.35) > UsageChartLayout.labelBand(scale: 1))
    }
}
