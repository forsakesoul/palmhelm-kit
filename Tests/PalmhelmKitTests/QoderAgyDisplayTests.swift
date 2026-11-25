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
}
