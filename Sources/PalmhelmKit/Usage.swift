import Foundation

// GET /v1/usage 的响应形状（Bridge docs/ops/local-api.md「用量接口」；与 Bridge chat/local-api.ts 同步）。
// 数字都是整机当前用户两类本地记录（Claude Code / Codex）的估计聚合；partial=true 表示有已知缺口，reasons/quality 说明原因。
public enum UsageWindow: String, CaseIterable, Sendable {
    case h5 = "5h", h24 = "24h", d7 = "7d", d30 = "30d"
    public var label: String { switch self { case .h5: KitL10n.string("5 小时"); case .h24: KitL10n.string("24 小时"); case .d7: KitL10n.string("7 天"); case .d30: KitL10n.string("30 天") } }
}

/// Token 类型（四桶互斥）；activity 为该桶内的用量活动记录数。
public enum TokenKind: String, CaseIterable, Sendable {
    case input, output, cacheRead, cacheWrite
    public var label: String { switch self { case .input: KitL10n.string("输入"); case .output: KitL10n.string("输出"); case .cacheRead: KitL10n.string("缓存读取"); case .cacheWrite: KitL10n.string("kit.cache_write.label", default: "缓存写入") } }
}

public struct UsageTokens: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var activity: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, activity: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.activity = activity
    }

    public subscript(kind: TokenKind) -> Int {
        switch kind { case .input: input; case .output: output; case .cacheRead: cacheRead; case .cacheWrite: cacheWrite }
    }

    public func total(_ kinds: Set<TokenKind>) -> Int { kinds.reduce(0) { $0 + self[$1] } }

    public static func + (a: UsageTokens, b: UsageTokens) -> UsageTokens {
        UsageTokens(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite, activity: a.activity + b.activity)
    }
}

public struct UsageBucket: Codable, Sendable, Equatable {
    public var t: Int // 桶起点 epoch ms（Bridge 本机时区的小时/日起点）
    public var date: String? // 仅 7d：本机日历日 "YYYY-MM-DD"
    public var byModel: [String: UsageTokens]
}

public struct UsageRecent: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var byModel: [String: UsageTokens]
}

public struct UsageRecentSet: Codable, Sendable, Equatable {
    public var today: UsageRecent
    public var d7: UsageRecent
    public var d30: UsageRecent
}

/// USD / 百万 token 的估算单价；没有条目的模型（含 other/unknown）金额未知，不是 0。
public struct UsagePrice: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var source: String?
    public var asOf: String?

    public subscript(kind: TokenKind) -> Double {
        switch kind { case .input: input; case .output: output; case .cacheRead: cacheRead; case .cacheWrite: cacheWrite }
    }
}

public struct UsageHeatmap: Codable, Sendable, Equatable {
    public var days: [String] // 7 个本机日期，旧→新
    public var activity: [[Int]] // [7][24]
}

public struct UsageAgentReport: Codable, Sendable, Equatable {
    public var candidates: Int
    public var parsed: Int
    public var complete: Int
}

public struct UsageAgents: Codable, Sendable, Equatable {
    public var claude: UsageAgentReport
    public var codex: UsageAgentReport
    public var pi: UsageAgentReport? // h11a 起才有
}

public struct UsageResponse: Codable, Sendable, Equatable {
    public var window: String
    public var timeZone: String
    public var generatedT: Int
    public var partial: Bool
    public var reasons: [String]
    public var quality: [String: Int]
    public var bucketMs: Int
    public var buckets: [UsageBucket]
    public var recent: UsageRecentSet
    public var heatmap: UsageHeatmap
    public var prices: [String: UsagePrice]
    public var agents: UsageAgents
    /// 索引覆盖进度（#4；旧 Bridge 没有）。
    public var coverage: UsageCoverage?
    /// 按请求估价区块（h11a 起；旧 Bridge 没有）。先只读 version：只有 v1 才按 v1 结构解码，其他版本不解码、只留「暂不支持」信号，
    /// 这样新版本改了结构也不会拖垮整份用量响应。金额只看这里，不再用旧 prices 自行估算。
    var estimateBox: UsageEstimateBox?
    public var estimate: UsageEstimate? { estimateBox?.v1 }
    public var estimateV1: UsageEstimate? { estimateBox?.v1 }
    public var estimateUnsupported: Bool { estimateBox != nil && estimateBox?.v1 == nil }

