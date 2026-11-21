import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct QuotaAccountsTests {
    private let now = Date(timeIntervalSince1970: 1_792_400_000) // 固定时刻
    private var nowMs: Int { Int(now.timeIntervalSince1970 * 1000) }

    @Test func oauthDiagnosticsAndWindowEvidenceAreSafeAndBackwardCompatible() throws {
        let data = Data(#"{"accounts":[],"claudeExperimental":{"enabled":true,"lastFailure":{"reason":"token_expired","at":1792400000000}}}"#.utf8)
        let response = try JSONDecoder().decode(AccountsResponse.self, from: data)
        #expect(response.claudeExperimental?.enabled == true)
        #expect(response.claudeExperimental?.lastFailure?.reason == "token_expired")
        #expect(try JSONDecoder().decode(AccountsResponse.self, from: Data(#"{"accounts":[]}"#.utf8)).claudeExperimental == nil)
        #expect(QuotaCopy.claudeFailureText("http_401").contains("401"))
        #expect(QuotaCopy.claudeFailureText("/secret/path") == "未知错误类别")
        #expect(QuotaCopy.claudeFailureText("token_expired").contains("过期"))
        let w = AccountWindow(id: "a", source: "claude_oauth_usage", observedAt: nowMs)
        #expect(QuotaCopy.windowEvidence(w, time: { _ in "10:00" }) == "OAuth 额度查询 · 10:00")
        #expect(QuotaCopy.windowEvidence(AccountWindow(id: "a", source: "SECRET"), time: { _ in "" }) == nil)
        #expect(QuotaCopy.windowEvidence(AccountWindow(id: "a", source: "claude_statusline", observedAt: Int.max), time: { _ in "bad" }) == "状态行")
    }

    @Test func experimentalClaudePlanAndFableUseSharedCopyWithoutGuessingMultiplier() throws {
        let json = #"{"provider":"claude","accountId":"a","plan":"max","billingMode":"subscription","source":"claude_oauth_usage","observedAt":1792400000000,"status":"ok","windows":[{"id":"seven_day:fable","label":"Fable","usedPercent":23,"windowMins":10080,"resetAt":1792500000000}]}"#
        var a = try JSONDecoder().decode(AccountSnapshot.self, from: Data(json.utf8))
        #expect(QuotaCopy.planTitle(a) == "Max")
        #expect(QuotaCopy.windowTitle(a.windows![0]) == "Fable · 7 天")
        #expect(QuotaCopy.shortWindowTitle(a.windows![0]) == "Fable · 7 天")
        for (plan, title) in [("pro", "Pro"), ("team", "Team"), ("enterprise", "Enterprise"), ("max_20x", "Max 20x"), ("max_5x", "Max 5x"), ("person@example.test", "套餐未知")] {
            a.plan = plan
            #expect(QuotaCopy.planTitle(a) == title)
        }
        a.plan = "max"; a.billingMode = nil; a.windows = nil
        #expect(QuotaCopy.planTitle(a) == "套餐未知")
        #expect(QuotaCopy.displayAccount(a, now: now).windows == nil)
    }

    @Test func codexPlanTitlesUseTheCompleteWhitelist() {
        let titles = [
            "free": "Free", "go": "Go", "plus": "Plus", "prolite": "Pro 100", "pro": "Pro 200", "promax": "Pro 500",
            "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu",
            "self_serve_business_prolite": "self_serve_business_prolite", "self_serve_business_usage_based": "self_serve_business_usage_based",
            "ent26": "ent26", "enterprise_cbp_automation": "enterprise_cbp_automation", "enterprise_cbp_usage_based": "enterprise_cbp_usage_based",
            "edu_plus": "edu_plus", "edu_pro": "edu_pro", "sci": "sci", "sci_plus": "sci_plus", "unknown": "套餐未知",
        ]
        for (plan, title) in titles {
            let a = AccountSnapshot(provider: "codex", accountId: "a", plan: plan, billingMode: "subscription", source: "codex_app_server", status: "ok")
            #expect(QuotaCopy.planTitle(a) == title)
        }
        for plan in ["future_plan", "person@example.test", "/private/auth.json", "sk-secret"] {
            let a = AccountSnapshot(provider: "codex", accountId: "a", plan: plan, billingMode: "subscription", source: "codex_app_server", status: "ok")
            #expect(QuotaCopy.planTitle(a) == "套餐未知")
        }
    }

    @Test func apiWinsOverOldPlanAndWindowsWithoutHidingErrors() throws {
        let json = #"{"provider":"codex","accountId":"unidentified","billingMode":"api","plan":"pro","windows":[{"id":"old","usedPercent":99,"windowMins":300}],"source":"codex_app_server","observedAt":1,"status":"stale","errorCode":"timeout"}"#
        let raw = try JSONDecoder().decode(AccountSnapshot.self, from: Data(json.utf8))
        let a = QuotaCopy.displayAccount(raw, now: now)
        #expect(QuotaCopy.planTitle(a) == "API")
        #expect(a.windows == nil)
        #expect(a.observedAt == 1 && a.status == "stale")
        #expect(QuotaCopy.note(a, now: now, connected: true, refreshError: nil, observedText: { _ in "10:00" })?.contains("超时") == true)
        #expect(try JSONDecoder().decode(AccountSnapshot.self, from: JSONEncoder().encode(a)) == a)
    }

    @Test func missingOrUnknownBillingModeKeepsOldBridgeWindows() throws {
        let json = #"{"provider":"codex","accountId":"a","plan":"plus","windows":[{"id":"old","usedPercent":42,"windowMins":300}],"source":"codex_app_server","status":"ok"}"#
        let raw = try JSONDecoder().decode(AccountSnapshot.self, from: Data(json.utf8))
        #expect(raw.billingMode == nil)
        for mode in [nil, "unknown", "future"] as [String?] {
            var a = raw
            a.billingMode = mode
            #expect(QuotaCopy.planTitle(a) == "套餐未知")
            #expect(QuotaCopy.displayAccount(a, now: now).windows == raw.windows)
        }
        var claude = raw
        claude.provider = "claude"
        claude.plan = "max"
        #expect(QuotaCopy.planTitle(claude) == "套餐未知")
        #expect(QuotaCopy.displayAccount(claude, now: now).windows == raw.windows)
    }

    @Test func decodesOkSnapshotAndIgnoresUnknownFields() throws {
        let j = #"{"accounts":[{"provider":"codex","accountId":"acct_0123456789abcdef","plan":"plus","source":"codex_app_server","observedAt":1792400000000,"status":"ok","futureField":1,"windows":[{"id":"codex:primary","usedPercent":42,"windowMins":300,"resetAt":1792418000000,"extra":true}]}]}"#
        let r = try JSONDecoder().decode(AccountsResponse.self, from: Data(j.utf8))
        #expect(r.accounts[0].status == "ok" && r.accounts[0].windows?.first?.windowMins == 300)
        #expect(r.throttled == nil)
    }

    @Test func unknownStatusIsKeptAndNotShownAsOk() throws {
        let a = AccountSnapshot(provider: "codex", accountId: "unidentified", source: "codex_app_server", status: "brand_new")
        #expect(QuotaCopy.statusNote(a, now: now, observedText: { _ in "" }) == "状态未知（brand_new），请升级 Palmhelm 或 Bridge")
        let j = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(AccountSnapshot.self, from: j).status == "brand_new")
    }

    @Test func windowTitleFollowsServerMinutesNotHardcoded() {
        #expect(QuotaCopy.windowTitle(AccountWindow(id: "a", usedPercent: 1, windowMins: 300)) == "5 小时窗口")
        #expect(QuotaCopy.windowTitle(AccountWindow(id: "a", usedPercent: 1, windowMins: 10080)) == "7 天窗口")
        #expect(QuotaCopy.windowTitle(AccountWindow(id: "a", usedPercent: 1, windowMins: 90)) == "90 分钟窗口")
        #expect(QuotaCopy.windowTitle(AccountWindow(id: "a", usedPercent: 1)) == "窗口")
        #expect(QuotaCopy.windowTitle(AccountWindow(id: "a", label: "Other", usedPercent: 1, windowMins: 60)) == "1 小时窗口 · Other")
    }

    @Test func resetCountdownAndExpiry() {
        let future = AccountWindow(id: "a", usedPercent: 1, resetAt: nowMs + 5 * 3600_000 + 120_000)
        #expect(QuotaCopy.resetText(future, now: now) == "5 小时 2 分后重置")
        #expect(QuotaCopy.resetText(AccountWindow(id: "a", usedPercent: 1, resetAt: nowMs + 30_000), now: now) == "1 分钟后重置")
        let passed = AccountWindow(id: "a", usedPercent: 90, resetAt: nowMs - 1)
        #expect(QuotaCopy.windowExpired(passed, now: now))
        #expect(QuotaCopy.resetText(passed, now: now) == "已到重置时刻，需要刷新")
        #expect(QuotaCopy.resetText(AccountWindow(id: "a", usedPercent: 1), now: now) == "重置时间未知", "没有时间就不猜")
        #expect(!QuotaCopy.windowExpired(AccountWindow(id: "a", usedPercent: 1), now: now))
    }

    @Test func staleAfterResetDoesNotShowAsZeroOrFull() {
        let a = AccountSnapshot(provider: "codex", accountId: "acct_x", windows: [AccountWindow(id: "a", usedPercent: 90, resetAt: nowMs - 1)], source: "codex_app_server", observedAt: nowMs - 9_000_000, status: "stale")
        #expect(QuotaCopy.statusNote(a, now: now, observedText: { _ in "x" }) == "有窗口已经重置，显示的数字已过期，请刷新")
        #expect(QuotaCopy.fraction(a.windows![0]) == 0.9, "值保留，不改写成 0 或满额")
    }

    @Test func statusNotesCoverEveryState() {
        let base = { (s: String, code: String?) in AccountSnapshot(provider: "codex", accountId: "unidentified", source: "codex_app_server", status: s, errorCode: code) }
        let t = { (_: Int) in "10:00" }
        #expect(QuotaCopy.statusNote(base("ok", nil), now: now, observedText: t) == nil)
        #expect(QuotaCopy.statusNote(base("not_supported", nil), now: now, observedText: t) == "当前账户没有可读取的订阅额度（可能未安装 Codex、版本不支持，或使用的不是订阅账户）")
        #expect(QuotaCopy.statusNote(base("not_logged_in", nil), now: now, observedText: t) == "Codex 尚未登录，登录后再刷新")
        #expect(QuotaCopy.statusNote(base("error", "timeout"), now: now, observedText: t) == "读取失败：超时")
        #expect(QuotaCopy.statusNote(base("error", "some_raw_leak_xyz"), now: now, observedText: t) == "读取失败：未知错误", "未知码不回显原文")
        var off = base("stale", "exited")
        off.observedAt = 1
        #expect(QuotaCopy.statusNote(off, now: now, observedText: t) == "离线或读取失败（Codex 进程提前退出），显示 10:00 的数据")
    }

    @Test func footnoteSaysItIsNotTheSameAsEstimate() {
        #expect(QuotaCopy.footnote.contains("不是一回事") && QuotaCopy.footnote.contains("服务商"))
    }
}

