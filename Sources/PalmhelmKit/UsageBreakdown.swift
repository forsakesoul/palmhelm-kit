import Foundation

/// 用量柱图的数据（h11c，两端共用）：从同一响应里筛出当前窗口的桶，按「整图 token 前 3 个具名模型 + 其他」堆叠，
/// 并给出每根柱的时段标题、总量与各部分占比（余数法，和为 100，非 0 不显示 0%）。不含金额：桶里没有成本数据。
public struct UsageChartData: Sendable, Equatable {
    public struct Part: Sendable, Equatable, Identifiable {
        public let model: String? // nil = 其他（含 Bridge 的 other 聚合项）
        public let tokens: Int
        public let percent: Int
        public var id: String { model ?? "\u{1F}other" }
    }
    public struct Bar: Sendable, Equatable, Identifiable {
        public let id: Int // 桶起点 epoch ms（DST 重复小时也唯一）
        public let start: Date
        public let end: Date
        public let total: Int
        public let parts: [Part] // 只含 tokens > 0 的部分：前 3 个具名模型按系列顺序，最后是其他
        public let title: String
    }

    public let timeZone: TimeZone
    public let daily: Bool
    /// 整图前 3 个具名模型（顺序即颜色顺序）；其他统一一组。
    public let series: [String]
    public let bars: [Bar]

    public static let otherKey = "other"
    public static let seriesLimit = 3
    /// 柱宽占类目宽度的比例（分类 x 轴）：柱子居中于类目，相邻柱之间留出间隙。
    public static let barRatio = 0.7

    /// 柱子的分类 x 键：桶起点的 epoch 毫秒（DST 重复小时也唯一）。分类轴让柱子与刻度都居中于各自的类目，首尾柱子天然在绘图区内。
    public static func key(_ b: Bar) -> String { String(b.id) }

    /// 按分类键找回柱（图表点按、刻度标签）。
    public func bar(key: String) -> Bar? { bars.first { String($0.id) == key } }

    /// - Parameters: from / to 为窗口的日历日（YYYY-MM-DD，按响应时区），daily 为日桶。
    public static func make(_ r: UsageResponse, from: String, to: String, daily: Bool) -> UsageChartData {
        let tz = TimeZone(identifier: r.timeZone) ?? .current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let df = DateFormatter(); df.timeZone = tz; df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        let buckets = r.buckets.filter { b in
            let day = b.date ?? df.string(from: Date(timeIntervalSince1970: Double(b.t) / 1000))
            return day >= from && day <= to
        }.sorted { $0.t < $1.t }
        let kinds = Set(TokenKind.allCases)
        var sums: [String: Int] = [:]
        for b in buckets { for (m, t) in b.byModel where m != otherKey { sums[m, default: 0] += t.total(kinds) } }
        let series = sums.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(seriesLimit).map(\.key)

        // 同一小时标签出现两次（DST 回拨）时带上 UTC 偏移区分
        let hourLabel: (Date) -> String = { d in
            let f = DateFormatter(); f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f.string(from: d)
        }
        let starts = buckets.map { Date(timeIntervalSince1970: Double($0.t) / 1000) }
        let hourCounts = Dictionary(grouping: starts.map(hourLabel), by: { $0 }).mapValues(\.count)

        let bars: [Bar] = buckets.map { b in
            let start = Date(timeIntervalSince1970: Double(b.t) / 1000)
            let end = daily ? (cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)) : start.addingTimeInterval(Double(r.bucketMs) / 1000)
            var named = series.map { m in (m as String?, b.byModel[m]?.total(kinds) ?? 0) }
            let other = b.byModel.filter { !series.contains($0.key) }.values.reduce(0) { $0 + $1.total(kinds) }
            named.append((nil, other))
            let total = named.reduce(0) { $0 + $1.1 }
            let percents = percentages(named.map(\.1))
            let parts = zip(named, percents).filter { $0.0.1 > 0 }.map { Part(model: $0.0.0, tokens: $0.0.1, percent: $0.1) }
            let title: String
            if daily {
                let f = DateFormatter(); f.timeZone = tz; f.locale = KitL10n.formattingLocale; f.calendar = KitL10n.formattingLocale.calendar
                if KitL10n.resourceLanguage.hasPrefix("zh") { f.dateFormat = "M月d日 EEE" } else { f.setLocalizedDateFormatFromTemplate("MMMdEEE") }
                title = f.string(from: start)
            } else {
                let h = hourLabel(start), e = hourLabel(end)
                if (hourCounts[h] ?? 0) > 1 {
                    let o = DateFormatter(); o.timeZone = tz; o.locale = Locale(identifier: "en_US_POSIX"); o.dateFormat = "xxx"
                    title = KitL10n.format("%@–%@（UTC%@）", h, e, o.string(from: start))
                } else { title = "\(h)–\(e)" }
            }
            return Bar(id: b.t, start: start, end: end, total: total, parts: parts, title: title)
        }
        return UsageChartData(timeZone: tz, daily: daily, series: series, bars: bars)
    }

    /// 选中位置 → 所在的桶（半开区间 [start, end)）。
    public func bar(at date: Date) -> Bar? { bars.first { date >= $0.start && date < $0.end } }

    /// 余数法百分比：和为 100（全 0 时全 0）；非 0 的项至少 1%，从最大项扣回，保持和为 100。
    public static func percentages(_ values: [Int]) -> [Int] {
        let total = values.reduce(0, +)
        guard total > 0 else { return values.map { _ in 0 } }
        let raw = values.map { Double($0) * 100 / Double(total) }
        var floor = raw.map { Int($0) }
        var left = 100 - floor.reduce(0, +)
        for i in raw.indices.sorted(by: { (raw[$0] - Double(floor[$0]), -$0) > (raw[$1] - Double(floor[$1]), -$1) }) where left > 0 { floor[i] += 1; left -= 1 }
        for i in values.indices where values[i] > 0 && floor[i] == 0 {
            if let j = floor.indices.max(by: { floor[$0] < floor[$1] }), floor[j] > 1 { floor[j] -= 1; floor[i] = 1 }
        }
        return floor
    }
}

