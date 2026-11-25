import Foundation

// 账户额度（#26，GET /v1/accounts）：与 Bridge chat/local-api.ts 的 AccountSnapshot 同步。
// 额度来自服务商（Codex 订阅窗口），与用量的估算金额是两回事，不互相换算。未知字段忽略；状态保留原字符串（未知状态按「状态未知」显示，不当成正常）。

/// 一个订阅窗口：窗口长度与重置时间以服务端为准（缺失即 nil，不猜）。
public struct AccountWindow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String?
    public var usedPercent: Double? // 窗口已重置（reset）时省略：不沿用旧的百分比
    public var reset: Bool? // 重置时间已过去：显示「已重置，等待新数据」
    public var windowMins: Int?
    public var resetAt: Int? // epoch 毫秒
    public var source: String?
    public var observedAt: Int?
    public init(id: String, label: String? = nil, usedPercent: Double? = nil, reset: Bool? = nil, windowMins: Int? = nil, resetAt: Int? = nil, source: String? = nil, observedAt: Int? = nil) {
        self.id = id; self.label = label; self.usedPercent = usedPercent; self.reset = reset; self.windowMins = windowMins; self.resetAt = resetAt
        self.source = source; self.observedAt = observedAt
    }
}

/// 一个账户的快照。accountId 是 Bridge 本地生成的标识（核实不了身份时为 "unidentified"）；不含邮箱或认证信息。
public struct AccountSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var provider: String
    public var accountId: String
    public var label: String?
    public var plan: String?
    public var billingMode: String? // subscription / api / unknown；旧 Bridge 缺失时为未知，不清除窗口
    public var windows: [AccountWindow]?
    public var source: String
    public var observedAt: Int? // 最近一次成功采集（毫秒）；从未成功为 nil
    public var status: String // ok / stale / error / not_supported / not_logged_in / awaiting_refresh；未知值原样保留
    public var errorCode: String?
    public var retryAfterT: Int?
    /// 合并进这个账户的配置来源（#49，Bridge 的 sources[]）；旧 Bridge 没有此键时为 nil。额度只取最新一次采集，不相加。
    public var sources: [AccountSourceSummary]?
    public var id: String { provider + "|" + accountId }
    public init(provider: String, accountId: String, label: String? = nil, plan: String? = nil, billingMode: String? = nil, windows: [AccountWindow]? = nil, source: String, observedAt: Int? = nil, status: String, errorCode: String? = nil, retryAfterT: Int? = nil, sources: [AccountSourceSummary]? = nil) {
        self.provider = provider; self.accountId = accountId; self.label = label; self.plan = plan; self.windows = windows
        self.source = source; self.observedAt = observedAt; self.status = status; self.errorCode = errorCode; self.retryAfterT = retryAfterT
        self.sources = sources
        self.billingMode = billingMode
    }
}

/// 合并账户里的一个配置来源（只读）：sourceId 是 Bridge 的 HMAC 派生键，不含路径；label 为用户给的显示名。
public struct AccountSourceSummary: Codable, Sendable, Equatable, Identifiable {
    public var sourceId: String
    public var label: String?
    public var status: String
    public var observedAt: Int?
    public var id: String { sourceId }
    public init(sourceId: String, label: String? = nil, status: String, observedAt: Int? = nil) {
        self.sourceId = sourceId; self.label = label; self.status = status; self.observedAt = observedAt
    }
}

/// GET /v1/accounts 的响应。throttled：手动刷新太频繁，给的是缓存。旧 Bridge 没有这个接口（404）时调用方直接不显示。
public struct AccountsResponse: Codable, Sendable, Equatable {
    public var accounts: [AccountSnapshot]
    public var throttled: Bool?
    public var claudeExperimental: ClaudeExperimentalStatus?
    public init(accounts: [AccountSnapshot], throttled: Bool? = nil, claudeExperimental: ClaudeExperimentalStatus? = nil) { self.accounts = accounts; self.throttled = throttled; self.claudeExperimental = claudeExperimental }
}

public struct ClaudeExperimentalStatus: Codable, Sendable, Equatable {
    public struct Failure: Codable, Sendable, Equatable {
        public var reason: String
        public var at: Int
    }
    public var enabled: Bool
    public var lastFailure: Failure?
}