// F4：旧快照上的离线 / 刷新失败 / 过期说明，数值保留、采集时间不变；跨过重置时刻要变成过期（固定快照 + 注入的 now）。
@Suite struct QuotaStaleNoteTests {
    private let t0 = Date(timeIntervalSince1970: 1_792_400_000)
    private var t0Ms: Int { Int(t0.timeIntervalSince1970 * 1000) }
    private let t = { (_: Int) in "10:00" }
    private func snap(resetIn: Int) -> AccountSnapshot {
        AccountSnapshot(provider: "codex", accountId: "acct_x", windows: [AccountWindow(id: "codex:primary", usedPercent: 42, windowMins: 300, resetAt: t0Ms + resetIn)], source: "codex_app_server", observedAt: t0Ms, status: "ok")
    }

    @Test func fixedSnapshotCrossesResetAndBecomesExpired() {
        let a = snap(resetIn: 60_000)
        #expect(QuotaCopy.note(a, now: t0, connected: true, refreshError: nil, observedText: t) == nil, "重置前：ok 不打扰")
        let later = t0.addingTimeInterval(61)
        #expect(QuotaCopy.note(a, now: later, connected: true, refreshError: nil, observedText: t) == "有窗口已经重置，显示的数字已过期，请刷新")
        #expect(QuotaCopy.resetText(a.windows![0], now: later) == "已到重置时刻，需要刷新")
        #expect(a.windows![0].usedPercent == 42, "数值不被改写成 0 或满额")
    }