/// 用量图的唯一配色权威（O1-356）：每个主题家族 × 明暗各一组「前三个具名模型 + 其他灰」。
/// S0 直接是该家族的 accent（与 `PalmhelmThemeTokens` 同源），S1 / S2 为邻近色并拉开明度；其他是中性灰（聚合项，不作未知 / 未读 / 0 的替身）。
/// 顺序与 `UsageChartData.series` 一致；超出索引或 nil 为其他。主题切换不重排模型、不改数据。
public enum UsageSeriesColor {
    /// 一组系列色（0xRRGGBB）。S0 / card / card2 直接来自 `PalmhelmThemeTokens` 的同一明暗 swatch（不另存副本，O1-359 R3）；
    /// S1 / S2 / 其他只在这里保留。
    public struct Palette: Sendable, Equatable {
        public let s0: UInt32, s1: UInt32, s2: UInt32, other: UInt32
        public let card: UInt32, card2: UInt32
    }

    /// 一组配色：S0 与 card / card2 取主题 token，S1 / S2 / 其他取本表（O1-356 规格）。
    public static func palette(_ family: PalmhelmThemeFamily, dark: Bool) -> Palette {
        let sw = dark ? PalmhelmThemeTokens.tokens(family).dark : PalmhelmThemeTokens.tokens(family).light
        let rest: (s1: UInt32, s2: UInt32, other: UInt32)
        switch (family, dark) {
        case (.clearBlue, false): rest = (0x13365F, 0x1B8CAF, 0x68717A)
        case (.clearBlue, true): rest = (0x627AAB, 0xD1F1F0, 0xA1A6AD)
        case (.warmOrange, false): rest = (0x4C231A, 0xA97A69, 0x68717A)
        case (.warmOrange, true): rest = (0xB57865, 0xFFE0BC, 0xA1A6AD)
        case (.qoderGreen, false): rest = (0x132E24, 0x4F8B58, 0x68717A)
        case (.qoderGreen, true): rest = (0x3D8464, 0xD4EBC9, 0xA1A6AD)
        case (.deepSea, false): rest = (0x0B2A36, 0x3E8FA3, 0x68717A)
        case (.deepSea, true): rest = (0x4C8597, 0xD3EEF2, 0x9A9FA6)
        }
        return Palette(s0: sw.accent, s1: rest.s1, s2: rest.s2, other: rest.other, card: sw.card, card2: sw.card2)
    }

    /// 系列序号（0..<3）→ 色值；nil 或超出为其他。
    public static func hex(_ index: Int?, family: PalmhelmThemeFamily, dark: Bool) -> UInt32 {
        let p = palette(family, dark: dark)
        switch index {
        case 0?: return p.s0
        case 1?: return p.s1
        case 2?: return p.s2
        default: return p.other
        }
    }

    /// 热力图四档（0 = 最低，3 = 最高；O1-356 规格的不透明 sRGB 色）。zero 留 card2，不在此表内。
    public static func heatLevels(_ family: PalmhelmThemeFamily, dark: Bool) -> [UInt32] {
        switch (family, dark) {
        case (.clearBlue, false): [0x627BCE, 0x5371CC, 0x4167C9, 0x245AC7]
        case (.clearBlue, true): [0x6683BA, 0x7596D4, 0x81A6EB, 0x8CB4FF]
        case (.warmOrange, false): [0xBD6558, 0xBA5A4A, 0xB84D39, 0xB53C1D]
        case (.warmOrange, true): [0xB46E59, 0xD17F65, 0xE98D6F, 0xFF9A78]
        case (.qoderGreen, false): [0x6F8478, 0x5E786A, 0x486B58, 0x255A41]
        case (.qoderGreen, true): [0x658859, 0x759D67, 0x83B073, 0x8FC07E]
        case (.deepSea, false): [0x668693, 0x537786, 0x3C6576, 0x1A4A5E]
        case (.deepSea, true): [0x5F919F, 0x6AA1B1, 0x74B2C4, 0x7FC3D6]
        }
    }

    /// 热力格的档位（1…4）：按最大值的四分位定档；0 表示没有活动（由调用方画 card2）。
    public static func heatLevel(value: Int, maxValue: Int) -> Int {
        guard value > 0 else { return 0 }
        let m = max(1, maxValue)
        let t = Double(value) / Double(m)
        switch t {
        case ...0.25: return 1
        case ...0.5: return 2
        case ...0.75: return 3
        default: return 4
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI
extension UsageSeriesColor {
    /// 当前家族的系列色（随系统明暗切换）。family 必须显式传入，不提供回退默认。
    public static func color(_ index: Int?, family: PalmhelmThemeFamily) -> Color {
        PalmhelmIdentityPalette.adaptive(light: hex(index, family: family, dark: false), dark: hex(index, family: family, dark: true))
    }

    /// 热力格颜色（档位 0…4；0 为 card2，1…4 为四档）。
    public static func heatColor(level: Int, family: PalmhelmThemeFamily) -> Color {
        guard level >= 1 else { return PalmhelmIdentityPalette.adaptive(light: palette(family, dark: false).card2, dark: palette(family, dark: true).card2) }
        let light = heatLevels(family, dark: false), dark = heatLevels(family, dark: true)
        let i = min(max(level, 1), 4) - 1
        return PalmhelmIdentityPalette.adaptive(light: light[i], dark: dark[i])
    }
}
#endif
