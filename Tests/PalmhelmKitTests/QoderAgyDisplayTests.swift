import Foundation
import Testing
@testable import PalmhelmKit

// #124 agy 显示名与 #125 qoder 额度的展示规则。
@Suite struct QoderAgyDisplayTests {
    private let now = Date(timeIntervalSince1970: 1_792_400_000)

    @Test func agyAndQoderKindLabels() {
        #expect(ThreadIdentity.kindLabel("agy") == "Antigravity")
        #expect(ThreadIdentity.kindLabel("qodercli") == "Qoder")
        #expect(ThreadIdentity.kindLabel("claude") == "Claude")
    }

    @Test func qoderPolicyAllowsOnlyCreditsAndAddon() {
        let qoder = AccountSnapshot(provider: "qoder", accountId: "a", windows: [
            AccountWindow(id: "credits", usedPercent: 1), AccountWindow(id: "addon", usedPercent: 2),
            AccountWindow(id: "org_resource_package", usedPercent: 3),
        ], source: "qoder_statusline", status: "ok")
        #expect(QuotaWindowPolicy.windows(of: qoder).map(\.id) == ["credits", "addon"])
        #expect(!QuotaWindowPolicy.allowed(provider: "claude", AccountWindow(id: "credits")))
    }

    @Test func qoderWindowsGetNamesAndNoCycleReset() {
        let raw = AccountSnapshot(provider: "qoder", accountId: "a", windows: [
            AccountWindow(id: "credits", usedPercent: 12.5, windowMins: 0, resetAt: 0),
            AccountWindow(id: "addon", usedPercent: 40, windowMins: 0, resetAt: 253_402_214_400_000),
        ], source: "qoder_statusline", status: "ok")
        let shown = QuotaCopy.displayAccount(raw, now: now).windows ?? []
        #expect(shown.allSatisfy { $0.source == "qoder_statusline" })
        #expect(QuotaCopy.windowTitle(shown[0]) == "套餐额度")
        #expect(QuotaCopy.shortWindowTitle(shown[1]) == "加购额度")
        // 0 与 9999 年都不是重置时刻：不按周期重置，也不判成已过期。
        #expect(QuotaCopy.resetText(shown[0], now: now) == "不按周期重置")
        #expect(QuotaCopy.resetText(shown[1], now: now) == "不按周期重置")
        #expect(!QuotaCopy.windowExpired(shown[0], now: now))
        #expect(!QuotaCopy.windowExpired(shown[1], now: now))
        #expect(QuotaCopy.fraction(shown[0]) == 0.125)
        #expect(QuotaCopy.windowEvidence(shown[0], time: { _ in "" }) == "状态行")
        #expect(QuotaCopy.providerTitle("qoder") == "Qoder")
    }

    @Test func zeroResetAtIsNeverExpiredEvenWithoutDisplayPass() {
        let raw = AccountWindow(id: "credits", usedPercent: 5, resetAt: 0, source: "qoder_statusline")
        #expect(!QuotaCopy.windowExpired(raw, now: now))
        #expect(QuotaCopy.resetText(raw, now: now) == "不按周期重置")
    }

    @Test func otherProvidersKeepTheirOldText() {
        #expect(QuotaCopy.resetText(AccountWindow(id: "a", usedPercent: 1), now: now) == "重置时间未知")
        #expect(QuotaCopy.windowTitle(AccountWindow(id: "credits", usedPercent: 1)) == "窗口")
        #expect(QuotaCopy.windowTitle(AccountWindow(id: "addon", usedPercent: 1, windowMins: 300)) == "5 小时窗口")
    }

    @Test func agyPolicyAllowsOnlyFourWindows() {
        let agy = AccountSnapshot(provider: "agy", accountId: "default", windows: [
            AccountWindow(id: "gemini-5h", usedPercent: 10, windowMins: 300),
            AccountWindow(id: "gemini-weekly", usedPercent: 20, windowMins: 10080),
            AccountWindow(id: "3p-5h", usedPercent: 30, windowMins: 300),
            AccountWindow(id: "3p-weekly", usedPercent: 40, windowMins: 10080),
            AccountWindow(id: "gemini-1h", usedPercent: 50, windowMins: 60),
            AccountWindow(id: "credits", usedPercent: 60),
            AccountWindow(id: "five_hour:primary", usedPercent: 70, windowMins: 300),
        ], source: "agy_statusline", status: "ok")
        #expect(QuotaWindowPolicy.windows(of: agy).map(\.id) == ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
        #expect(!QuotaWindowPolicy.allowed(provider: "claude", AccountWindow(id: "gemini-5h", windowMins: 300)))
        #expect(!QuotaWindowPolicy.allowed(provider: "qoder", AccountWindow(id: "gemini-5h", windowMins: 300)))
    }

