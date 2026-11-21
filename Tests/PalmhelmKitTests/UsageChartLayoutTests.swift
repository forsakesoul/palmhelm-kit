import Foundation
import Testing
@testable import PalmhelmKit

// #30：柱图用分类 x 轴（类目键 = 桶起点毫秒）。固定：键唯一、可回查、首尾零桶可选中、柱宽比例小于 1。
@Suite struct UsageChartLayoutTests {
    private func response(buckets: [(Int, Int)]) throws -> UsageResponse {
        let b = buckets.map { #"{"t":\#($0.0),"byModel":{"claude-a":{"input":\#($0.1),"output":0,"cacheRead":0,"cacheWrite":0,"activity":1}}}"# }.joined(separator: ",")
        let json = #"{"window":"24h","timeZone":"Asia/Shanghai","generatedT":1,"partial":false,"reasons":[],"quality":{},"bucketMs":3600000,"buckets":[\#(b)],"recent":{"today":{"from":"a","to":"a","byModel":{}},"d7":{"from":"a","to":"a","byModel":{}},"d30":{"from":"a","to":"a","byModel":{}}},"heatmap":{"days":[],"activity":[]},"prices":{},"agents":{"claude":{"candidates":0,"parsed":0,"complete":0},"codex":{"candidates":0,"parsed":0,"complete":0}}}"#
        return try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    @Test func keysAreUniquePerBucketAndLookUpBack() throws {
        let t0 = 1_792_252_800_000 // 2026-10-18 00:00 上海
        let r = try response(buckets: [(t0, 0), (t0 + 3_600_000, 5), (t0 + 7_200_000, 0)])
        let d = UsageChartData.make(r, from: "2026-10-18", to: "2026-10-18", daily: false)
        #expect(d.bars.count == 3)
        #expect(Set(d.bars.map(UsageChartData.key)).count == 3)
        for b in d.bars { #expect(d.bar(key: UsageChartData.key(b))?.id == b.id) }
        #expect(d.bar(key: "999") == nil)
    }

    @Test func zeroBucketsAtBothEndsAreSelectable() throws {
        let t0 = 1_792_252_800_000
        let r = try response(buckets: [(t0, 0), (t0 + 3_600_000, 9), (t0 + 7_200_000, 0)])
        let d = UsageChartData.make(r, from: "2026-10-18", to: "2026-10-18", daily: false)
        #expect(d.bar(at: d.bars[0].start.addingTimeInterval(1800))?.id == d.bars[0].id)
        #expect(d.bar(at: d.bars[2].start.addingTimeInterval(1800))?.id == d.bars[2].id)
    }

    @Test func barRatioLeavesGapBetweenNeighbours() {
        #expect(UsageChartData.barRatio > 0 && UsageChartData.barRatio < 1)
    }
}