    enum CodingKeys: String, CodingKey {
        case window, timeZone, generatedT, partial, reasons, quality, bucketMs, buckets, recent, heatmap, prices, agents, coverage
        case estimateBox = "estimate"
    }

    /// 响应里出现过的模型（稳定顺序：按窗口内总量降序，再按名字）。
    public var models: [String] {
        var sum: [String: Int] = [:]
        for b in buckets { for (m, t) in b.byModel { sum[m, default: 0] += t.total(Set(TokenKind.allCases)) } }
        return sum.keys.sorted { (sum[$0]!, $1) > (sum[$1]!, $0) }
    }

    /// 估算金额：只对有报价的模型计；返回 (已报价金额, 是否存在未报价部分)。
    public func estimate(_ byModel: [String: UsageTokens], kinds: Set<TokenKind>) -> (usd: Double, hasUnpriced: Bool) {
        var usd = 0.0, unpriced = false
        for (m, t) in byModel {
            if let p = prices[m] { for k in kinds { usd += Double(t[k]) * p[k] / 1_000_000 } }
            else if t.total(kinds) > 0 { unpriced = true }
        }
        return (usd, unpriced)
    }
}

// ---- 估价区块（Bridge chat/local-api.ts UsageEstimate，version 1）：USD / 百万 token，时间毫秒 ----

public struct UsageEstimateTokens: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    /// 缓存写入按 TTL 拆分（#4；旧 Bridge 没有）：short = Claude 5m / OpenAI 30m，long = Claude 1h / OpenAI 12h，unknown = 无法确认 TTL（金额按短 TTL 假设）。
    public var cacheWriteShort: Int?
    public var cacheWriteLong: Int?
    public var cacheWriteUnknown: Int?
    public var total: Int { input + output + cacheRead + cacheWrite }
}

/// 一档参考单价：上下文 token 严格大于 above 时适用（0 = 基础价）；缺价为 nil（不是 0）。
public struct UsageBand: Codable, Sendable, Equatable {
    public var above: Int
    public var input: Double?
    public var output: Double?
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var reasoning: Double?
    /// 长 TTL（1h）写入单价及其来源：table = 价格表自带；rule = 按规则从输入价推导（#4）。
    public var cacheWriteLong: Double?
    public var cacheWriteLongSource: String?
}

public struct UsageEstimateRow: Codable, Sendable, Equatable, Identifiable {
    public var source: String // claude / codex / pi
    public var model: String
    public var provider: String? // 实际服务商（models.dev 公开 id）；未知为 nil
    public var referenceProvider: String? // 实际服务商未知时采用的官方参考渠道
    public var tokens: UsageEstimateTokens
    public var costUsd: Double? // 可估部分；全不可估为 nil
    public var unpricedTokens: Int
    public var reasons: [String]
    public var usedBands: [UsageBand]
    public var notes: [String]? // 价格口径说明码（tier_threshold_unverified 等）
    public var id: String { [source, model, provider ?? "", referenceProvider ?? ""].joined(separator: "\u{1F}") }
}

public struct UsageEstimateTotals: Codable, Sendable, Equatable {
    public var tokens: UsageEstimateTokens
    public var costUsd: Double?
    public var hasUnpriced: Bool
    public var partial: Bool
    public var priceStale: Bool
    public var ttlUnknownTokens: Int? // 无法确认 TTL 的缓存写入量（按短 TTL 假设计价，金额是部分）
}

public struct UsageEstimateWindow: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var rows: [UsageEstimateRow]
    public var totals: UsageEstimateTotals
}

public struct UsagePricingInfo: Codable, Sendable, Equatable {
    public var source: String
    public var origin: String // bundled / downloaded
    public var freshness: String // current / stale / excluded
    public var versionHash: String
    public var asOfT: Int
    public var lastValidatedT: Int
    public var lastCheckT: Int?
    public var autoUpdate: Bool
    public var updatePolicy: String // startup_if_older_than_3d / manual_only
    public var cacheLongRules: [UsageCacheLongRule]? // 长 TTL 写入价的推导规则（含来源与 asOf）
    public var notes: [String]? // 口径说明码：inference_geo_us_x1_1_when_logged / inference_geo_global_assumed_otherwise
}