/// 账户额度的展示文案（纯函数，Mac 与 iOS 共用）。
public enum QuotaCopy {
    /// 套餐只用已确认的计费类别与协议枚举，不从窗口或任意上游文本猜档位。
    public static func planTitle(_ a: AccountSnapshot) -> String {
        if a.billingMode == "api" { return "API" }
        // agy 的套餐只认白名单，不回显任意上游文本；Bridge 未必给 billingMode，不要求为 subscription。
        if a.provider == "agy" {
            switch a.plan {
            case "Google AI Pro", "Google AI Ultra": return a.plan!
            default: return KitL10n.string("套餐未知")
            }
        }
        guard a.billingMode == "subscription", let plan = a.plan else { return KitL10n.string("套餐未知") }
        if a.provider == "claude" {
            switch plan {
            case "pro": return "Pro"
            case "max": return "Max" // 兼容仅提供 Max 的旧来源，不从窗口推断倍率
            case "max_5x": return "Max 5x"
            case "max_20x": return "Max 20x"
            case "team": return "Team"
            case "enterprise": return "Enterprise"
            default: return KitL10n.string("套餐未知")
            }
        }
        guard a.provider == "codex" else { return KitL10n.string("套餐未知") }
        switch plan {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "self_serve_business_prolite", "self_serve_business_usage_based",
             "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based",
             "edu_plus", "edu_pro", "sci", "sci_plus": return plan
        default: return KitL10n.string("套餐未知")
        }
    }

    /// 卡片底部固定说明：额度与估算金额是两回事。
    public static var footnote: String { KitL10n.string("额度来自服务商的订阅窗口，与上方的估算金额不是一回事，不互相换算。") }

    /// 仅固定错误类别；不回显服务端未知原文。
    public static func claudeFailureText(_ reason: String) -> String {
        switch reason {
        case "keychain_denied": return KitL10n.string("无法读取 Claude 登录钥匙串（可能未授权）")
        case "token_expired": return KitL10n.string("Claude 登录令牌已过期，请在 Claude Code 登录后重试")
        case "shape_mismatch": return KitL10n.string("返回格式不认识，实验接口可能已变化")
        case "timeout": return KitL10n.string("读取钥匙串或查询额度超时")
        case "http_error": return KitL10n.string("无法连接 Claude 额度接口")
        default:
            if reason.count == 8, reason.hasPrefix("http_"), let status = Int(reason.suffix(3)), (100...599).contains(status) { return KitL10n.format("额度接口返回 HTTP %lld", status) }
            return KitL10n.string("未知错误类别")
        }
    }

    public static func windowEvidence(_ w: AccountWindow, time: (Int) -> String) -> String? {
        let source: String
        switch w.source {
        case "claude_statusline", "qoder_statusline", "agy_statusline": source = KitL10n.string("状态行")
        case "claude_oauth_usage": source = KitL10n.string("OAuth 额度查询")
        default: return nil
        }
        guard let at = w.observedAt, at > 0, at <= 100_000_000_000_000 else { return source }
        return source + " · " + time(at)
    }

    /// 账户卡标题：只认识的 provider 给人话名字；未知的原样显示，绝不冒充成别的服务。
    public static func providerTitle(_ provider: String) -> String {
        switch provider {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "qoder": return "Qoder"
        case "agy": return "Antigravity"
        default: return provider
        }
    }
    /// 账户由多个配置来源合并时的说明（额度不相加）；只有一个来源或没有来源信息时为 nil。
    public static func sourcesNote(_ a: AccountSnapshot) -> String? {
        guard let sources = a.sources, sources.count > 1 else { return nil }
        return KitL10n.format("由 %lld 个配置目录合并而成，额度取最新一次采集，不相加", sources.count)
    }

    /// 来源的人话状态（只认固定枚举，未知原样按「状态未知」）。
    public static func sourceStatusText(_ status: String) -> String {
        switch status {
        case "ok": return KitL10n.string("正常")
        case "stale": return KitL10n.string("数据过期")
        case "error": return KitL10n.string("读取失败")
        case "awaiting_refresh": return KitL10n.string("等待刷新")
        case "not_logged_in": return KitL10n.string("未登录")
        case "not_supported": return KitL10n.string("不支持")
        default: return KitL10n.string("状态未知")
        }
    }