    @Test func agyDisplayAccountFillsSourceCrossesResetAndTitles() {
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let raw = AccountSnapshot(provider: "agy", accountId: "default", plan: "Google AI Pro", windows: [
            AccountWindow(id: "gemini-5h", usedPercent: 25, windowMins: 300, resetAt: nowMs + 3_600_000, observedAt: nowMs - 60_000),
            AccountWindow(id: "gemini-weekly", usedPercent: 80, windowMins: 10080, resetAt: nowMs - 1_000),
            AccountWindow(id: "3p-5h", usedPercent: 40, windowMins: 300, resetAt: nil),
            AccountWindow(id: "3p-weekly", usedPercent: 60, windowMins: 10080, resetAt: nowMs + 86_400_000),
        ], source: "agy_statusline", observedAt: nowMs - 60_000, status: "ok")

        let shown = QuotaCopy.displayAccount(raw, now: now).windows ?? []
        #expect(shown.count == 4)
        #expect(shown.allSatisfy { $0.source == "agy_statusline" })

        #expect(QuotaCopy.windowTitle(shown[0]) == "Gemini · 5 小时")
        #expect(QuotaCopy.shortWindowTitle(shown[0]) == "Gemini · 5 小时")
        #expect(QuotaCopy.windowTitle(shown[1]) == "Gemini · 7 天")
        #expect(QuotaCopy.shortWindowTitle(shown[1]) == "Gemini · 7 天")
        #expect(QuotaCopy.windowTitle(shown[2]) == "第三方模型 · 5 小时")
        #expect(QuotaCopy.shortWindowTitle(shown[2]) == "第三方模型 · 5 小时")
        #expect(QuotaCopy.windowTitle(shown[3]) == "第三方模型 · 7 天")
        #expect(QuotaCopy.shortWindowTitle(shown[3]) == "第三方模型 · 7 天")

        // 非 agy_statusline 来源不命中 agy 标题（避免与其他来源同名窗口碰撞）
        #expect(QuotaCopy.windowTitle(AccountWindow(id: "gemini-5h", usedPercent: 10, windowMins: 300)) == "5 小时窗口")
        #expect(QuotaCopy.shortWindowTitle(AccountWindow(id: "3p-weekly", usedPercent: 10, windowMins: 10080)) == "7 天")

        // 跨重置：隐藏旧百分比、标记 reset = true
        #expect(shown[1].usedPercent == nil)
        #expect(shown[1].reset == true)
        #expect(QuotaCopy.usedText(shown[1]) == "已重置，等待新数据")
        #expect(QuotaCopy.resetText(shown[1], now: now) == "已重置")
        #expect(QuotaCopy.fraction(shown[1]) == nil)

        // 未重置与缺少 resetAt
        #expect(shown[0].usedPercent == 25)
        #expect(shown[0].reset != true)
        #expect(shown[2].usedPercent == 40)
        #expect(QuotaCopy.resetText(shown[2], now: now) == "重置时间未知")

        #expect(QuotaCopy.windowEvidence(shown[0], time: { _ in "10:00" }) == "状态行 · 10:00")
        #expect(QuotaCopy.windowEvidence(shown[2], time: { _ in "10:00" }) == "状态行")
        #expect(QuotaCopy.providerTitle("agy") == "Antigravity")
    }

    @Test func agyStatusNotesAndTightestSelection() {
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let awaiting = AccountSnapshot(provider: "agy", accountId: "default", source: "agy_statusline", status: "awaiting_refresh")
        #expect(QuotaCopy.statusNote(awaiting, now: now, observedText: { _ in "10:00" }) == "已接入，等待 Antigravity 下次刷新状态行（在 agy 里发一条消息后会更新）")

        let stale = AccountSnapshot(provider: "agy", accountId: "default", windows: [
            AccountWindow(id: "gemini-5h", usedPercent: 30, windowMins: 300, resetAt: nowMs + 3_600_000),
        ], source: "agy_statusline", observedAt: nowMs - 2_400_000, status: "stale")
        #expect(QuotaCopy.statusNote(stale, now: now, observedText: { _ in "10:00" }) == "超过 30 分钟没有新数据（需要 Antigravity 运行并刷新状态行），显示 10:00 的数据")

        let staleExpired = AccountSnapshot(provider: "agy", accountId: "default", windows: [
            AccountWindow(id: "gemini-5h", usedPercent: 30, windowMins: 300, resetAt: nowMs - 1_000),
        ], source: "agy_statusline", observedAt: nowMs - 2_400_000, status: "stale")
        #expect(QuotaCopy.statusNote(staleExpired, now: now, observedText: { _ in "10:00" }) == "有窗口已经重置，显示的数字已过期；需要 Antigravity 运行并刷新状态行")

        // planTitle：agy 白名单（不要求 billingMode == subscription）、非白名单与 api
        #expect(QuotaCopy.planTitle(AccountSnapshot(provider: "agy", accountId: "default", plan: "Google AI Pro", source: "agy_statusline", status: "ok")) == "Google AI Pro")
        #expect(QuotaCopy.planTitle(AccountSnapshot(provider: "agy", accountId: "default", plan: "Google AI Ultra", source: "agy_statusline", status: "ok")) == "Google AI Ultra")
        #expect(QuotaCopy.planTitle(AccountSnapshot(provider: "agy", accountId: "default", plan: "Custom Plan", source: "agy_statusline", status: "ok")) == "套餐未知")
        #expect(QuotaCopy.planTitle(AccountSnapshot(provider: "agy", accountId: "default", plan: nil, source: "agy_statusline", status: "ok")) == "套餐未知")
        #expect(QuotaCopy.planTitle(AccountSnapshot(provider: "agy", accountId: "default", plan: "Google AI Pro", billingMode: "api", source: "agy_statusline", status: "ok")) == "API")

        let agyOk = AccountSnapshot(provider: "agy", accountId: "default", windows: [
            AccountWindow(id: "gemini-5h", usedPercent: 85, windowMins: 300, resetAt: nowMs + 3_600_000),
        ], source: "agy_statusline", observedAt: nowMs, status: "ok")
        let claudeOk = AccountSnapshot(provider: "claude", accountId: "c1", windows: [
            AccountWindow(id: "five_hour:primary", usedPercent: 40, windowMins: 300, resetAt: nowMs + 3_600_000),
        ], source: "claude_statusline", observedAt: nowMs, status: "ok")
        let codexOk = AccountSnapshot(provider: "codex", accountId: "x1", windows: [
            AccountWindow(id: "primary", usedPercent: 60, windowMins: 300, resetAt: nowMs + 3_600_000),
        ], source: "codex_cli", observedAt: nowMs, status: "ok")
        #expect(AccountSelection.tightest([claudeOk, codexOk, agyOk], now: now)?.id == "agy|default")
    }

