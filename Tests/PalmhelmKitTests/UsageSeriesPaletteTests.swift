import Testing
import Foundation
@testable import PalmhelmKit

// O1-356：图表系列色唯一权威（家族 × 明暗）的验收：对比度、色觉模拟下的 ΔE00、热力四档、松绿兼容。
@Suite struct UsageSeriesPaletteTests {
    // MARK: 颜色数学（测试内实现：sRGB → 线性 → 色觉模拟 → XYZ → Lab → CIEDE2000）
    private func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private func rgb(_ v: UInt32) -> [Double] { [Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255].map(linear) }
    private func luminance(_ lin: [Double]) -> Double { 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2] }
    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(rgb(a)), lb = luminance(rgb(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    enum CVD: CaseIterable { case normal, protan, deutan, tritan }
    private static let matrices: [CVD: [[Double]]] = [
        .protan: [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
        .deutan: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
        .tritan: [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]],
    ]
    /// 线性 RGB 上做 Machado 2009（severity 1.0）模拟，裁剪到 [0,1]。
    private func simulate(_ v: UInt32, _ cvd: CVD) -> [Double] {
        let lin = rgb(v)
        guard let m = Self.matrices[cvd] else { return lin }
        return (0..<3).map { r in min(max(m[r][0] * lin[0] + m[r][1] * lin[1] + m[r][2] * lin[2], 0), 1) }
    }
    private func lab(_ lin: [Double]) -> (Double, Double, Double) {
        let x = (0.4124564 * lin[0] + 0.3575761 * lin[1] + 0.1804375 * lin[2]) / 0.95047
        let y = 0.2126729 * lin[0] + 0.7151522 * lin[1] + 0.0721750 * lin[2]
        let z = (0.0193339 * lin[0] + 0.1191920 * lin[1] + 0.9503041 * lin[2]) / 1.08883
        func f(_ t: Double) -> Double { t > pow(6.0 / 29, 3) ? cbrt(t) : t / (3 * pow(6.0 / 29, 2)) + 4.0 / 29 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
    /// CIEDE2000（Sharma 2005，kL = kC = kH = 1）。
    static func deltaE00(_ l1: (Double, Double, Double), _ l2: (Double, Double, Double)) -> Double {
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        func deg(_ r: Double) -> Double { let d = r * 180 / .pi; return d < 0 ? d + 360 : d }
        let (L1, a1, b1) = l1, (L2, a2, b2) = l2
        let C1 = (a1 * a1 + b1 * b1).squareRoot(), C2 = (a2 * a2 + b2 * b2).squareRoot()
        let Cb = (C1 + C2) / 2
        let G = 0.5 * (1 - (pow(Cb, 7) / (pow(Cb, 7) + pow(25, 7))).squareRoot())
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = (a1p * a1p + b1 * b1).squareRoot(), C2p = (a2p * a2p + b2 * b2).squareRoot()
        let h1p = (C1p == 0 && a1p == 0) ? 0 : deg(atan2(b1, a1p))
        let h2p = (C2p == 0 && a2p == 0) ? 0 : deg(atan2(b2, a2p))
        let dLp = L2 - L1, dCp = C2p - C1p
        var dhp = 0.0
        if C1p * C2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (C1p * C2p).squareRoot() * sin(rad(dhp / 2))
        let Lbp = (L1 + L2) / 2, Cbp = (C1p + C2p) / 2
        var hbp = h1p + h2p
        if C1p * C2p == 0 { hbp = h1p + h2p } else if abs(h1p - h2p) <= 180 { hbp = (h1p + h2p) / 2 } else { hbp = h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2 }
        let T = 1 - 0.17 * cos(rad(hbp - 30)) + 0.24 * cos(rad(2 * hbp)) + 0.32 * cos(rad(3 * hbp + 6)) - 0.20 * cos(rad(4 * hbp - 63))
        let dTheta = 30 * exp(-pow((hbp - 275) / 25, 2))
        let RC = 2 * (pow(Cbp, 7) / (pow(Cbp, 7) + pow(25, 7))).squareRoot()
        let SL = 1 + 0.015 * pow(Lbp - 50, 2) / (20 + pow(Lbp - 50, 2)).squareRoot()
        let SC = 1 + 0.045 * Cbp, SH = 1 + 0.015 * Cbp * T
        let RT = -sin(rad(2 * dTheta)) * RC
        let tL = dLp / SL, tC = dCp / SC, tH = dHp / SH
        return (tL * tL + tC * tC + tH * tH + RT * tC * tH).squareRoot()
    }

    // MARK: 算法自检（Sharma 2005 参考对，黑白对比）
    @Test func colorMathMatchesTheReferences() {
        let d = Self.deltaE00((50, 2.6772, -79.7751), (50, 0, -82.7485))
        #expect(abs(d - 2.0425) < 0.001, "CIEDE2000 参考值 2.0425，实际 \(d)")
        #expect(abs(contrast(0xFFFFFF, 0x000000) - 21) < 0.001, "黑白对比 21")
    }

    // MARK: 各家族：accent 同源、对比度、色觉 ΔE00
    @Test func paletteS0IsTheFamilyAccentInBothSchemes() {
        for family in PalmhelmThemeFamily.allCases {
            #expect(UsageSeriesColor.palette(family, dark: false).s0 == PalmhelmThemeTokens.tokens(family).light.accent, "\(family) 浅色 S0")
            #expect(UsageSeriesColor.palette(family, dark: true).s0 == PalmhelmThemeTokens.tokens(family).dark.accent, "\(family) 深色 S0")
            #expect(UsageSeriesColor.palette(family, dark: false).card == PalmhelmThemeTokens.tokens(family).light.card)
            #expect(UsageSeriesColor.palette(family, dark: true).card2 == PalmhelmThemeTokens.tokens(family).dark.card2)
        }
    }

    @Test func seriesMeetNonTextContrastOnCardAndCard2() {
        var minimum = Double.infinity
        for family in PalmhelmThemeFamily.allCases {
            for dark in [false, true] {
                let p = UsageSeriesColor.palette(family, dark: dark)
                for c in [p.s0, p.s1, p.s2, p.other] { for bg in [p.card, p.card2] { minimum = min(minimum, contrast(c, bg)) } }
            }
        }
        #expect(minimum >= 3, "最低对比度 \(minimum)")
    }

    @Test func everyPairIsDistinguishableUnderNormalAndDichromacy() {
        var minimum = Double.infinity
        var count = 0
        for family in PalmhelmThemeFamily.allCases {
            for dark in [false, true] {
                let p = UsageSeriesColor.palette(family, dark: dark)
                let colors = [p.s0, p.s1, p.s2, p.other]
                for cvd in CVD.allCases {
                    for i in colors.indices { for j in colors.indices where i < j {
                        let de = Self.deltaE00(lab(simulate(colors[i], cvd)), lab(simulate(colors[j], cvd)))
                        minimum = min(minimum, de); count += 1
                    } }
                }
            }
        }
        #expect(count == PalmhelmThemeFamily.allCases.count * 2 * 4 * 6, "应有 \(PalmhelmThemeFamily.allCases.count * 2 * 4 * 6) 个配对，实际 \(count)")
        #expect(minimum >= 10, "最小 ΔE00 \(minimum)（正常 + 三类模拟）")
    }

    // MARK: 热力四档
    @Test func heatLevelsStayVisibleAgainstTheBackground() {
        for family in PalmhelmThemeFamily.allCases {
            for dark in [false, true] {
                let p = UsageSeriesColor.palette(family, dark: dark)
                for c in UsageSeriesColor.heatLevels(family, dark: dark) { for bg in [p.card, p.card2] { #expect(contrast(c, bg) >= 3, "\(family) 热力 \(String(c, radix: 16)) 对比度不足") } }
            }
        }
    }

    @Test func heatLevelsAreQuartilesOfTheMaximum() {
        #expect(UsageSeriesColor.heatLevel(value: 0, maxValue: 100) == 0)
        #expect(UsageSeriesColor.heatLevel(value: 1, maxValue: 100) == 1)
        #expect(UsageSeriesColor.heatLevel(value: 25, maxValue: 100) == 1)
        #expect(UsageSeriesColor.heatLevel(value: 26, maxValue: 100) == 2)
        #expect(UsageSeriesColor.heatLevel(value: 75, maxValue: 100) == 3)
        #expect(UsageSeriesColor.heatLevel(value: 100, maxValue: 100) == 4)
        #expect(UsageSeriesColor.heatLevel(value: 5, maxValue: 0) == 4, "最大值为 0 时不除零")
    }

    // MARK: 索引与其他灰
    @Test func indicesMapToSeriesAndOverflowToOther() {
        let p = UsageSeriesColor.palette(.clearBlue, dark: false)
        #expect(UsageSeriesColor.hex(0, family: .clearBlue, dark: false) == p.s0)
        #expect(UsageSeriesColor.hex(2, family: .clearBlue, dark: false) == p.s2)
        #expect(UsageSeriesColor.hex(3, family: .clearBlue, dark: false) == p.other)
        #expect(UsageSeriesColor.hex(nil, family: .clearBlue, dark: false) == p.other)
        #expect(UsageSeriesColor.hex(-1, family: .clearBlue, dark: false) == p.other)
    }

    // MARK: 松绿兼容（只改显示名）
    @Test func greenFamilyKeepsItsRawValueAndIsNamedSongLü() throws {
        #expect(PalmhelmThemeFamily.qoderGreen.rawValue == "qoderGreen")
        #expect(PalmhelmThemeFamily.qoderGreen.label == "松绿")
        let data = try JSONEncoder().encode(PalmhelmThemeFamily.qoderGreen)
        #expect(String(decoding: data, as: UTF8.self) == "\"qoderGreen\"")
        #expect(try JSONDecoder().decode(PalmhelmThemeFamily.self, from: Data("\"qoderGreen\"".utf8)) == .qoderGreen)
        #expect(PalmhelmThemeFamily(rawValue: "qoderGreen") == .qoderGreen, "旧偏好读取不变")
    }
}