    /// 手动刷新太频繁时的说明。
    public static var throttledNote: String { KitL10n.string("刚刚已经刷新过，显示的是缓存（约 1 分钟后可再刷新）") }

    /// 一个窗口是否已经过了重置时刻（过了就不能再当成当前值）。
    public static func windowExpired(_ w: AccountWindow, now: Date) -> Bool {
        guard let r = w.resetAt, r > 0 else { return false }
        return Double(r) <= now.timeIntervalSince1970 * 1000
    }

    /// 共同展示层的有界防御（R4）与 Claude / Antigravity 的跨重置判断（R5）。纯函数：只看快照与当前时刻，不改服务端数据。
    /// 百分比不在 0–100 的有限数、或重置时间超出可安全换算的范围 → 该字段按未知处理（不填 0）。
    /// Claude 与 Antigravity 窗口的重置时间已过 → 隐藏旧比例，标记为已重置（「已重置，等待新数据」）；Codex 的既有过期口径不变。
    /// qoder / agy 窗口的标题与重置文案依赖这里补上的 source，调用方必须先经过 displayAccount。
    public static func displayAccount(_ a: AccountSnapshot, now: Date) -> AccountSnapshot {
        var out = a
        if a.billingMode == "api" {
            out.windows = nil
            return out
        }
        let nowMs = now.timeIntervalSince1970 * 1000
        out.windows = a.windows?.map { w in
            var x = w
            if let p = x.usedPercent, !(p.isFinite && p >= 0 && p <= 100) { x.usedPercent = nil }
            if let r = x.resetAt, !(r > 0 && r <= 100_000_000_000_000) { x.resetAt = nil }
            // qoder / agy 的额度窗口载荷里没有窗口来源：这里补上，标题与证据文案据此区分。
            if a.provider == "qoder", x.source == nil { x.source = "qoder_statusline" }
            if a.provider == "agy", x.source == nil { x.source = "agy_statusline" }
            if (a.provider == "claude" || a.provider == "agy"), let r = x.resetAt, Double(r) <= nowMs {
                x.usedPercent = nil
                x.reset = true
            }
            return x
        }
        return out
    }

    /// qoder 额度窗口没有周期长度，只按窗口 id 给名字；限定 qoder 来源，免得和其他来源的同名窗口撞上。
    private static func qoderWindowTitle(_ w: AccountWindow) -> String? {
        guard w.source == "qoder_statusline" else { return nil }
        switch w.id {
        case "credits": return KitL10n.string("套餐额度")
        case "addon": return KitL10n.string("加购额度")
        default: return nil
        }
    }

    /// agy 额度窗口按模型组与周期给名字；限定 agy 来源，免得和其他来源的同名窗口撞上。
    private static func agyWindowTitle(_ w: AccountWindow) -> String? {
        guard w.source == "agy_statusline" else { return nil }
        switch w.id {
        case "gemini-5h": return KitL10n.string("Gemini · 5 小时")
        case "gemini-weekly": return KitL10n.string("Gemini · 7 天")
        case "3p-5h": return KitL10n.string("第三方模型 · 5 小时")
        case "3p-weekly": return KitL10n.string("第三方模型 · 7 天")
        default: return nil
        }
    }

    /// 窗口名：按服务端给的窗口长度生成（不写死 5 小时 / 7 天）；没有长度就只写「窗口」。
    public static func windowTitle(_ w: AccountWindow) -> String {
        if let t = qoderWindowTitle(w) ?? agyWindowTitle(w) { return t }
        if w.id == "seven_day:fable" { return KitL10n.string("Fable · 7 天") }
        let base: String
        if let m = w.windowMins, m > 0 {
            if m % 1440 == 0 { base = KitL10n.format("%lld 天窗口", m / 1440) }
            else if m % 60 == 0 { base = KitL10n.format("%lld 小时窗口", m / 60) }
            else { base = KitL10n.format("%lld 分钟窗口", m) }
        } else { base = KitL10n.string("窗口") }
        return w.label.map { "\(base) · \($0)" } ?? base
    }