    @Test func claudeCodexQoderExistingBehaviorUnchanged() {
        let nowMs = Int(now.timeIntervalSince1970 * 1000)

        // Claude：标题、文案、跨重置不变
        #expect(QuotaCopy.providerTitle("claude") == "Claude")
        let claudeAwaiting = AccountSnapshot(provider: "claude", accountId: "c1", source: "claude_statusline", status: "awaiting_refresh")
        #expect(QuotaCopy.statusNote(claudeAwaiting, now: now, observedText: { _ in "10:00" }) == "已接入，等待 Claude Code 下次刷新（发送一条消息后会更新）")
        let claudeStale = AccountSnapshot(provider: "claude", accountId: "c1", windows: [
            AccountWindow(id: "five_hour:primary", usedPercent: 20, windowMins: 300, resetAt: nowMs + 3_600_000),
        ], source: "claude_statusline", observedAt: nowMs - 2_400_000, status: "stale")
        #expect(QuotaCopy.statusNote(claudeStale, now: now, observedText: { _ in "10:00" }) == "超过 30 分钟没有新数据（需要 Claude Code 运行并刷新状态行），显示 10:00 的数据")
        let claudeExpired = QuotaCopy.displayAccount(AccountSnapshot(provider: "claude", accountId: "c1", windows: [
            AccountWindow(id: "five_hour:primary", usedPercent: 55, windowMins: 300, resetAt: nowMs - 1_000),
        ], source: "claude_statusline", status: "ok"), now: now)
        #expect(claudeExpired.windows?.first?.usedPercent == nil)
        #expect(claudeExpired.windows?.first?.reset == true)

        // Codex：标题、白名单、跨重置不隐藏旧比例、stale 文案不变
        #expect(QuotaCopy.providerTitle("codex") == "Codex")
        #expect(QuotaWindowPolicy.allowed(provider: "codex", AccountWindow(id: "p", windowMins: 300)))
        #expect(QuotaWindowPolicy.allowed(provider: "codex", AccountWindow(id: "w", windowMins: 10080)))
        #expect(!QuotaWindowPolicy.allowed(provider: "codex", AccountWindow(id: "other", windowMins: 60)))
        let codexExpired = QuotaCopy.displayAccount(AccountSnapshot(provider: "codex", accountId: "x1", windows: [
            AccountWindow(id: "p", usedPercent: 55, windowMins: 300, resetAt: nowMs - 1_000),
        ], source: "codex_cli", status: "ok"), now: now)
        #expect(codexExpired.windows?.first?.usedPercent == 55)
        #expect(codexExpired.windows?.first?.reset == nil)
        let codexStale = AccountSnapshot(provider: "codex", accountId: "x1", windows: [
            AccountWindow(id: "p", usedPercent: 20, windowMins: 300, resetAt: nowMs + 3_600_000),
        ], source: "codex_cli", observedAt: nowMs - 2_400_000, status: "stale")
        #expect(QuotaCopy.statusNote(codexStale, now: now, observedText: { _ in "10:00" }) == "离线或读取失败，显示 10:00 的数据")

        // Qoder：标题、stale 文案不变
        #expect(QuotaCopy.providerTitle("qoder") == "Qoder")
        let qoderStale = AccountSnapshot(provider: "qoder", accountId: "q1", windows: [
            AccountWindow(id: "credits", usedPercent: 10, resetAt: 0),
        ], source: "qoder_statusline", observedAt: nowMs - 2_400_000, status: "stale")
        #expect(QuotaCopy.statusNote(qoderStale, now: now, observedText: { _ in "10:00" }) == "离线或读取失败，显示 10:00 的数据")
    }
}
