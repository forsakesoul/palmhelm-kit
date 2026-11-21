import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct UsageAccuracyTests {
    private func cov(_ enumeration: String = "complete", total: Int = 10, indexed: Int = 10, percent: Int? = 100, backfilling: Bool = false, rebuilding: Bool = false, refresh: String? = nil, lastSuccessT: Int? = nil) -> UsageCoverage {
        UsageCoverage(enumeration: enumeration, filesTotal: total, filesIndexed: indexed, bytesTotal: 100, bytesIndexed: 100, percent: percent, updatedT: 0, backfilling: backfilling, rebuilding: rebuilding, refresh: refresh, lastSuccessT: lastSuccessT)
    }
    @Test func coverageLineStatesAreHonest() {
        #expect(UsageAccuracy.coverageLine(nil) == nil, "旧 Bridge：不显示")
        #expect(UsageAccuracy.coverageLine(cov()) == nil, "全部读完：不打扰")
        #expect(UsageAccuracy.coverageLine(cov("in_progress", total: 40, indexed: 12, percent: nil)) == "已扫描 12 个，仍在发现记录", "枚举没走完：不给百分比")
        #expect(UsageAccuracy.coverageLine(cov(total: 684, indexed: 171, percent: 25, backfilling: true))!.contains("25%"))
        #expect(UsageAccuracy.coverageLine(cov(rebuilding: true))!.contains("旧快照"))
        // 后台扫描失败：不能因为旧快照读完了就不打扰 / 显示 100%，要说明失败与上次成功时间，且优先于其他提示
        let failed = UsageAccuracy.coverageLine(cov(percent: nil, rebuilding: true, refresh: "failed", lastSuccessT: 1_792_411_200_000))!
        #expect(failed.contains("更新失败") && failed.contains("稍后自动重试") && !failed.contains("100%"))
        #expect(UsageAccuracy.coverageLine(cov(refresh: "failed"))!.contains("上次确认的"), "没有成功时间时不编造")
        #expect(UsageAccuracy.coverageLine(cov(refresh: "ok", lastSuccessT: 1)) == nil, "恢复后不再提示")
    }

    private func totals(partial: Bool = false, ttl: Int? = nil, unpriced: Bool = false, stale: Bool = false) -> UsageEstimateTotals {
        UsageEstimateTotals(tokens: UsageEstimateTokens(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), costUsd: 1, hasUnpriced: unpriced, partial: partial, priceStale: stale, ttlUnknownTokens: ttl)
    }
    @Test func badgesSeparateScanGapFromPriceUncertainty() {
        #expect(UsageAccuracy.badges(totals(), scanPartial: false).isEmpty)
        #expect(UsageAccuracy.badges(totals(partial: true), scanPartial: true) == ["扫描有缺口"], "只有扫描缺口，不说价格不确定")
        #expect(UsageAccuracy.badges(totals(partial: true, ttl: 5), scanPartial: false) == ["价格有不确定部分"], "只有 TTL 未知，不说扫描有缺口")
        #expect(UsageAccuracy.badges(totals(partial: true, ttl: 5, unpriced: true, stale: true), scanPartial: true) == ["扫描有缺口", "价格有不确定部分", "有未报价", "价格可能过期"])
    }
    @Test func coverageDecodesRefreshFieldsAndOldBridgeWithout() throws {
        let j = #"{"enumeration":"complete","filesTotal":1,"filesIndexed":1,"bytesTotal":1,"bytesIndexed":1,"percent":null,"updatedT":1,"backfilling":false,"rebuilding":false,"refresh":"failed","lastSuccessT":5}"#
        let c = try JSONDecoder().decode(UsageCoverage.self, from: Data(j.utf8))
        #expect(c.refresh == "failed" && c.lastSuccessT == 5 && c.percent == nil)
        let old = j.replacingOccurrences(of: #","refresh":"failed","lastSuccessT":5"#, with: "")
        #expect(try JSONDecoder().decode(UsageCoverage.self, from: Data(old.utf8)).refresh == nil)
    }
    @Test func ttlUnknownCopyDoesNotHardCodeFiveMinutes() {
        let c = UsageCopy.reason("cache_ttl_unknown")
        #expect(c.contains("短 TTL") && !c.contains("5 分钟"), "Pi / OpenAI 的短 TTL 不是 5 分钟")
    }

    private func tok(_ w: Int, s: Int?, l: Int?, u: Int?) -> UsageEstimateTokens {
        UsageEstimateTokens(input: 0, output: 0, cacheRead: 0, cacheWrite: w, cacheWriteShort: s, cacheWriteLong: l, cacheWriteUnknown: u)
    }
    @Test func ttlLineUsesSourceLabelsAndHidesWhenNoSplit() {
        #expect(UsageAccuracy.ttlLine(source: "claude", tokens: tok(320, s: 100, l: 200, u: 20)) == "缓存写入 5m 100 · 1h 200 · TTL 未知 20")
        #expect(UsageAccuracy.ttlLine(source: "codex", tokens: tok(5, s: 5, l: 0, u: 0)) == "缓存写入 30m 5")
        #expect(UsageAccuracy.ttlLine(source: "claude", tokens: tok(0, s: 0, l: 0, u: 0)) == nil)
        #expect(UsageAccuracy.ttlLine(source: "claude", tokens: tok(100, s: nil, l: nil, u: nil)) == nil, "旧 Bridge 没有分项")
    }
    @Test func longWriteLineMentionsRuleAndSource() {
        let rules = [UsageCacheLongRule(rule: "anthropic_1h_2x_input", appliesTo: "anthropic", multiplier: 2, source: "platform.claude.com/docs/en/about-claude/pricing", asOf: "2026-10-24")]
        var b = UsageBand(above: 0, input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5, reasoning: nil, cacheWriteLong: 4, cacheWriteLongSource: "rule")
        let line = UsageAccuracy.longWriteLine(source: "claude", band: b, rules: rules)!
        #expect(line.contains("按规则推导") && line.contains("2× 输入价") && line.contains("2026-10-24") && line.contains("1h 写 $4"))
        b.cacheWriteLongSource = "table"
        #expect(UsageAccuracy.longWriteLine(source: "claude", band: b, rules: rules)!.contains("价格表"))
        b.cacheWriteLong = nil
        #expect(UsageAccuracy.longWriteLine(source: "claude", band: b, rules: rules) == nil)
    }
    @Test func newReasonCodesHaveCopyAndDecodeIsBackwardCompatible() throws {
        #expect(UsageCopy.reason("cache_ttl_unknown").contains("TTL"))
        #expect(UsageCopy.reason("tier_threshold_unverified").contains("未经官方"))
        let old = #"{"input":1,"output":2,"cacheRead":3,"cacheWrite":4}"#
        let t = try JSONDecoder().decode(UsageEstimateTokens.self, from: Data(old.utf8))
        #expect(t.cacheWriteShort == nil && t.cacheWriteUnknown == nil)
    }
}