    /// 额度行的短窗口名（O1-352）：「5 小时」「7 天」；没有长度时只写「窗口」。与 windowTitle 的判定同口径，只是不带「窗口」二字。
    public static func shortWindowTitle(_ w: AccountWindow) -> String {
        if let t = qoderWindowTitle(w) ?? agyWindowTitle(w) { return t }
        if w.id == "seven_day:fable" { return KitL10n.string("Fable · 7 天") }
        if let m = w.windowMins, m > 0 {
            if m % 1440 == 0 { return KitL10n.format("%lld 天", m / 1440) }
            if m % 60 == 0 { return KitL10n.format("%lld 小时", m / 60) }
            return KitL10n.format("%lld 分钟", m)
        }
        return KitL10n.string("窗口")
    }

    /// 重置倒计时：没有重置时间 → 未知；已过 → 已到重置时刻；否则给出剩余时长。
    public static func resetText(_ w: AccountWindow, now: Date) -> String {
        if w.reset == true { return KitL10n.string("已重置") }
        // 0 不是重置时刻：qoder 的无周期窗口显示“不按周期重置”，其他来源保持“重置时间未知”。
        guard let r = w.resetAt, r > 0 else { return KitL10n.string(w.source == "qoder_statusline" ? "不按周期重置" : "重置时间未知") }
        let left = Double(r) - now.timeIntervalSince1970 * 1000
        if left <= 0 { return KitL10n.string("已到重置时刻，需要刷新") }
        let mins = Int(left / 60_000)
        if mins < 60 { return KitL10n.format("%lld 分钟后重置", max(mins, 1)) }
        if mins < 48 * 60 { return KitL10n.format("%lld 小时 %lld 分后重置", mins / 60, mins % 60) }
        return KitL10n.format("%lld 天后重置", mins / 1440)
    }

    public static func usedText(_ w: AccountWindow) -> String {
        if w.reset == true { return KitL10n.string("已重置，等待新数据") }
        guard let p = w.usedPercent else { return KitL10n.string("用量未知") }
        return KitL10n.format("已用 %lld%%", Int(p.rounded()))
    }

    /// 窗口进度条的比例（0…1）；没有百分比（已重置或未知）为 nil，不画假进度。
    public static func fraction(_ w: AccountWindow) -> Double? {
        guard w.reset != true, let p = w.usedPercent else { return nil }
        return min(max(p / 100, 0), 1)
    }

    /// 错误码的人话（只给固定码；未知码统一说「未知错误」，不回显原文）。
    public static func errorText(_ code: String?) -> String {
        switch code {
        case "timeout": KitL10n.string("超时")
        case "protocol_error": KitL10n.string("返回格式不认识（可能需要升级 Codex 或 Bridge）")
        case "upstream_error": KitL10n.string("服务商暂时没有返回额度")
        case "exited": KitL10n.string("Codex 进程提前退出")
        case "spawn_failed": KitL10n.string("无法启动 Codex")
        case "no_data": KitL10n.string("还没有读到过")
        case "account_changed": KitL10n.string("账户已切换")
        case "internal": KitL10n.string("内部错误")
        default: KitL10n.string("未知错误")
        }
    }

    /// 卡片上的说明，综合了四件事：未连接这台 Mac、本次刷新失败（客户端侧）、窗口已过重置时刻、Bridge 报告的状态。
    /// 旧快照始终保留并标注它的采集时间（observedAt）；数值不改写。没有任何需要说明的事时为 nil。
    public static func note(_ a: AccountSnapshot, now: Date, connected: Bool, refreshError: String?, observedText: (Int) -> String) -> String? {
        let when = a.observedAt.map(observedText)
        if !connected { return when.map { KitL10n.format("未连接这台 Mac，显示 %@ 的数据", $0) } ?? KitL10n.string("未连接这台 Mac，还没有读到过数据") }
        if let e = refreshError { return KitL10n.format("刷新失败（%@）", e) + (when.map { KitL10n.format("，显示 %@ 的数据", $0) } ?? "") }
        if a.status == "ok", (a.windows ?? []).contains(where: { windowExpired($0, now: now) }) { return KitL10n.string("有窗口已经重置，显示的数字已过期，请刷新") }
        return statusNote(a, now: now, observedText: observedText)
    }

