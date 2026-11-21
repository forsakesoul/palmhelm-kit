import Foundation
import Testing
@testable import PalmhelmKit

// h11b：/v1/usage 的 estimate 区块（Bridge h11a）解码、旧 Bridge 兼容、价格刷新结果与原因码文案。
@Suite struct UsageEstimateTests {
    private static let base = #""window":"24h","timeZone":"Asia/Shanghai","generatedT":1792380000000,"partial":true,"reasons":[],"quality":{},"bucketMs":3600000,"buckets":[],"recent":{"today":{"from":"2026-10-24","to":"2026-10-24","byModel":{}},"d7":{"from":"2026-10-18","to":"2026-10-24","byModel":{}},"d30":{"from":"2026-09-25","to":"2026-10-24","byModel":{}}},"heatmap":{"days":[],"activity":[]},"prices":{}"#
    private static let window = #"{"from":"2026-10-24","to":"2026-10-24","rows":[{"source":"pi","model":"qwen-x","provider":null,"referenceProvider":null,"tokens":{"input":10,"output":2,"cacheRead":0,"cacheWrite":0},"costUsd":null,"unpricedTokens":12,"reasons":["region_ambiguous"],"usedBands":[]},{"source":"claude","model":"claude-opus-5-5","provider":null,"referenceProvider":"anthropic","tokens":{"input":100,"output":10,"cacheRead":50,"cacheWrite":0},"costUsd":0.0012,"unpricedTokens":0,"reasons":[],"usedBands":[{"above":0,"input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25,"reasoning":null}],"futureField":1}],"totals":{"tokens":{"input":110,"output":12,"cacheRead":50,"cacheWrite":0},"costUsd":0.0012,"hasUnpriced":true,"partial":true,"priceStale":false}}"#

    @Test func decodesEstimateAndIgnoresUnknownFields() throws {
        let json = "{" + Self.base + #","agents":{"claude":{"candidates":1,"parsed":1,"complete":1},"codex":{"candidates":0,"parsed":0,"complete":0},"pi":{"candidates":2,"parsed":2,"complete":1}},"estimate":{"version":1,"windows":{"today":"# + Self.window + #","last7d":"# + Self.window + #"},"pricing":{"source":"models.dev","origin":"bundled","freshness":"current","versionHash":"a94d9e0203f0b3c0","asOfT":1792300000000,"lastValidatedT":1792300000000,"lastCheckT":null,"autoUpdate":true,"updatePolicy":"startup_if_older_than_3d"},"sources":[{"source":"opencode","status":"partial","reasons":["sqlite_not_opened"]}],"truncated":[]}}"#
        let u = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        let e = try #require(u.estimate)
        #expect(e.windows.today.rows.count == 2)
        #expect(e.windows.today.rows[0].costUsd == nil)
        #expect(e.windows.today.rows[1].usedBands.first?.reasoning == nil)
        #expect(e.windows.today.totals.tokens.total == 172)
        #expect(e.pricing.lastCheckT == nil)
        #expect(u.agents.pi?.candidates == 2)
        #expect(Set(e.windows.today.rows.map(\.id)).count == 2)
    }

    @Test func unknownEstimateVersionWithDifferentShapeIsNotInterpreted() throws {
        // v2 改了结构（没有 windows），整份响应仍要能解开，只留「暂不支持」信号与外层 token 数据
        let json = "{" + Self.base + #","agents":{"claude":{"candidates":1,"parsed":1,"complete":1},"codex":{"candidates":0,"parsed":0,"complete":0}},"estimate":{"version":2,"periods":[{"id":"x"}]}}"#
        let u = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(u.estimateV1 == nil)
        #expect(u.estimateUnsupported)
        #expect(u.recent.today.from == "2026-10-24")
    }

    @Test func oldBridgeWithoutEstimateStillDecodes() throws {
        let json = "{" + Self.base + #","agents":{"claude":{"candidates":1,"parsed":1,"complete":1},"codex":{"candidates":0,"parsed":0,"complete":0}}}"#
        let u = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(u.estimate == nil)
        #expect(u.agents.pi == nil)
    }

    @Test func priceRefreshResults() {
        let pricing = #"{"source":"models.dev","origin":"downloaded","freshness":"current","versionHash":"x","asOfT":1,"lastValidatedT":2,"lastCheckT":3,"autoUpdate":true,"updatePolicy":"startup_if_older_than_3d"}"#
        if case .updated(let p) = BridgeClient.decodePriceRefresh(status: 200, body: Data(#"{"result":"updated","pricing":\#(pricing)}"#.utf8)) { #expect(p.origin == "downloaded") } else { Issue.record("200 updated") }
        if case .current = BridgeClient.decodePriceRefresh(status: 200, body: Data(#"{"result":"current","pricing":\#(pricing)}"#.utf8)) {} else { Issue.record("200 current") }
        #expect(BridgeClient.decodePriceRefresh(status: 429, body: Data(#"{"error":"rate_limited","retryAfterMs":59000}"#.utf8)) == .rateLimited(retryAfterMs: 59000))
        #expect(BridgeClient.decodePriceRefresh(status: 403, body: Data(#"{"error":"read_only"}"#.utf8)) == .failed(code: "read_only"))
        #expect(BridgeClient.decodePriceRefresh(status: 401, body: Data()) == .failed(code: "unauthorized"))
        #expect(BridgeClient.decodePriceRefresh(status: 404, body: Data()) == .failed(code: "unsupported"))
        #expect(BridgeClient.decodePriceRefresh(status: 503, body: Data(#"{"error":"shutting_down"}"#.utf8)) == .failed(code: "shutting_down"))
        #expect(BridgeClient.decodePriceRefresh(status: 200, body: Data(#"{"result":"unexpected","pricing":\#(pricing)}"#.utf8)) == .failed(code: "invalid_response"))
        #expect(BridgeClient.decodePriceRefresh(status: 200, body: Data("not json".utf8)) == .failed(code: "invalid_response"))
        #expect(UsageCopy.refreshFailure("brand_new_code") == "更新失败")
        #expect(BridgeClient.decodePriceRefresh(status: 502, body: Data(#"{"error":"timeout"}"#.utf8)) == .failed(code: "timeout"))
    }

    @Test func copyCoversKnownCodesAndKeepsUnknown() {
        #expect(UsageCopy.reason("region_ambiguous") == "参考渠道不唯一，暂不估价")
        for code in ["model_unknown", "price_missing", "price_field_missing", "price_overflow", "tokens_all_zero", "changed_during_read", "pi_inconsistent", "missing_id", "missing_field", "codex_reset", "codex_cache_write_unsupported", "overflow", "truncated_models", "rows_truncated", "bands_omitted", "wal_unverifiable", "journal_present"] {
            #expect(UsageCopy.reason(code) != code, "\(code) 应有中文说明")
        }
        #expect(UsageCopy.reason("sqlite_not_opened").contains("OpenCode"))
        #expect(UsageCopy.reason("some_new_code") == "some_new_code")
        #expect(UsageCopy.status("found_unusable") == "已发现，暂不可用")
        #expect(UsageCopy.sourceName("pi") == "Pi")
        #expect(UsageCopy.refreshFailure("read_only").contains("只读"))
    }
}
