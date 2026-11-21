import Foundation
import Testing
@testable import PalmhelmKit

// h11c：柱图堆叠与悬停明细的共享聚合。
@Suite struct UsageBreakdownTests {
    private func response(tz: String, bucketMs: Int = 3_600_000, buckets: String) throws -> UsageResponse {
        let json = #"{"window":"24h","timeZone":"\#(tz)","generatedT":1,"partial":false,"reasons":[],"quality":{},"bucketMs":\#(bucketMs),"buckets":[\#(buckets)],"recent":{"today":{"from":"a","to":"a","byModel":{}},"d7":{"from":"a","to":"a","byModel":{}},"d30":{"from":"a","to":"a","byModel":{}}},"heatmap":{"days":[],"activity":[]},"prices":{},"agents":{"claude":{"candidates":0,"parsed":0,"complete":0},"codex":{"candidates":0,"parsed":0,"complete":0}}}"#
        return try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }
    private func tok(_ n: Int) -> String { #"{"input":\#(n),"output":0,"cacheRead":0,"cacheWrite":0,"activity":1}"# }

    @Test func topThreePlusOtherAndPartsSumToTotal() throws {
        // 2026-10-24 00:00 / 01:00 上海
        let b1 = #"{"t":1792771200000,"byModel":{"a":\#(tok(50)),"b":\#(tok(30)),"c":\#(tok(10)),"d":\#(tok(7)),"other":\#(tok(3))}}"#
        let b2 = #"{"t":1792774800000,"byModel":{"a":\#(tok(10)),"d":\#(tok(1))}}"#
        let b3 = #"{"t":1792778400000,"byModel":{}}"#
        let d = UsageChartData.make(try response(tz: "Asia/Shanghai", buckets: [b1, b2, b3].joined(separator: ",")), from: "2026-10-24", to: "2026-10-24", daily: false)
        #expect(d.series == ["a", "b", "c"]) // d（8）不进前 3；other 聚合项永远不当具名模型
        let first = try #require(d.bars.first)
        #expect(first.title == "00:00–01:00")
        #expect(first.parts.map(\.model) == ["a", "b", "c", nil])
        #expect(first.parts.reduce(0) { $0 + $1.tokens } == first.total)
        #expect(first.parts.reduce(0) { $0 + $1.percent } == 100)
        #expect(first.parts.last?.tokens == 10) // d 7 + other 3
        #expect(d.bars[1].parts.map(\.model) == ["a", nil]) // 0 的行省略
        #expect(d.bars[2].total == 0 && d.bars[2].parts.isEmpty)
        #expect(d.bar(at: first.start)?.id == first.id)
        #expect(d.bar(at: first.end)?.id == d.bars[1].id) // 半开区间
    }

    @Test func percentagesSumTo100AndNonZeroNeverZero() {
        #expect(UsageChartData.percentages([1, 1, 1]).reduce(0, +) == 100)
        let p = UsageChartData.percentages([1000, 1])
        #expect(p == [99, 1])
        #expect(UsageChartData.percentages([0, 0]) == [0, 0])
    }

    @Test func dstRepeatedHourGetsOffsetAndDailyTitleHasWeekday() throws {
        // 2026-11-01 洛杉矶回拨：01:00 出现两次（PDT 08:00Z、PST 09:00Z）
        let b1 = #"{"t":1793520000000,"byModel":{"a":\#(tok(1))}}"#
        let b2 = #"{"t":1793523600000,"byModel":{"a":\#(tok(1))}}"#
        let d = UsageChartData.make(try response(tz: "America/Los_Angeles", buckets: [b1, b2].joined(separator: ",")), from: "2026-11-01", to: "2026-11-01", daily: false)
        #expect(d.bars.count == 2)
        #expect(d.bars[0].title != d.bars[1].title)
        #expect(d.bars[0].title.contains("UTC"))
        let day = #"{"t":1792771200000,"date":"2026-10-24","byModel":{"a":\#(tok(1))}}"#
        let w = UsageChartData.make(try response(tz: "Asia/Shanghai", bucketMs: 86_400_000, buckets: day), from: "2026-10-18", to: "2026-10-24", daily: true)
        #expect(w.bars.first?.title == "10月24日 周六")
    }

    @Test func bucketsOutsideWindowAreDropped() throws {
        let yesterday = #"{"t":1792684800000,"byModel":{"a":\#(tok(5))}}"#
        let today = #"{"t":1792771200000,"byModel":{"a":\#(tok(5))}}"#
        let d = UsageChartData.make(try response(tz: "Asia/Shanghai", buckets: [yesterday, today].joined(separator: ",")), from: "2026-10-24", to: "2026-10-24", daily: false)
        #expect(d.bars.map(\.id) == [1792771200000])
    }
}