    /// 账户卡顶部的状态说明；ok 且没有需要说明的事时为 nil。
    public static func statusNote(_ a: AccountSnapshot, now: Date, observedText: (Int) -> String) -> String? {
        switch a.status {
        case "ok": return nil
        case "not_supported": return KitL10n.string("当前账户没有可读取的订阅额度（可能未安装 Codex、版本不支持，或使用的不是订阅账户）")
        case "not_logged_in": return KitL10n.string("Codex 尚未登录，登录后再刷新")
        case "awaiting_refresh":
            if a.provider == "agy" { return KitL10n.string("已接入，等待 Antigravity 下次刷新状态行（在 agy 里发一条消息后会更新）") }
            return KitL10n.string("已接入，等待 Claude Code 下次刷新（发送一条消息后会更新）")
        case "stale":
            if (a.windows ?? []).contains(where: { windowExpired($0, now: now) }) {
                if a.provider == "agy" { return KitL10n.string("有窗口已经重置，显示的数字已过期；需要 Antigravity 运行并刷新状态行") }
                return KitL10n.string("有窗口已经重置，显示的数字已过期，请刷新")
            }
            if a.provider == "claude" { return KitL10n.format("超过 30 分钟没有新数据（需要 Claude Code 运行并刷新状态行），显示 %@ 的数据", a.observedAt.map(observedText) ?? KitL10n.string("上次")) }
            if a.provider == "agy" { return KitL10n.format("超过 30 分钟没有新数据（需要 Antigravity 运行并刷新状态行），显示 %@ 的数据", a.observedAt.map(observedText) ?? KitL10n.string("上次")) }
            let why = a.errorCode == nil ? "" : KitL10n.format("（%@）", errorText(a.errorCode))
            return KitL10n.format("离线或读取失败%@，显示 %@ 的数据", why, a.observedAt.map(observedText) ?? KitL10n.string("上次"))
        case "error": return KitL10n.format("读取失败：%@", errorText(a.errorCode))
        default: return KitL10n.format("状态未知（%@），请升级 Palmhelm 或 Bridge", a.status)
        }
    }
}

/// 状态行安装 / 卸载的结果（固定字段）。restored：original 恢复原值，removed 删除了我们加的键，not_ours 用户已改过未恢复，none 无需恢复。
public struct ClaudeStatuslineResult: Codable, Sendable, Equatable {
    public var ok: Bool?
    public var settings: String?
    public var restored: String?
    public var warnings: [String]?
    public var error: String?
    public init(ok: Bool? = nil, settings: String? = nil, restored: String? = nil, warnings: [String]? = nil, error: String? = nil) {
        self.ok = ok; self.settings = settings; self.restored = restored; self.warnings = warnings; self.error = error
    }
}

/// 状态行开关的响应解码（纯函数，便于测试）。只有 2xx 且 `ok == true` 才算成功；2xx 但内容不对 → error = invalid_response；
/// 非 2xx 只保留服务端的固定码（不回显任何其他字符串）；没有可用的固定码 → http_<状态码>。
public func decodeClaudeStatuslineResult(status: Int, data: Data) -> ClaudeStatuslineResult {
    let decoded = try? JSONDecoder().decode(ClaudeStatuslineResult.self, from: data)
    let code = decoded?.error.flatMap { $0.count <= 40 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? $0 : nil }
    guard (200...299).contains(status) else {
        return ClaudeStatuslineResult(ok: false, error: code ?? "http_\(status)")
    }
    guard let decoded, decoded.ok == true else {
        return ClaudeStatuslineResult(ok: false, error: "invalid_response")
    }
    return decoded
}

/// GET /v1/accounts/claude/statusline 的响应：{"installed": Bool}；内容不对返回 nil（调用方按「未知」处理，不当作未安装）。
public struct ClaudeStatuslineStatus: Codable, Sendable, Equatable {
    public var installed: Bool
}
