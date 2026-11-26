import CoreGraphics
import Testing
@testable import PalmhelmKit

// 骨架铺满（A2-000 §5）：纯布局函数。只测实际绘图布局，不做像素快照。
@Suite struct SkeletonLayoutTests {
    private let sizes: [CGSize] = [CGSize(width: 390, height: 844), CGSize(width: 1000, height: 4320), CGSize(width: 100, height: 4320), CGSize(width: 40, height: 600), CGSize(width: 1, height: 300)]

    private func all(_ d: SkeletonDrawing) -> [SkeletonRRect] { d.bars + d.user + d.assistant + d.code + d.dots }

    private func assertSane(_ d: SkeletonDrawing, _ size: CGSize, _ what: String) {
        for r in all(d) {
            let ok = r.rect.minX.isFinite && r.rect.minY.isFinite && r.rect.width.isFinite && r.rect.height.isFinite && r.radius.isFinite
                && r.rect.width > 0 && r.rect.height > 0 && r.radius >= 0 && r.rect.minX >= -1e-6 && r.rect.maxX <= size.width + 1e-6
            #expect(ok, "\(what) \(size) \(r)")
        }
    }

    // SkeletonRows 是 View，成员受 MainActor 隔离；在非隔离的 #expect autoclosure 里读会报
    // "main actor-isolated property 'style' can not be referenced from a nonisolated autoclosure"。
    @MainActor @Test func defaultCallsKeepNaturalLayout() {
        let lines = SkeletonLines()
        #expect(lines.count == 3 && lines.lineHeight == 12 && lines.spacing == 8 && !lines.fill && lines.widths == nil && lines.barColor == nil)
        let rows = SkeletonRows()
        #expect(rows.count == 3 && !rows.fill && rows.style == .sidebar)
        #expect(SkeletonThreadMetrics.iOS == SkeletonThreadMetrics(userInset: 10, assistantInset: 10, radius: 14, oppositeSpacer: 40, rowGap: 8))
        #expect(SkeletonThreadMetrics.mac == SkeletonThreadMetrics(userInset: 10, assistantInset: 12, radius: 12, oppositeSpacer: 120, rowGap: 10))
    }

    @Test func degenerateSizesDrawNothing() {
        for s in [CGSize.zero, CGSize(width: 0, height: 500), CGSize(width: 300, height: 0), CGSize(width: -5, height: 10), CGSize(width: CGFloat.nan, height: 10), CGSize(width: 10, height: CGFloat.infinity)] {
            for spec in [SkeletonSpec.thread(.iOS, maxWidth: nil), .lines(thickness: 12, spacing: 8, widths: SkeletonLayout.terminalWidths), .rows(.target), .rows(.sidebar)] {
                #expect(SkeletonLayout.drawing(spec, in: s) == SkeletonDrawing())
            }
        }
    }

