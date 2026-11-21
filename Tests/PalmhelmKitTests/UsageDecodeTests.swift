import XCTest
@testable import PalmhelmKit

final class UsageDecodeTests: XCTestCase {
    // 按 Bridge 契约（docs/ops/local-api.md 用量接口）构造的最小样本：含 other/unknown、无报价、partial、小时桶无 date。
    private let json = """
    {"window":"24h","timeZone":"Asia/Shanghai","generatedT":1792380000000,"partial":true,"reasons":["codex_baseline_unknown"],
     "quality":{"codexBaselineUnknown":1,"missingId":0},"bucketMs":3600000,
     "buckets":[{"t":1792376400000,"byModel":{"claude-sonnet-5-5":{"input":100,"output":10,"cacheRead":80,"cacheWrite":5,"activity":2},"other":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"activity":1}}},
                {"t":1792380000000,"byModel":{}}],
     "recent":{"today":{"from":"2026-10-19","to":"2026-10-19","byModel":{"claude-sonnet-5-5":{"input":100,"output":10,"cacheRead":80,"cacheWrite":5,"activity":2}}},
               "d7":{"from":"2026-10-13","to":"2026-10-19","byModel":{}},"d30":{"from":"2026-09-20","to":"2026-10-19","byModel":{}}},
     "heatmap":{"days":["2026-10-13","2026-10-14","2026-10-15","2026-10-16","2026-10-17","2026-10-18","2026-10-19"],"activity":[[0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3]]},
     "prices":{"claude-sonnet-5-5":{"input":3,"output":15,"cacheRead":0.3,"cacheWrite":3.75,"source":"anthropic.com/pricing","asOf":"2026-10-19"}},
     "agents":{"claude":{"candidates":3,"parsed":3,"complete":3},"codex":{"candidates":2,"parsed":1,"complete":1}}}
    """

    func testDecodeAndEstimate() throws {
        let u = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        XCTAssertTrue(u.partial)
        XCTAssertEqual(u.buckets.count, 2)
        XCTAssertNil(u.buckets[0].date)
        XCTAssertEqual(u.models, ["claude-sonnet-5-5", "other"])
        let all = u.buckets[0].byModel
        let selected = u.estimate(all, kinds: [.input, .output])
        let expectedSelected: Double = (100.0 * 3.0 + 10.0 * 15.0) / 1_000_000.0
        XCTAssertEqual(selected.usd, expectedSelected, accuracy: 1e-12)
        XCTAssertTrue(selected.hasUnpriced, "other 有 token 但没有报价 → 存在未报价部分")
        let onlyPriced = u.estimate(["claude-sonnet-5-5": all["claude-sonnet-5-5"]!], kinds: Set(TokenKind.allCases))
        XCTAssertFalse(onlyPriced.hasUnpriced)
        let expectedAll: Double = (100.0 * 3.0 + 10.0 * 15.0 + 80.0 * 0.3 + 5.0 * 3.75) / 1_000_000.0
        XCTAssertEqual(onlyPriced.usd, expectedAll, accuracy: 1e-12)
        XCTAssertEqual(all["claude-sonnet-5-5"]!.total([.input, .cacheRead]), 180)
    }

    func testUnpricedZeroTokensDoNotCountAsUnpriced() {
        let u = try! JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        XCTAssertFalse(u.estimate(["unknown": UsageTokens()], kinds: Set(TokenKind.allCases)).hasUnpriced)
    }

    /// #4：新增字段（coverage、TTL 分项、1h 推导规则、行 notes）全是可选——旧样本照常解码、新样本能读到；旧客户端忽略新字段由 Codable 保证。
    func testAccuracyFieldsDecodeWhenPresentAndAreAbsentOtherwise() throws {
        let old = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        XCTAssertNil(old.coverage)
        let withCov = json.replacingOccurrences(of: #""agents":{"claude""#, with: #""coverage":{"enumeration":"in_progress","filesTotal":9,"filesIndexed":4,"bytesTotal":100,"bytesIndexed":40,"updatedT":1,"backfilling":true,"rebuilding":false},"agents":{"claude""#)
        let u = try JSONDecoder().decode(UsageResponse.self, from: Data(withCov.utf8))
        XCTAssertEqual(u.coverage?.enumeration, "in_progress")
        XCTAssertNil(u.coverage?.percent)
        XCTAssertEqual(UsageAccuracy.coverageLine(u.coverage), "已扫描 4 个，仍在发现记录")
        let est = #"{"version":1,"windows":{"today":{"from":"a","to":"a","rows":[{"source":"claude","model":"m","tokens":{"input":1,"output":1,"cacheRead":0,"cacheWrite":300,"cacheWriteShort":100,"cacheWriteLong":200,"cacheWriteUnknown":0},"costUsd":0.1,"unpricedTokens":0,"reasons":[],"usedBands":[{"above":0,"input":2,"cacheWrite":2.5,"cacheWriteLong":4,"cacheWriteLongSource":"rule"}],"notes":["tier_threshold_unverified"]}],"totals":{"tokens":{"input":1,"output":1,"cacheRead":0,"cacheWrite":300},"hasUnpriced":false,"partial":false,"priceStale":false,"ttlUnknownTokens":0}},"last7d":{"from":"a","to":"a","rows":[],"totals":{"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"hasUnpriced":false,"partial":false,"priceStale":false}}},"pricing":{"source":"models.dev","origin":"bundled","freshness":"current","versionHash":"h","asOfT":1,"lastValidatedT":1,"autoUpdate":true,"updatePolicy":"manual_only","cacheLongRules":[{"rule":"anthropic_1h_2x_input","appliesTo":"anthropic","multiplier":2,"source":"platform.claude.com/docs/en/about-claude/pricing","asOf":"2026-10-24"}],"notes":["inference_geo_global_assumed_otherwise"]},"sources":[],"truncated":[]}"#
        let e = try JSONDecoder().decode(UsageEstimate.self, from: Data(est.utf8))
        let r = e.windows.today.rows[0]
        XCTAssertEqual(UsageAccuracy.ttlLine(source: r.source, tokens: r.tokens), "缓存写入 5m 100 · 1h 200")
        XCTAssertTrue(UsageAccuracy.priceDetail(r, rules: e.pricing.cacheLongRules).contains("按规则推导"))
        XCTAssertTrue(UsageAccuracy.priceDetail(r, rules: e.pricing.cacheLongRules).contains("未经官方"))
        XCTAssertEqual(UsageAccuracy.pricingNote(e.pricing.notes![0]), "日志读不到推理地域时按全球价计算")
    }
}
