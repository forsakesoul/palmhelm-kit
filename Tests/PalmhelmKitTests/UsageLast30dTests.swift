import Foundation
import Testing
@testable import PalmhelmKit

// #31 第一段（Kit）：estimate.windows.last30d 可选解码（新旧响应都能解）；UsageChartData 支持 30 根日桶（零桶保留、键唯一）。
@Suite struct UsageLast30dTests {
    private func win(_ from: String, _ to: String, input: Int) -> String {
        #"{"from":"\#(from)","to":"\#(to)","rows":[{"source":"claude","model":"m","tokens":{"input":\#(input),"output":0,"cacheRead":0,"cacheWrite":0},"costUsd":null,"unpricedTokens":0,"reasons":[],"usedBands":[]}],"totals":{"tokens":{"input":\#(input),"output":0,"cacheRead":0,"cacheWrite":0},"costUsd":null,"hasUnpriced":false,"partial":false,"priceStale":false}}"#
    }

    @Test func oldBridgeWithoutLast30dDecodesToNil() throws {
        let old = #"{"today":\#(win("a", "a", input: 1)),"last7d":\#(win("b", "c", input: 7))}"#
        let w = try JSONDecoder().decode(UsageEstimateWindows.self, from: Data(old.utf8))
        #expect(w.last30d == nil)
        #expect(w.last7d.totals.tokens.input == 7)
    }

    @Test func newBridgeDecodesLast30dWithSameShapeAsLast7d() throws {
        let new = #"{"today":\#(win("a", "a", input: 1)),"last7d":\#(win("b", "c", input: 7)),"last30d":\#(win("d", "e", input: 30))}"#
        let w = try JSONDecoder().decode(UsageEstimateWindows.self, from: Data(new.utf8))
        #expect(w.last30d?.from == "d")
        #expect(w.last30d?.totals.tokens.input == 30)
        #expect(w.last30d?.rows.first?.model == "m", "rows 与 last7d 同形")
    }

    @Test func thirtyDailyBucketsKeepZeroDaysAndUniqueKeys() throws {
        let t0 = 1_771_459_200_000 // 2026-02-19 00:00 UTC（时区为 UTC：桶起点与 date 一致）
        let buckets = (0..<30).map { i -> String in
            let t = t0 + i * 86_400_000
            // 偶数日有用量，奇数日为零桶（没有模型条目）
            let by = i % 2 == 0 ? #"{"claude-a":{"input":\#(100 + i),"output":0,"cacheRead":0,"cacheWrite":0,"activity":1}}"# : "{}"
            return #"{"t":\#(t),"date":"2026-\#(i < 10 ? "02" : "03")-\#(String(format: "%02d", i < 10 ? 19 + i : i - 9))","byModel":\#(by)}"#
        }.joined(separator: ",")
        let json = #"{"window":"30d","timeZone":"UTC","generatedT":1,"partial":false,"reasons":[],"quality":{},"bucketMs":86400000,"buckets":[\#(buckets)],"recent":{"today":{"from":"a","to":"a","byModel":{}},"d7":{"from":"a","to":"a","byModel":{}},"d30":{"from":"a","to":"a","byModel":{}}},"heatmap":{"days":[],"activity":[]},"prices":{},"agents":{"claude":{"candidates":0,"parsed":0,"complete":0},"codex":{"candidates":0,"parsed":0,"complete":0}}}"#
        let r = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        let d = UsageChartData.make(r, from: "2026-02-19", to: "2026-03-20", daily: true)
        #expect(d.bars.count == 30)
        #expect(Set(d.bars.map(\.id)).count == 30)
        #expect(d.bars.filter { $0.total == 0 }.count == 15, "零日保留为柱（占类目）")
        #expect(d.bars.first?.total == 100)
    }
}