    // MARK: 气泡流
    @Test func threadAlternatesRecipeFromTheBottomAndAnchorsToIt() {
        let size = CGSize(width: 390, height: 2000)
        let d = SkeletonLayout.thread(size, metrics: .iOS, maxWidth: nil)
        let bubbles = (d.user.map { (true, $0) } + d.assistant.map { (false, $0) }).sorted { $0.1.rect.maxY > $1.1.rect.maxY }
        #expect(bubbles.first!.1.rect.maxY == size.height)                    // 贴底，底部无额外留白（外 padding 由调用端给）
        #expect(Array(bubbles.prefix(8).map(\.0)) == [false, true, false, true, false, true, false, true]) // 助手 / 用户 / 助手 / 用户 循环
        #expect(bubbles.last!.1.rect.minY <= 0)                                // 顶部被裁掉，不留空
        for (a, b) in zip(bubbles, bubbles.dropFirst()) { #expect(abs((a.1.rect.minY - b.1.rect.maxY) - 8) < 1e-6) } // 行距 8
        #expect(d.code.count > 0 && d.bars.count > 0)
        // 底部气泡：助手 3 行 [.92 .78 .55]，高度 = 2*10 + 3*12 + 2*8
        let bottom = bubbles.first!.1
        #expect(bottom.rect.height == 72 && bottom.radius == 14 && bottom.rect.minX == 0)
    }

    @Test func threadWidthsAreClampedAndSidesAreRight() {
        let size = CGSize(width: 300, height: 900)
        let d = SkeletonLayout.thread(size, metrics: .iOS, maxWidth: nil)
        let avail: CGFloat = 300 - 40 - 8
        #expect(d.assistant.allSatisfy { abs($0.rect.width - avail) < 1e-6 && $0.rect.minX == 0 })
        #expect(d.user.allSatisfy { $0.rect.maxX == 300 && $0.rect.width <= avail * 0.72 + 1e-6 })
        let mac = SkeletonLayout.thread(CGSize(width: 800, height: 900), metrics: .mac, maxWidth: nil)
        #expect(mac.assistant.allSatisfy { abs($0.rect.width - (800 - 120 - 8)) < 1e-6 && $0.radius == 12 })
        let capped = SkeletonLayout.thread(CGSize(width: 800, height: 900), metrics: .iOS, maxWidth: 400)
        #expect(capped.assistant.allSatisfy { $0.rect.minX == 200 }) // 列居中
    }

    @Test func overshootIsByDesignSoTheContainerMustClip() {
        // 布局为盖满边界会让最后一块越过提议 rect；SkeletonFillView 的 .clipped() 负责裁掉（三种填充分支共用它）。
        let t = SkeletonLayout.thread(CGSize(width: 390, height: 300), metrics: .iOS, maxWidth: nil)
        #expect((t.user + t.assistant).map(\.rect.minY).min()! < 0)
        let r = SkeletonLayout.rows(CGSize(width: 230, height: 4320), style: .sidebar)
        #expect((r.dots + r.bars).map(\.rect.maxY).max()! > 4320) // 列表末行越过底边
    }

    @Test func threadStaysSaneAtNarrowZeroAndTallSizes() {
        for s in sizes {
            for m in [SkeletonThreadMetrics.iOS, .mac] {
                let d = SkeletonLayout.thread(s, metrics: m, maxWidth: nil)
                assertSane(d, s, "thread")
                if s.width - m.oppositeSpacer - 8 > 0 { #expect(d.assistant.count + d.user.count > 0) } else { #expect(all(d).isEmpty) } // 窄到没有可用列：不画、不负宽
            }
        }
    }

    @Test func threadCoversFourThousandPointsBeyondTheFixedBudget() {
        let d = SkeletonLayout.thread(CGSize(width: 1000, height: 4320), metrics: .iOS, maxWidth: nil)
        let top = (d.user + d.assistant).map(\.rect.minY).min()!
        #expect(top <= 0)
        let bottom = (d.user + d.assistant).map(\.rect.maxY).max()!
        #expect(bottom == 4320 && d.user.count + d.assistant.count > 40) // 覆盖条件决定数量，不靠固定上限
        // 极矮气泡（负 rowGap 之外的退化）也不无界：矮窗口少量气泡
        #expect(SkeletonLayout.thread(CGSize(width: 390, height: 10), metrics: .iOS, maxWidth: nil).assistant.count == 1)
    }

    // MARK: 终端行
    @Test func terminalLinesFillFromTopWithTheCycleAndCoverTallPanels() {
        for h in [CGFloat(300), 4320] {
            let size = CGSize(width: 400, height: h)
            let d = SkeletonLayout.lines(size, thickness: 9, spacing: 8, widths: SkeletonLayout.terminalWidths)
            #expect(d.bars.first!.rect.minY == 0)
            #expect(abs(d.bars[1].rect.minY - 17) < 1e-6)
            #expect(d.bars.last!.rect.minY < h && d.bars.last!.rect.minY + 17 >= h) // 末行到边
            #expect(d.bars.prefix(3).map { $0.rect.width / 400 } == [0.38, 0.72, 0.64])
            assertSane(d, size, "lines")
        }
        // 行距小到 512 行也盖不满 4320 时继续重复
        let dense = SkeletonLayout.lines(CGSize(width: 100, height: 4320), thickness: 4, spacing: 0, widths: [0.5])
        #expect(dense.bars.count > 512 && dense.bars.last!.rect.maxY >= 4320)
    }

    // MARK: 列表行
    @Test func rowsFillFromTopForBothStylesAndCoverTallLists() {
        for style in [SkeletonRowsStyle.sidebar, .target] {
            for s in sizes {
                let d = SkeletonLayout.rows(s, style: style)
                assertSane(d, s, "rows \(style)")
                #expect(d.dots.first!.rect.minY >= 0)
                #expect(d.dots.last!.rect.minY < s.height + 44)
            }
            let tall = SkeletonLayout.rows(CGSize(width: 300, height: 4320), style: style)
            #expect(tall.dots.count >= (style == .target ? 98 : 100)) // 4320 / pitch 44 或 43
        }
        let t = SkeletonLayout.rows(CGSize(width: 300, height: 200), style: .target)
        #expect(t.dots.first!.rect.width == 9 && t.dots.first!.radius == 4.5) // 9 圆点
        #expect(abs((t.dots[1].rect.minY - t.dots[0].rect.minY) - 44) < 1e-6)  // 行距 44
        let s = SkeletonLayout.rows(CGSize(width: 300, height: 200), style: .sidebar)
        #expect(s.dots.first!.rect.width == 22)                                  // 保留现有 22 图标
    }
}
