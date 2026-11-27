#if canImport(SwiftUI)
import SwiftUI
import Testing
@testable import PalmhelmKit
#if os(macOS)
import AppKit
#endif

// #156 h30a4：映射单测覆盖四种对齐；渲染回归在 macOS 的离屏 NSHostingView 中承载真实的 PalmhelmMarkdownText（含横向 ScrollView），
// 检查表头、分隔线、短值与三行长值的行布局与方向。渲染会解析 Markdown，计数是进程级全局，因此渲染用例与既有计数用例同在串行套件里。

@Suite struct MarkdownTableAlignmentMappingTests {
    @Test func fourAlignmentsMapToOneDirectionInEveryLayer() {
        #expect(tableCellAlignment([.unspecified], 0) == TableCellAlignment(column: .leading, frame: .leading, text: .leading))
        #expect(tableCellAlignment([.left], 0) == TableCellAlignment(column: .leading, frame: .leading, text: .leading))
        #expect(tableCellAlignment([.center], 0) == TableCellAlignment(column: .center, frame: .center, text: .center))
        #expect(tableCellAlignment([.right], 0) == TableCellAlignment(column: .trailing, frame: .trailing, text: .trailing))
    }

    @Test func missingColumnFallsBackToLeading() {
        #expect(tableCellAlignment([.right], 3) == TableCellAlignment(column: .leading, frame: .leading, text: .leading))
    }
}

#if os(macOS)
extension PreparedMarkdownTests {
    private static let longValue = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega"

    /// 一段连续墨迹（单位：pt）。rule 为分隔线。
    private struct Band {
        let top: CGFloat, bottom: CGFloat, minX: CGFloat, maxX: CGFloat, rule: Bool
        var midX: CGFloat { (minX + maxX) / 2 }
    }

    /// 在离屏 NSHostingView（宽 310pt）里渲染视图并按行切出墨迹段。返回段与内容的完整高度（pt）。
    @MainActor private func bands(_ view: some View, width: CGFloat = 310) throws -> (bands: [Band], fitHeight: CGFloat) {
        let height: CGFloat = 400
        let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / width
        var out: [Band] = []
        var open: (top: Int, bottom: Int, minX: Int, maxX: Int)?
        func close() {
            guard let g = open else { return }
            let tPt = CGFloat(g.top) / scale, bPt = CGFloat(g.bottom + 1) / scale
            let minPt = CGFloat(g.minX) / scale, maxPt = CGFloat(g.maxX + 1) / scale
            // 分隔线：高度不超过 2pt 且跨度不小于 200pt。
            let rule = (bPt - tPt) <= 2 && (maxPt - minPt) >= 200
            out.append(Band(top: tPt, bottom: bPt, minX: minPt, maxX: maxPt, rule: rule))
            open = nil
        }
        for y in 0..<rep.pixelsHigh {
            var lo = Int.max, hi = -1
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                lo = min(lo, x); hi = max(hi, x)
            }
            if hi < 0 {
                close()
                continue
            }
            if var g = open {
                g.bottom = y; g.minX = min(g.minX, lo); g.maxX = max(g.maxX, hi)
                open = g
            } else {
                open = (y, y, lo, hi)
            }
        }
        close()
        return (out, host.fittingSize.height)
    }

    /// 单列表：表头 `头`、短值 `短`、长值。期望段序：表头、分隔线、短值、三行长值，且段之间不重叠（段之间必有空隙）。
    @MainActor private func table(_ align: String) throws -> [Band] {
        let md = "| 头 |\n|\(align)|\n| 短 |\n| \(Self.longValue) |"
        let (bs, _) = try bands(PalmhelmMarkdownText(text: md))
        #expect(bs.count == 6, "期望 表头、分隔线、短值、三行长值 共 6 段，实际 \(bs.count) 段")
        return bs
    }

    @Test @MainActor func centerTableKeepsRowsApartAndCentersShortCells() throws {
        let bs = try table(":-:")
        guard bs.count == 6 else { return }
        #expect(bs[1].rule, "第二段是表头分隔线")
        let long = bs[3...5]
        let extent = (minX: long.map(\.minX).min()!, maxX: long.map(\.maxX).max()!)
        #expect(abs(bs[0].midX - (extent.minX + extent.maxX) / 2) <= 3, "居中：表头在列中央")
        #expect(abs(bs[2].midX - (extent.minX + extent.maxX) / 2) <= 3, "居中：短值在列中央")
        #expect(zip(bs, bs.dropFirst()).allSatisfy { $0.bottom <= $1.top }, "各段不重叠")
        #expect(bs.last!.bottom > bs[2].bottom + 30, "长值的最后一行在短值之下，没有被压进上一行")
    }

    @Test @MainActor func rightTableAlignsShortCellsToTheColumnEnd() throws {
        let bs = try table("-:")
        guard bs.count == 6 else { return }
        let long = bs[3...5]
        let longMaxX = long.map(\.maxX).max()!
        #expect(abs(bs[0].maxX - longMaxX) <= 2, "右对齐：表头贴右")
        #expect(abs(bs[2].maxX - longMaxX) <= 2, "右对齐：短值贴右")
        #expect(bs[2].minX > longMaxX / 2, "右对齐：短值不在左半")
        #expect(zip(bs, bs.dropFirst()).allSatisfy { $0.bottom <= $1.top }, "各段不重叠")
    }

    @Test @MainActor func leftTableAlignsShortCellsToTheColumnStart() throws {
        let bs = try table(":-")
        guard bs.count == 6 else { return }
        let longMinX = bs[3...5].map(\.minX).min()!
        #expect(abs(bs[2].minX - longMinX) <= 2, "左对齐：短值靠左")
        #expect(abs(bs[0].minX - longMinX) <= 2, "左对齐：表头靠左")
    }
}
#endif
#endif
