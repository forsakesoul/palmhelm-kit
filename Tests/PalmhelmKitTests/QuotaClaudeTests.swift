import Foundation
import Testing
@testable import PalmhelmKit

// Claude 订阅额度（#26 第二段，A1-109 返工版）：解码、共同展示层的有界防御（R4）、跨重置（R5）、
// 状态行开关响应的严格校验（R6），以及账户标题（未知 provider 原样显示）。
@Suite struct QuotaClaudeTests {
    private let now = Date(timeIntervalSince1970: 1_792_400_000)
    private var nowMs: Int { Int(now.timeIntervalSince1970 * 1000) }
    private func observed(_ ms: Int) -> String { "\(ms)" }

    @Test func decodesClaudeWindowsWithResetAndWithoutPercent() throws {
        let j = #"{"accounts":[{"provider":"claude","accountId":"acct_0123456789abcdef","label":"Claude","source":"claude_statusline","observedAt":1792399000000,"status":"ok","windows":[{"id":"five_hour:primary","usedPercent":42,"windowMins":300,"resetAt":1792418000000},{"id":"seven_day:secondary","reset":true,"windowMins":10080,"resetAt":1792399500000}]}]}"#
        let r = try JSONDecoder().decode(AccountsResponse.self, from: Data(j.utf8))
        let w = r.accounts[0].windows!
        #expect(w[0].usedPercent == 42 && w[0].reset == nil)
        #expect(w[1].usedPercent == nil && w[1].reset == true)
        #expect(QuotaCopy.usedText(w[1]) == "已重置，等待新数据")
        #expect(QuotaCopy.fraction(w[1]) == nil, "已重置不画进度")
        #expect(QuotaCopy.fraction(w[0]) == 0.42)
    }

    @Test func claudeStatesHaveCopyAndUnknownStatusIsNotHidden() {
        var waiting = AccountSnapshot(provider: "claude", accountId: "a", source: "claude_statusline", status: "awaiting_refresh")
        #expect(QuotaCopy.statusNote(waiting, now: now, observedText: observed)?.contains("等待 Claude Code") == true)
        var stale = waiting
        stale.status = "stale"
        stale.observedAt = nowMs - 3_600_000
        let staleText = QuotaCopy.statusNote(stale, now: now, observedText: observed) ?? ""
        #expect(staleText.contains("超过 30 分钟"), "Claude 的过期不说成离线或读取失败")
        #expect(!staleText.contains("离线或读取失败"))
        waiting.status = "brand_new"
        #expect(QuotaCopy.statusNote(waiting, now: now, observedText: observed)?.contains("状态未知") == true)
    }

    @Test func providerTitleKnownAndUnknown() {
        #expect(QuotaCopy.providerTitle("codex") == "Codex")
        #expect(QuotaCopy.providerTitle("claude") == "Claude")
        #expect(QuotaCopy.providerTitle("gemini") == "gemini", "未知 provider 原样显示，不冒充 Codex")
    }

    // R5：同一份快照，前后跨过重置时间，两个时刻的展示结果不同。
    @Test func claudeWindowCrossesResetOnTheSameSnapshot() {
        let resetMs = nowMs + 60_000
        let snap = AccountSnapshot(provider: "claude", accountId: "a", windows: [AccountWindow(id: "five_hour:primary", usedPercent: 90, windowMins: 300, resetAt: resetMs)], source: "claude_statusline", observedAt: nowMs - 1000, status: "ok")
        let before = QuotaCopy.displayAccount(snap, now: now).windows![0]
        #expect(before.usedPercent == 90 && before.reset == nil, "重置前显示比例")
        let after = QuotaCopy.displayAccount(snap, now: now.addingTimeInterval(120)).windows![0]
        #expect(after.usedPercent == nil && after.reset == true, "重置后隐藏旧比例")
        #expect(QuotaCopy.usedText(after) == "已重置，等待新数据")
    }

    // R5 只针对 Claude：Codex 的既有口径不变（已过重置时仍保留数值，由状态说明标注）。
    @Test func codexExpiryKeepsItsExistingRule() {
        let snap = AccountSnapshot(provider: "codex", accountId: "a", windows: [AccountWindow(id: "codex:primary", usedPercent: 40, windowMins: 300, resetAt: nowMs - 1000)], source: "codex_app_server", observedAt: nowMs, status: "ok")
        let w = QuotaCopy.displayAccount(snap, now: now).windows![0]
        #expect(w.usedPercent == 40, "Codex 不因跨重置被改写")
        #expect(w.reset == nil)
        #expect(QuotaCopy.windowExpired(w, now: now))
    }