public struct UsageCacheLongRule: Codable, Sendable, Equatable {
    public var rule: String
    public var appliesTo: String
    public var multiplier: Double
    public var source: String
    public var asOf: String
}

/// 索引覆盖进度（#4）：分母（枚举）确定前不给百分比。
public struct UsageCoverage: Codable, Sendable, Equatable {
    public var enumeration: String // complete / in_progress
    public var filesTotal: Int
    public var filesIndexed: Int
    public var bytesTotal: Int
    public var bytesIndexed: Int
    public var percent: Int?
    public var updatedT: Int
    public var backfilling: Bool
    public var rebuilding: Bool
    public var refresh: String? // ok / failed：failed = 最近一次后台扫描失败，显示的是上次确认的快照
    public var lastSuccessT: Int? // 最近一次成功批处理的时间（毫秒）
}

public struct UsageSourceState: Codable, Sendable, Equatable, Identifiable {
    public var source: String // claude / codex / pi / qoder / opencode
    public var status: String // collected / partial / found_unusable / not_found
    public var reasons: [String]
    public var id: String { source }
}

public struct UsageEstimateWindows: Codable, Sendable, Equatable {
    public var today: UsageEstimateWindow
    public var last7d: UsageEstimateWindow
    /// 近 30 天（#31）：与 last7d 同口径；旧 Bridge 没有该字段，解码为 nil。
    public var last30d: UsageEstimateWindow?
}

/// estimate 的版本边界：先读 version，只有 1 才解 v1；未知版本保留原版本号，不解其余字段。
public struct UsageEstimateBox: Codable, Sendable, Equatable {
    public let version: Int
    public let v1: UsageEstimate?
    private enum K: String, CodingKey { case version }
    public init(from decoder: Decoder) throws {
        version = try decoder.container(keyedBy: K.self).decode(Int.self, forKey: .version)
        v1 = version == 1 ? try UsageEstimate(from: decoder) : nil
    }
    public func encode(to encoder: Encoder) throws {
        if let v1 { try v1.encode(to: encoder) } else { var c = encoder.container(keyedBy: K.self); try c.encode(version, forKey: .version) }
    }
}

public struct UsageEstimate: Codable, Sendable, Equatable {
    public var version: Int
    public var windows: UsageEstimateWindows
    public var pricing: UsagePricingInfo
    public var sources: [UsageSourceState]
    public var truncated: [String]
}

/// POST /v1/usage/prices/refresh 的结果（只回固定原因码）。
public enum PriceRefreshResult: Sendable, Equatable {
    case current(UsagePricingInfo), updated(UsagePricingInfo)
    case rateLimited(retryAfterMs: Int)
    case failed(code: String) // timeout / fetch_failed / invalid_table / too_large / redirect_refused / cache_write_failed / unavailable / shutting_down / read_only / unauthorized
}

