import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// 主题家族（h11 设置里的外观）：清蓝为默认，暖橙、松绿与深海可选，按设备保存。两端共用。
public enum PalmhelmThemeFamily: String, Sendable, CaseIterable, Codable {
    case clearBlue, warmOrange, qoderGreen, deepSea

    public static let standard: PalmhelmThemeFamily = .clearBlue

    public var label: String {
        switch self { case .clearBlue: KitL10n.string("清蓝"); case .warmOrange: KitL10n.string("暖橙"); case .qoderGreen: KitL10n.string("松绿"); case .deepSea: KitL10n.string("深海") }
    }
}

/// 一套主题在某一明暗模式下的 token（0xRRGGBB）。字段名与设计表（reins-ios-ia-theme-usage）的列一致。
public struct PalmhelmThemeSwatch: Sendable, Equatable {
    public let accent: UInt32
    public let accentSoft: UInt32
    public let card: UInt32
    public let card2: UInt32
    public let emphasis: UInt32
    public let onAccent: UInt32

    public init(accent: UInt32, accentSoft: UInt32, card: UInt32, card2: UInt32, emphasis: UInt32, onAccent: UInt32) {
        self.accent = accent; self.accentSoft = accentSoft; self.card = card; self.card2 = card2; self.emphasis = emphasis; self.onAccent = onAccent
    }
}

/// 主题 token：浅 / 深两套。表中指定配对（accent 与 onAccent 等）≥ 4.5:1（Advisor 实算）。
/// 「工作中」的点与文字跟 accent；ok / warn / bad 不随家族变（见 PalmhelmSemanticColor）。
public struct PalmhelmThemeTokens: Sendable, Equatable {
    public let light: PalmhelmThemeSwatch
    public let dark: PalmhelmThemeSwatch

    public init(light: PalmhelmThemeSwatch, dark: PalmhelmThemeSwatch) { self.light = light; self.dark = dark }

    public static func tokens(_ family: PalmhelmThemeFamily) -> PalmhelmThemeTokens {
        switch family {
        case .clearBlue:
            PalmhelmThemeTokens(
                light: PalmhelmThemeSwatch(accent: 0x245AC7, accentSoft: 0xE7EEFC, card: 0xFFFFFF, card2: 0xF0F3F9, emphasis: 0x183E83, onAccent: 0xFFFFFF),
                dark: PalmhelmThemeSwatch(accent: 0x8CB4FF, accentSoft: 0x213653, card: 0x191D25, card2: 0x272E3A, emphasis: 0xD0E0FF, onAccent: 0x102445))
        case .warmOrange:
            PalmhelmThemeTokens(
                light: PalmhelmThemeSwatch(accent: 0xB53C1D, accentSoft: 0xFCE9E2, card: 0xFFFFFF, card2: 0xF5F0EC, emphasis: 0x7C2D18, onAccent: 0xFFFFFF),
                dark: PalmhelmThemeSwatch(accent: 0xFF9A78, accentSoft: 0x42271F, card: 0x1B1D21, card2: 0x282B31, emphasis: 0xFFD5C5, onAccent: 0x301208))
        case .qoderGreen:
            PalmhelmThemeTokens(
                light: PalmhelmThemeSwatch(accent: 0x255A41, accentSoft: 0xE3EFDD, card: 0xFFFFFF, card2: 0xF2F4F2, emphasis: 0x1B4330, onAccent: 0xFDFDFD),
                dark: PalmhelmThemeSwatch(accent: 0x8FC07E, accentSoft: 0x22351E, card: 0x181C17, card2: 0x242B22, emphasis: 0xD4EBC9, onAccent: 0x10220E))
        case .deepSea:
            PalmhelmThemeTokens(
                light: PalmhelmThemeSwatch(accent: 0x1A4A5E, accentSoft: 0xE2EDF0, card: 0xFFFFFF, card2: 0xEEF2F3, emphasis: 0x102D3B, onAccent: 0xF7F5EC),
                dark: PalmhelmThemeSwatch(accent: 0x7FC3D6, accentSoft: 0x173440, card: 0x151B1E, card2: 0x212B30, emphasis: 0xCFE9F0, onAccent: 0x0C2631))
        }
    }
}

/// 语义色：成功 / 等你 / 错误。不随主题家族变；深色错误文字 #FF7B72、浅色 #C62828（h11 spec「深色」节）。
public enum PalmhelmSemanticColor: Sendable, CaseIterable {
    case ok, warn, bad

    public var light: UInt32 {
        switch self { case .ok: 0x1F8F3A; case .warn: 0xB7791F; case .bad: 0xC62828 }
    }
    public var dark: UInt32 {
        switch self { case .ok: 0x3FB950; case .warn: 0xE3B341; case .bad: 0xFF7B72 }
    }
}

#if canImport(SwiftUI)
extension PalmhelmThemeTokens {
    /// 随系统明暗切换的颜色（复用 PalmhelmIdentityPalette.adaptive）。
    public func color(_ key: KeyPath<PalmhelmThemeSwatch, UInt32>) -> Color {
        PalmhelmIdentityPalette.adaptive(light: light[keyPath: key], dark: dark[keyPath: key])
    }
}

extension PalmhelmSemanticColor {
    /// 随系统明暗切换的语义色。
    public var color: Color { PalmhelmIdentityPalette.adaptive(light: light, dark: dark) }
}
#endif
