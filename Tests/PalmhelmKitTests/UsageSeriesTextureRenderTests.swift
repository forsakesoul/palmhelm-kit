#if canImport(SwiftUI)
import SwiftUI
import CoreGraphics
import Testing
@testable import PalmhelmKit

// O1-360 B2：渲染 UsageSeriesTexture.fill 本身（柱段与图例共用这一入口），断言 on/off 的真实像素，
// 不只查瓦片是否非空。若 fill 永远返回实色，开启纹理的断言必须失败。
@MainActor
@Suite struct UsageSeriesTextureRenderTests {
    private func pixels(_ index: Int?, dark: Bool, differentiate: Bool) throws -> Set<UInt32> {
        let size = 40
        let view = Rectangle().fill(UsageSeriesTexture.fill(index, family: .clearBlue, dark: dark, differentiate: differentiate))
            .frame(width: CGFloat(size), height: CGFloat(size))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        // 拼成 UInt32 像素值。拆成独立语句：写成一个内联的移位表达式时，
        // GitHub 托管镜像的 swiftc 会报 "unable to type-check this expression in reasonable time"。
        var out = Set<UInt32>()
        out.reserveCapacity(buf.count / 4)
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = UInt32(buf[i]) << 24
            let g = UInt32(buf[i + 1]) << 16
            let b = UInt32(buf[i + 2]) << 8
            let a = UInt32(buf[i + 3])
            out.insert(r | g | b | a)
        }
        return out
    }

    @Test func offIsSolidForEverySeries() throws {
        for dark in [false, true] {
            for index in [0, 1, 2, 3, nil] {
                #expect(try pixels(index, dark: dark, differentiate: false).count == 1, "关闭时系列 \(String(describing: index)) 必须实色")
            }
        }
    }

    @Test func onKeepsS0SolidAndTexturesEveryOtherSeriesDistinctly() throws {
        for dark in [false, true] {
            #expect(try pixels(0, dark: dark, differentiate: true).count == 1, "S0 开启纹理时仍实填")
            let diagonal = try pixels(1, dark: dark, differentiate: true)
            let dots = try pixels(2, dark: dark, differentiate: true)
            let stripes = try pixels(nil, dark: dark, differentiate: true)
            for (name, px) in [("斜线", diagonal), ("点纹", dots), ("横纹", stripes)] {
                #expect(px.count >= 2, "\(name) 必须是可辨的图案，不能是实色（dark \(dark)）")
            }
            #expect(diagonal != dots && dots != stripes && diagonal != stripes, "三种图案必须彼此不同（dark \(dark)）")
        }
    }
}
#endif
