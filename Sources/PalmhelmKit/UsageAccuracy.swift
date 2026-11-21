import Foundation

/// 用量准确性包（#4）的展示文案规则：覆盖进度、TTL 拆分与未知标记、单价详情（含推导规则）。纯函数，Mac 与 iOS 共用。
public enum UsageAccuracy {
    /// 覆盖进度提示；已全部读完且没有重建时返回 nil（不打扰）。
    /// 枚举没走完 → 「已扫描 N 个，仍在发现记录」（不给百分比，不把少量已读文件当成全天总量）；走完但还在补齐 → 百分比；重建中 → 说明显示的是旧快照。
    public static func coverageLine(_ c: UsageCoverage?) -> String? {
        guard let c else { return nil }
        if c.refresh == "failed" {
            let when = c.lastSuccessT.map { KitL10n.formatted(Date(timeIntervalSince1970: Double($0) / 1000), date: .abbreviated, time: .shortened) }
            return when.map { KitL10n.format("最近一次更新失败，显示的是 %@ 的数据，稍后自动重试", $0) } ?? KitL10n.string("最近一次更新失败，显示的是上次确认的数据，稍后自动重试")
        }
        if c.rebuilding { return KitL10n.string("时区或价格分档变化，正在后台重算；当前显示的是旧快照") }
        if c.enumeration != "complete" { return KitL10n.format("已扫描 %lld 个，仍在发现记录", c.filesIndexed) }
        if c.filesIndexed < c.filesTotal || (c.percent ?? 100) < 100 {
            let p = c.percent.map { "\($0)%" } ?? ""
            return KitL10n.format("正在补齐用量记录 %@（已读完 %lld / %lld 个文件）", p, c.filesIndexed, c.filesTotal)
        }
        return nil
    }

    /// 质量标记：「扫描有缺口」（本机记录没读全）与「价格有不确定部分」（TTL 未知等按假设计价）是两回事，分开显示。
    public static func badges(_ t: UsageEstimateTotals, scanPartial: Bool) -> [String] {
        var out: [String] = []
        if scanPartial { out.append(KitL10n.string("扫描有缺口")) }
        if (t.ttlUnknownTokens ?? 0) > 0 { out.append(KitL10n.string("价格有不确定部分")) }
        if t.hasUnpriced { out.append(KitL10n.string("有未报价")) }
        if t.priceStale { out.append(KitL10n.string("价格可能过期")) }
        return out
    }

    /// TTL 档位名（按来源）：Claude 5m / 1h；Codex（OpenAI）30m / 12h；其他来源没有可核实的档位名。
    public static func ttlLabels(source: String) -> (short: String, long: String)? {
        switch source { case "claude": ("5m", "1h"); case "codex": ("30m", "12h"); default: nil }
    }

    /// 缓存写入的 TTL 拆分行；没有任何分项（旧 Bridge）或写入为 0 时 nil。例：「缓存写入 5m 100 · 1h 200 · TTL 未知 20」
    public static func ttlLine(source: String, tokens t: UsageEstimateTokens) -> String? {
        guard t.cacheWrite > 0, t.cacheWriteShort != nil || t.cacheWriteLong != nil || t.cacheWriteUnknown != nil else { return nil }
        let l = ttlLabels(source: source) ?? (short: KitL10n.string("短"), long: KitL10n.string("长"))
        var parts: [String] = []
        if let s = t.cacheWriteShort, s > 0 { parts.append("\(l.short) \(KitL10n.number(s))") }
        if let g = t.cacheWriteLong, g > 0 { parts.append("\(l.long) \(KitL10n.number(g))") }
        if let u = t.cacheWriteUnknown, u > 0 { parts.append(KitL10n.format("TTL 未知 %@", KitL10n.number(u))) }
        return parts.isEmpty ? nil : KitL10n.string("kit.cache_write.space", default: "缓存写入 ") + parts.joined(separator: " · ")
    }

    /// 这一行含 TTL 未知的写入（要显示「TTL 未知」标记）。
    public static func hasUnknownTTL(_ r: UsageEstimateRow) -> Bool {
        (r.tokens.cacheWriteUnknown ?? 0) > 0 || r.reasons.contains("cache_ttl_unknown")
    }

    /// 单价详情里长 TTL 写价那一行：来源是推导规则时注明「按规则推导」与规则来源 / asOf；规则表里查不到时只说「按规则推导」。
    public static func longWriteLine(source: String, band b: UsageBand, rules: [UsageCacheLongRule]?) -> String? {
        guard let price = b.cacheWriteLong else { return nil }
        let l = ttlLabels(source: source)?.long ?? KitL10n.string("长 TTL")
        let p = String(format: "$%.4g", price)
        guard b.cacheWriteLongSource == "rule" else { return KitL10n.format("%@ 写 %@ / 百万（价格表）", l, p) }
        if let r = rules?.first {
            return KitL10n.format("%@ 写 %@ / 百万（按规则推导：%@× 输入价；来源 %@，%@）", l, p, KitL10n.number(r.multiplier), r.source, r.asOf)
        }
        return KitL10n.format("%@ 写 %@ / 百万（按规则推导）", l, p)
    }

    /// 一行的单价详情（Mac 悬停 / 通用文本）：每个用到的档的四项价 + 长 TTL 写价（含推导规则来源）+ 价格口径说明。
    public static func priceDetail(_ r: UsageEstimateRow, rules: [UsageCacheLongRule]?) -> String {
        func p(_ v: Double?) -> String { v.map { String(format: "%g", $0) } ?? KitL10n.string("未提供") }
        var lines: [String] = []
        for b in r.usedBands {
            lines.append((b.above == 0 ? KitL10n.string("基础价") : KitL10n.format("上下文超过 %@ token", KitL10n.number(b.above))) + KitL10n.format("：输入 %@ · 输出 %@ · 缓存读 %@ · 缓存写 %@", p(b.input), p(b.output), p(b.cacheRead), p(b.cacheWrite)) + (ttlLabels(source: r.source).map { KitL10n.format("（%@）", $0.short) } ?? ""))
            if let l = longWriteLine(source: r.source, band: b, rules: rules) { lines.append(l) }
        }
        for n in r.notes ?? [] { lines.append(UsageCopy.reason(n)) }
        return lines.isEmpty ? KitL10n.string("没有可显示的单价（未报价）") : lines.joined(separator: "\n")
    }

    /// 价格口径说明（定价区块的 notes）。
    public static func pricingNote(_ code: String) -> String? {
        switch code {
        case "inference_geo_us_x1_1_when_logged": KitL10n.string("日志里标明推理地域为 US 时，所有价格按 1.1 倍计")
        case "inference_geo_global_assumed_otherwise": KitL10n.string("日志读不到推理地域时按全球价计算")
        default: nil
        }
    }
}