/// 用量页的人话：来源名、四态、原因码。未知码原样返回（不吞掉）。
public enum UsageCopy {
    public static func sourceName(_ s: String) -> String {
        switch s { case "claude": "Claude Code"; case "codex": "Codex"; case "pi": "Pi"; case "qoder": "Qoder"; case "agy": "Antigravity"; case "opencode": "OpenCode"; default: s }
    }
    public static func status(_ s: String) -> String {
        switch s { case "collected": KitL10n.string("已采集"); case "partial": KitL10n.string("部分采集"); case "found_unusable": KitL10n.string("已发现，暂不可用"); case "not_found": KitL10n.string("未发现记录"); default: s }
    }
    public static func reason(_ r: String) -> String {
        switch r {
        // 估价
        case "cache_ttl_unknown": KitL10n.string("缓存写入 TTL 未知，按短 TTL 假设计价（金额为部分）")
        case "cache_ttl_inconsistent": KitL10n.string("缓存 TTL 分项不合法，按未知处理")
        case "tier_threshold_unverified": KitL10n.string("长 / 短上下文分界未经官方价目页核实")
        case "region_ambiguous": KitL10n.string("参考渠道不唯一，暂不估价")
        case "zero_price_unverified": KitL10n.string("价格为 0 但未确认，不计金额")
        case "tier_insufficient": KitL10n.string("分档信息不足")
        case "price_excluded_30d": KitL10n.string("价格超过 30 天未确认，不计金额")
        case "provider_model_missing": KitL10n.string("该服务商下没有此模型的价格")
        case "model_unlisted": KitL10n.string("价格表里没有此模型")
        case "model_unknown": KitL10n.string("记录里没有可用的模型名")
        case "no_reference_channel": KitL10n.string("没有可用的官方参考价")
        case "price_missing": KitL10n.string("没有价格")
        case "price_field_missing": KitL10n.string("缺少部分单价")
        case "price_overflow": KitL10n.string("金额超出可计算范围")
        case "unit_unknown": KitL10n.string("计价单位不明")
        // 来源
        case "sqlite_not_opened": KitL10n.string("为避免改动 OpenCode 数据，未读取")
        case "wal_unverifiable": KitL10n.string("存在 WAL 状态或旁路文件，未验证")
        case "journal_present": KitL10n.string("发现 journal 文件，未读取")
        case "format_unsupported": KitL10n.string("记录格式暂不支持")
        case "sampled_tokens_zero": KitL10n.string("抽样记录 token 均为 0")
        case "tokens_all_zero": KitL10n.string("记录 token 均为 0")
        case "open_failed": KitL10n.string("打不开记录")
        case "unreadable", "unreadable_dir": KitL10n.string("记录目录不可读")
        case "absent": KitL10n.string("没有记录目录")
        case "empty": KitL10n.string("记录为空")
        case "no_recent_records": KitL10n.string("近期没有记录")
        case "schema_unknown": KitL10n.string("记录结构不认识")
        // 扫描质量
        case "truncated_files": KitL10n.string("有文件超出读取上限")
        case "budget_exhausted": KitL10n.string("本次扫描时间用完")
        case "incomplete_files": KitL10n.string("有文件未读完")
        case "changed_during_read": KitL10n.string("有文件在读取中被改动")
        case "long_line": KitL10n.string("有超长记录行被跳过")
        case "claude_inconsistent", "codex_inconsistent", "pi_inconsistent", "agy_inconsistent": KitL10n.string("有记录前后不一致，已跳过")
        case "missing_id", "pi_missing_id": KitL10n.string("有记录缺少编号，已跳过")
        case "missing_field", "pi_missing_field": KitL10n.string("有记录缺少字段，已跳过")
        case "codex_baseline_unknown": KitL10n.string("部分 Codex 会话缺少起点")
        case "codex_reset": KitL10n.string("部分 Codex 会话计数被重置")
        case "codex_cache_write_unsupported": KitL10n.string("Codex 记录不含缓存写入")
        case "overflow": KitL10n.string("有数值超出范围")
        case "truncated_models": KitL10n.string("模型太多，部分归入其他")
        // 截断
        case "rows_truncated": KitL10n.string("部分模型明细已省略，总量仍含全部")
        case "bands_omitted": KitL10n.string("单价详情已省略")
        default: r
        }
    }
    public static func refreshFailure(_ code: String) -> String {
        switch code {
        case "timeout": KitL10n.string("连接 models.dev 超时")
        case "fetch_failed": KitL10n.string("下载失败")
        case "invalid_table": KitL10n.string("下载到的价格表格式不对，已保留原来的")
        case "too_large": KitL10n.string("价格表超过大小上限")
        case "redirect_refused": KitL10n.string("被重定向，已拒绝")
        case "cache_write_failed": KitL10n.string("写入价格缓存失败")
        case "unavailable", "shutting_down": KitL10n.string("Bridge 暂时不可用")
        case "read_only": KitL10n.string("这台设备是只读，请在可控设备上更新")
        case "unauthorized": KitL10n.string("设备鉴权失效，请检查配对")
        case "unsupported": KitL10n.string("这台 Mac 的 Bridge 版本较旧，不支持更新价格")
        case "transport": KitL10n.string("连不上 Bridge，稍后再试")
        default: KitL10n.string("更新失败") // 未知码不原样外露
        }
    }
}
