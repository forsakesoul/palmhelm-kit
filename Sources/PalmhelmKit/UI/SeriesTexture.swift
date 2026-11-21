#if canImport(SwiftUI)
import SwiftUI
import CoreGraphics

/// 系列纹理（O1-359 R2）：系统「区分时不仅依赖颜色」开启时，系列用纹理区分，图例与图使用同一套样式。
/// S0 实填，S1 斜线，S2 点纹，其他横纹。纹理只是对颜色的补充，不替代文字名称。
public enum UsageSeriesTexture {
    enum Kind: Equatable { case solid, diagonal, dots, stripes }

    /// 系列序号 → 纹理种类（nil / 超出为其他，横纹）。
    static func kind(_ index: Int?) -> Kind {
        switch index {
        case 0?: .solid
        case 1?: .diagonal
        case 2?: .dots
        default: .stripes
        }
    }

    /// 图与图例共用的填充样式。differentiate 为 false 时就是实色（与 `UsageSeriesColor.color` 相同）。
    public static func fill(_ index: Int?, family: PalmhelmThemeFamily, dark: Bool, differentiate: Bool) -> AnyShapeStyle {
        let hex = UsageSeriesColor.hex(index, family: family, dark: dark)
        let k = kind(index)
        guard differentiate, k != .solid, let cg = tile(k, hex: hex, size: 8) else {
            return AnyShapeStyle(PalmhelmIdentityPalette.adaptive(light: UsageSeriesColor.hex(index, family: family, dark: false), dark: UsageSeriesColor.hex(index, family: family, dark: true)))
        }
        return AnyShapeStyle(ImagePaint(image: Image(decorative: cg, scale: 1), sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 1))
    }

    /// 透明底的 size × size 瓦片（平铺后形成纹理）。测试可直接调用。
    static func tile(_ kind: Kind, hex: UInt32, size: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.setStrokeColor(red: r, green: g, blue: b, alpha: 1)
        let s = CGFloat(size)
        switch kind {
        case .solid:
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        case .diagonal:
            ctx.setLineWidth(1.6)
            for off in [-s, 0, s] {
                ctx.move(to: CGPoint(x: 0, y: off)); ctx.addLine(to: CGPoint(x: s, y: off + s))
            }
            ctx.strokePath()
        case .dots:
            for (x, y) in [(0.0, 0.0), (s, 0), (0, s), (s, s), (s / 2, s / 2)] {
                ctx.fillEllipse(in: CGRect(x: CGFloat(x) - 1.5, y: CGFloat(y) - 1.5, width: 3, height: 3))
            }
        case .stripes:
            ctx.fill(CGRect(x: 0, y: s / 2 - 1.5, width: s, height: 3))
        }
        return ctx.makeImage()
    }
}
#endif
