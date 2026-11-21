import Testing
import Foundation
@testable import PalmhelmKit

// O1-348：高延迟中继（1.7s RTT）下，一次全新 HTTPS 请求约 5.2s（3 个往返）。期限必须覆盖它，同时真不可达时有界结束。
// 用 URLProtocol 桩模拟「慢而可达」（先等 delay 再回应）与「黑洞」（永不回应），走真实 BridgeClient 的请求与期限路径。
final class StubDelayProtocol: URLProtocol {
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) static var blackhole = false
    nonisolated(unsafe) static var body = Data(#"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#.utf8)
    private var work: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.blackhole { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, let url = self.request.url else { return }
            let body = Self.body
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: item)
    }
    override func stopLoading() { work?.cancel() }
}

@Suite(.serialized) struct BridgeClientDeadlineTests {
    private let oneRoundTripsAt1_7s = 3 * 1.738 // TCP + TLS1.3 + HTTP，每个往返约 1.738s

    private func client(timeout: TimeInterval?) -> BridgeClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubDelayProtocol.self]
        return BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 47821, transport: .http), token: "t", session: URLSession(configuration: config), timeout: timeout)
    }

    private func elapsed(_ work: () async throws -> Void) async -> (TimeInterval, Error?) {
        let t0 = Date()
        do { try await work(); return (Date().timeIntervalSince(t0), nil) }
        catch { return (Date().timeIntervalSince(t0), error) }
    }

    // #85：卡在首字节的事件流尝试必须在首字节期限内结束（抛超时），让重连环接着退避再试，而不是一直挂着。
    @Test func streamFirstByteDeadlineEndsAStalledAttempt() async throws {
        StubDelayProtocol.blackhole = true
        defer { StubDelayProtocol.blackhole = false }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubDelayProtocol.self]
        let c = BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 47821, transport: .http), token: "t", session: URLSession(configuration: config))
        let stream = try await c.events(since: nil, firstByteDeadline: 0.5)
        let (took, error) = await elapsed {
            for try await _ in stream {}
        }
        #expect((error as? URLError)?.code == .timedOut, "黑洞：应以超时结束，而不是无限等待（\(String(describing: error))）")
        #expect(took < 5, "首字节期限 0.5 秒，实际 \(took) 秒")
    }

    @Test func theDeadlinesCoverAFreshRequestAtHighLatency() {
        #expect(BridgeAPI.Deadline.request >= oneRoundTripsAt1_7s * 1.5, "一次全新请求约 5.2s，常规期限须有余量")
        #expect(BridgeAPI.Deadline.pairSend >= BridgeAPI.Deadline.request)
        #expect(BridgeAPI.Deadline.refreshRound >= 2 * BridgeAPI.Deadline.request, "一轮至少能容纳两个地址各一次请求")
    }

    @Test func slowButReachableRequestCompletesWithTheDefaultDeadline() async {
        StubDelayProtocol.delay = oneRoundTripsAt1_7s
        StubDelayProtocol.blackhole = false
        let (t, error) = await elapsed { _ = try await client(timeout: nil).state() }
        #expect(error == nil, "慢而可达的请求应当完成：\(String(describing: error))")
        #expect(t >= oneRoundTripsAt1_7s - 0.2, "确实经历了高延迟")
    }

    @Test func theOldFourSecondBoundFailsTheSameRequest() async {
        // 旧的单次期限 4 秒：同样的 5.2s 请求必然超时（用来证明根因，不是新的目标值）
        StubDelayProtocol.delay = oneRoundTripsAt1_7s
        StubDelayProtocol.blackhole = false
        let (_, error) = await elapsed { _ = try await client(timeout: 4).state() }
        #expect((error as? URLError)?.code == .timedOut)
    }

    @Test func blackholeFailsWithinTheDeadlineAndDoesNotHang() async {
        StubDelayProtocol.blackhole = true
        let (t, error) = await elapsed { _ = try await client(timeout: nil).state() }
        StubDelayProtocol.blackhole = false
        #expect((error as? URLError)?.code == .timedOut, "真不可达：超时而不是无限等待")
        #expect(t < BridgeAPI.Deadline.request + 2, "有界结束：约 \(String(format: "%.1f", t))s")
    }

    // O1-349 R1：配对 POST 经真实 BridgeClient.pair（不传显式期限）时，11 秒的有效响应必须成功（配对期限 15 秒）。
    @Test func pairPostSlowerThanTheRequestDeadlineStillSucceeds() async throws {
        StubDelayProtocol.blackhole = false
        StubDelayProtocol.delay = 11
        StubDelayProtocol.body = Data(#"{"deviceId":"d-1","token":"deadbeef.secret","spkiSha256":null}"#.utf8)
        defer { StubDelayProtocol.delay = 0; StubDelayProtocol.body = Data(#"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#.utf8) }
        let (t, error) = await elapsed { _ = try await client(timeout: nil).pair(code: "123456", deviceName: "t") }
        #expect(error == nil, "11 秒的配对响应须成功（不得被常规 10 秒内层抢先）：\(String(describing: error))")
        #expect(t >= 10.5, "确实超过了常规期限")
    }

    // O1-349 R4：「在 Herdr 中显示」（reveal）也经公共绝对期限：黑洞类的慢响应在期限内结束。
    @Test func revealHonoursTheAbsoluteDeadline() async {
        StubDelayProtocol.blackhole = false
        StubDelayProtocol.delay = 0.3
        defer { StubDelayProtocol.delay = 0 }
        let (t, error) = await elapsed { _ = try await client(timeout: 0.05).reveal(targetId: "t1") }
        #expect((error as? URLError)?.code == .timedOut, "期限内返回超时，而不是等到 0.3 秒的响应")
        #expect(t < 0.25, "在期限附近结束：\(String(format: "%.2f", t))s")
    }
}

// O1-349 R3：地址扫描游标——预算用尽时未试的候选留给下一轮；周期试完从头再来；成功才结束周期；不改写 preferred。
@Suite struct EndpointScanTests {
    private func eps(_ n: Int) -> [BridgeEndpoint] { (1...n).map { BridgeEndpoint(host: "192.168.1.\($0)", port: 47821, transport: .https) } }

    @Test func untriedCandidatesCarryOverToTheNextRound() {
        var scan = EndpointScan()
        let list = eps(4)
        #expect(scan.plan(endpoints: list, preferred: 0) == [0, 1, 2, 3])
        scan.record(0, succeeded: false)
        scan.record(1, succeeded: false) // 预算用尽：2、3 未试
        #expect(scan.untried == 2)
        #expect(scan.plan(endpoints: list, preferred: 0) == [2, 3], "下一轮从未试的地址开始，不回到 preferred 重来")
        scan.record(2, succeeded: true)
        #expect(scan.plan(endpoints: list, preferred: 2) == [2, 0, 1, 3], "成功后新周期从 preferred 开始")
    }

    @Test func cycleRestartsOnceEveryCandidateHasFailed() {
        var scan = EndpointScan()
        let list = eps(2)
        _ = scan.plan(endpoints: list, preferred: 0)
        scan.record(0, succeeded: false)
        scan.record(1, succeeded: false)
        #expect(scan.cycleExhausted)
        #expect(scan.plan(endpoints: list, preferred: 0) == [0, 1], "周期试完后从头再来")
    }

    @Test func changedAddressTableResetsTheCycle() {
        var scan = EndpointScan()
        _ = scan.plan(endpoints: eps(2), preferred: 0)
        scan.record(0, succeeded: false)
        #expect(scan.plan(endpoints: eps(3), preferred: 0) == [0, 1, 2], "地址表变化：重新排序")
    }

    @Test func resetRebuildsTheOrderFromThePreferredEndpoint() {
        var scan = EndpointScan()
        let list = eps(3)
        _ = scan.plan(endpoints: list, preferred: 0)
        scan.record(0, succeeded: false)
        #expect(scan.plan(endpoints: list, preferred: 0) == [1, 2], "未试完的周期继续")
        scan.reset()
        #expect(scan.plan(endpoints: list, preferred: 2) == [2, 0, 1], "结束周期后从新的 preferred 重建")
    }
}