    @Test func successThenRefreshFailureKeepsOldValueAndTime() {
        let a = snap(resetIn: 3_600_000)
        #expect(QuotaCopy.note(a, now: t0, connected: true, refreshError: "超时", observedText: t) == "刷新失败（超时），显示 10:00 的数据")
        #expect(QuotaCopy.note(a, now: t0, connected: false, refreshError: nil, observedText: t) == "未连接这台 Mac，显示 10:00 的数据")
        #expect(a.observedAt == t0Ms && a.windows![0].usedPercent == 42)
    }

    @Test func neverReadShowsHonestEmptyNote() {
        let none = AccountSnapshot(provider: "codex", accountId: "unidentified", source: "codex_app_server", observedAt: nil, status: "error", errorCode: "timeout")
        #expect(QuotaCopy.note(none, now: t0, connected: false, refreshError: nil, observedText: t) == "未连接这台 Mac，还没有读到过数据")
    }

    @Test func apiKeyNotSupportedCopyIsNeutral() {
        let a = AccountSnapshot(provider: "codex", accountId: "unidentified", source: "codex_app_server", status: "not_supported")
        let text = QuotaCopy.statusNote(a, now: t0, observedText: t) ?? ""
        #expect(text.contains("没有可读取的订阅额度") && !text.hasPrefix("未安装"))
    }

}

// O1-352：额度行的短窗口名。
@Suite struct QuotaShortTitleTests {
    @Test func shortTitlesDropTheWordWindow() {
        #expect(QuotaCopy.shortWindowTitle(AccountWindow(id: "bucket0", windowMins: 300)) == "5 小时")
        #expect(QuotaCopy.shortWindowTitle(AccountWindow(id: "bucket1", windowMins: 10_080)) == "7 天")
        #expect(QuotaCopy.shortWindowTitle(AccountWindow(id: "b", windowMins: 90)) == "90 分钟")
        #expect(QuotaCopy.shortWindowTitle(AccountWindow(id: "b")) == "窗口")
    }
}