    // R4：越界或不可安全换算的数值按未知处理，不填 0，也不会在转换时溢出。
    @Test func absurdNumbersBecomeUnknownNotZero() {
        let snap = AccountSnapshot(provider: "claude", accountId: "a", windows: [
            AccountWindow(id: "five_hour:primary", usedPercent: 1e100, windowMins: 300, resetAt: nowMs + 60_000),
            AccountWindow(id: "seven_day:secondary", usedPercent: -3, windowMins: 10080, resetAt: 9_000_000_000_000_000),
            AccountWindow(id: "x", usedPercent: Double.nan, windowMins: nil, resetAt: nil),
        ], source: "claude_statusline", observedAt: nowMs, status: "ok")
        let ws = QuotaCopy.displayAccount(snap, now: now).windows!
        #expect(ws[0].usedPercent == nil && ws[1].usedPercent == nil && ws[2].usedPercent == nil)
        #expect(ws[1].resetAt == nil, "超出安全范围的重置时间不保留")
        #expect(ws[0].resetAt == nowMs + 60_000, "合法的重置时间保留")
    }

    // R6：开关响应必须 2xx 且 ok == true；坏的 2xx 是 invalid_response；非 2xx 只保留固定码。
    @Test func statuslineResponseIsStrict() {
        #expect(decodeClaudeStatuslineResult(status: 200, data: Data(#"{"ok":true,"settings":"changed","restored":"none"}"#.utf8)).ok == true)
        #expect(decodeClaudeStatuslineResult(status: 200, data: Data(#"{"settings":"changed"}"#.utf8)).error == "invalid_response", "2xx 缺 ok")
        #expect(decodeClaudeStatuslineResult(status: 200, data: Data(#"{"ok":false}"#.utf8)).error == "invalid_response")
        #expect(decodeClaudeStatuslineResult(status: 200, data: Data("<html>".utf8)).error == "invalid_response", "2xx 非 JSON")
        #expect(decodeClaudeStatuslineResult(status: 409, data: Data(#"{"error":"settings_changed"}"#.utf8)).error == "settings_changed")
        #expect(decodeClaudeStatuslineResult(status: 500, data: Data(#"{"error":"<script>alert(1)</script>"}"#.utf8)).error == "http_500", "非固定码不回显")
        #expect(decodeClaudeStatuslineResult(status: 500, data: Data()).error == "http_500")
        let status = try? JSONDecoder().decode(ClaudeStatuslineStatus.self, from: Data(#"{"installed":true}"#.utf8))
        #expect(status?.installed == true)
    }

    // 经过真实客户端（BridgeClient + URLProtocol 桩）：非 2xx 保留 HTTP 状态码，404 才是旧 Bridge；2xx 解码 installed。
    final class StatusStub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: StatusStub.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: StatusStub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @Test func statuslineStatusKeepsHttpStatusThroughRealClient() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StatusStub.self]
        let client = BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "t", session: URLSession(configuration: cfg))
        StatusStub.status = 404; StatusStub.body = Data(#"{"error":"not_found"}"#.utf8)
        do { _ = try await client.claudeStatuslineInstalled(); Issue.record("404 应抛错") }
        catch BridgeError.http(let code) { #expect(code == 404) }
        StatusStub.status = 503; StatusStub.body = Data(#"{"error":"status_unreadable"}"#.utf8)
        do { _ = try await client.claudeStatuslineInstalled(); Issue.record("503 应抛错") }
        catch BridgeError.http(let code) { #expect(code == 503) }
        StatusStub.status = 200; StatusStub.body = Data(#"{"installed":true}"#.utf8)
        #expect(try await client.claudeStatuslineInstalled() == true)
        StatusStub.status = 200; StatusStub.body = Data("<html>".utf8)
        do { _ = try await client.claudeStatuslineInstalled(); Issue.record("2xx 非 JSON 应抛错") }
        catch BridgeError.decoding { }
    }
}
