import Foundation
import Testing
@testable import PalmhelmKit

// h10a K3：主题 token 与语义色的精确值（来源：reins-ios-ia-theme-usage/spec.md 表；错误色来自 h11 spec「深色」节）。
@Suite struct ThemeTokensTests {
    @Test func clearBlueIsDefaultAndExact() {
        #expect(PalmhelmThemeFamily.standard == .clearBlue)
        let t = PalmhelmThemeTokens.tokens(.clearBlue)
        #expect(t.light == PalmhelmThemeSwatch(accent: 0x245AC7, accentSoft: 0xE7EEFC, card: 0xFFFFFF, card2: 0xF0F3F9, emphasis: 0x183E83, onAccent: 0xFFFFFF))
        #expect(t.dark == PalmhelmThemeSwatch(accent: 0x8CB4FF, accentSoft: 0x213653, card: 0x191D25, card2: 0x272E3A, emphasis: 0xD0E0FF, onAccent: 0x102445))
    }

    @Test func warmOrangeExact() {
        let t = PalmhelmThemeTokens.tokens(.warmOrange)
        #expect(t.light == PalmhelmThemeSwatch(accent: 0xB53C1D, accentSoft: 0xFCE9E2, card: 0xFFFFFF, card2: 0xF5F0EC, emphasis: 0x7C2D18, onAccent: 0xFFFFFF))
        #expect(t.dark == PalmhelmThemeSwatch(accent: 0xFF9A78, accentSoft: 0x42271F, card: 0x1B1D21, card2: 0x282B31, emphasis: 0xFFD5C5, onAccent: 0x301208))
    }

    @Test func qoderGreenExact() {
        let t = PalmhelmThemeTokens.tokens(.qoderGreen)
        #expect(t.light == PalmhelmThemeSwatch(accent: 0x255A41, accentSoft: 0xE3EFDD, card: 0xFFFFFF, card2: 0xF2F4F2, emphasis: 0x1B4330, onAccent: 0xFDFDFD))
        #expect(t.dark == PalmhelmThemeSwatch(accent: 0x8FC07E, accentSoft: 0x22351E, card: 0x181C17, card2: 0x242B22, emphasis: 0xD4EBC9, onAccent: 0x10220E))
    }

    @Test func deepSeaExact() {
        let t = PalmhelmThemeTokens.tokens(.deepSea)
        #expect(t.light == PalmhelmThemeSwatch(accent: 0x1A4A5E, accentSoft: 0xE2EDF0, card: 0xFFFFFF, card2: 0xEEF2F3, emphasis: 0x102D3B, onAccent: 0xF7F5EC))
        #expect(t.dark == PalmhelmThemeSwatch(accent: 0x7FC3D6, accentSoft: 0x173440, card: 0x151B1E, card2: 0x212B30, emphasis: 0xCFE9F0, onAccent: 0x0C2631))
    }

    @Test func deepSeaRawValueRoundTripsAndUnknownIsNil() {
        #expect(PalmhelmThemeFamily(rawValue: "deepSea") == .deepSea)
        #expect(PalmhelmThemeFamily(rawValue: "missingFamily") == nil)
        #expect(PalmhelmThemeFamily.standard == .clearBlue)
    }

    @Test func familyLabelsAreChinese() {
        #expect(PalmhelmThemeFamily.allCases.map(\.label) == ["清蓝", "暖橙", "松绿", "深海"])
    }

    // 语义色不随家族变；错误色深浅分别为 #FF7B72 / #C62828。
    @Test func semanticColorsExact() {
        #expect(PalmhelmSemanticColor.bad.light == 0xC62828 && PalmhelmSemanticColor.bad.dark == 0xFF7B72)
        #expect(PalmhelmSemanticColor.ok.light == 0x1F8F3A && PalmhelmSemanticColor.ok.dark == 0x3FB950)
        #expect(PalmhelmSemanticColor.warn.light == 0xB7791F && PalmhelmSemanticColor.warn.dark == 0xE3B341)
    }

    // 指定配对 ≥ 4.5:1（按 WCAG 相对亮度实算）：onAccent 在 accent 上、emphasis 在 accentSoft 上。
    @Test func specifiedPairsMeetContrast() {
        for f in PalmhelmThemeFamily.allCases {
            let t = PalmhelmThemeTokens.tokens(f)
            for s in [t.light, t.dark] {
                #expect(contrast(s.onAccent, s.accent) >= 4.5, "\(f) onAccent/accent")
                #expect(contrast(s.emphasis, s.accentSoft) >= 4.5, "\(f) emphasis/accentSoft")
            }
        }
    }

    private func luminance(_ v: UInt32) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = lin(Double((v >> 16) & 0xFF) / 255), g = lin(Double((v >> 8) & 0xFF) / 255), b = lin(Double(v & 0xFF) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }
}
