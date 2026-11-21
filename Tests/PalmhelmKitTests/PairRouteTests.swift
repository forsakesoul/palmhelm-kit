import Testing
import Foundation
@testable import PalmhelmKit

// O1-346 / O1-347：配对依次尝试主地址与附带地址。未连上才换地址；配对请求结果不确定不换地址；指纹相关错误立即停止；绝对期限。
@MainActor
@Suite struct PairRouteTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }
    private let lan = BridgeEndpoint(host: "192.168.1.5", port: 47821, transport: .https)
    private let ts = BridgeEndpoint(host: "mac.tailnet.ts.net", port: 47821, transport: .https)
    private let unreachable = URLError(.cannotConnectToHost)

    @Test func unreachablePrimaryFallsBackToTheNextAddress() async {
        let log = Log()
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: nil,
            probe: { ep in log.add("probe:\(ep.host)"); return "S" },
            confirm: { _ in true },
            send: { ep -> String in
                log.add("send:\(ep.host)")
                if ep.host == "192.168.1.5" { throw URLError(.cannotConnectToHost) }
                return "ok"
            },
            reportedSpki: { _ in "S" })
        guard case .success(let s) = result else { Issue.record("应当成功：\(result)"); return }
        #expect(s.endpoint.host == ts.host, "第二个地址成功")
        #expect(s.endpoint.spkiSha256 == "S", "成功地址带上确认的指纹")
        #expect(log.all == ["probe:192.168.1.5", "send:192.168.1.5", "probe:mac.tailnet.ts.net", "send:mac.tailnet.ts.net"])
    }

    @Test func unreachableProbeAlsoFallsBack() async {
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: nil,
            probe: { ep in if ep.host == "192.168.1.5" { throw URLError(.timedOut) }; return "S" },
            confirm: { _ in true },
            send: { _ -> String in "ok" },
            reportedSpki: { _ in "S" })
        guard case .success(let s) = result else { Issue.record("应当成功"); return }
        #expect(s.endpoint.host == ts.host)
    }

    @Test func fingerprintChangeOnTheFallbackStopsWithoutSending() async {
        let log = Log()
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: nil,
            probe: { ep in ep.host == lan.host ? "S" : "T" },
            confirm: { _ in true },
            send: { ep -> String in
                log.add("send:\(ep.host)")
                throw URLError(.cannotConnectToHost)
            },
            reportedSpki: { _ in "S" })
        guard case .failure(.stopped(let e as PairRoute.PairRouteError)) = result else { Issue.record("应当因指纹不符停止：\(result)"); return }
        #expect(e == .fingerprintMismatch)
        #expect(log.all == ["send:192.168.1.5"], "指纹不符的地址不发配对码")
    }

    @Test func wrongPairingCodeStopsAndDoesNotTryTheNextAddress() async {
        let log = Log()
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: nil,
            probe: { _ in "S" },
            confirm: { _ in true },
            send: { ep -> String in
                log.add("send:\(ep.host)")
                throw BridgeError.http(status: 401)
            },
            reportedSpki: { _ in "S" })
        guard case .failure(.stopped(let e as BridgeError)) = result else { Issue.record("应当立即停止：\(result)"); return }
        #expect(e == .http(status: 401))
        #expect(log.all == ["send:192.168.1.5"], "配对码错误不换地址")
    }

    @Test func allAddressesUnreachableListsWhatWasTried() async {
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: nil,
            probe: { _ in "S" },
            confirm: { _ in true },
            send: { _ -> String in throw URLError(.cannotConnectToHost) },
            reportedSpki: { _ in "S" })
        guard case .failure(.unreachable(let tried)) = result else { Issue.record("应当是全部不可达：\(result)"); return }
        #expect(tried == ["局域网", "Tailscale"])
    }

    @Test func refusedFingerprintSendsNothing() async {
        let log = Log()
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: nil,
            probe: { _ in "S" },
            confirm: { _ in false },
            send: { ep -> String in log.add("send:\(ep.host)"); return "ok" },
            reportedSpki: { _ in "S" })
        guard case .failure(.stopped(let e as PairRoute.PairRouteError)) = result else { Issue.record("应当未确认停止：\(result)"); return }
        #expect(e == .notConfirmed)
        #expect(log.all.isEmpty, "未确认指纹时不发配对码")
    }

    @Test func broadcastFingerprintMismatchStopsBeforeAnyPairing() async {
        let log = Log()
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: "EXPECTED",
            probe: { _ in "S" },
            confirm: { _ in true },
            send: { ep -> String in log.add("send:\(ep.host)"); return "ok" },
            reportedSpki: { _ in "S" })
        guard case .failure(.stopped(let e as PairRoute.PairRouteError)) = result else { Issue.record("应当停止：\(result)"); return }
        #expect(e == .fingerprintMismatch)
        #expect(log.all.isEmpty)
    }

    // O1-347 R1：https 下 Bridge 缺失 spkiSha256 也必须拒绝（严格相等）。
    @Test func missingReportedFingerprintIsRejectedOverHttps() async {
        let result = await PairRoute.pair(
            candidates: [lan], expectedSpki: nil,
            probe: { _ in "S" },
            confirm: { _ in true },
            send: { _ -> String in "ok" },
            reportedSpki: { _ in nil })
        guard case .failure(.stopped(let e as PairRoute.PairRouteError)) = result else { Issue.record("缺失的指纹必须拒绝：\(result)"); return }
        #expect(e == .reportedFingerprintMissing)
    }

    @Test func differentReportedFingerprintIsRejected() async {
        let result = await PairRoute.pair(
            candidates: [lan], expectedSpki: nil,
            probe: { _ in "S" },
            confirm: { _ in true },
            send: { _ -> String in "ok" },
            reportedSpki: { _ in "OTHER" })
        guard case .failure(.stopped(let e as PairRoute.PairRouteError)) = result else { Issue.record("不一致的指纹必须拒绝：\(result)"); return }
        #expect(e == .reportedFingerprintMismatch)
    }

    // O1-347 R2：配对请求已发出但没有结果：不换地址、不重发同一码，报告「结果不确定」。
    @Test func timedOutPairingRequestIsNotRetriedOnTheNextAddress() async {
        let log = Log()
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: nil,
            probe: { _ in "S" },
            confirm: { _ in true },
            send: { ep -> String in
                log.add("send:\(ep.host)")
                throw URLError(.timedOut)
            },
            reportedSpki: { _ in "S" })
        guard case .failure(.resultUnknown(let ep)) = result else { Issue.record("应当是结果不确定：\(result)"); return }
        #expect(ep.host == lan.host)
        #expect(log.all == ["send:192.168.1.5"], "不换地址、不重发同一码")
    }

    @Test func droppedConnectionAfterSendIsAlsoOutcomeUnknown() async {
        let log = Log()
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: nil,
            probe: { _ in "S" },
            confirm: { _ in true },
            send: { ep -> String in log.add("send:\(ep.host)"); throw URLError(.networkConnectionLost) },
            reportedSpki: { _ in "S" })
        guard case .failure(.resultUnknown) = result else { Issue.record("应当是结果不确定：\(result)"); return }
        #expect(log.all.count == 1)
    }

    // O1-347 S1：绝对期限。探测超过期限即视为该地址不可达；配对请求超过期限即结果不确定。
    @Test func probeAbsoluteDeadlineFallsBackQuickly() async {
        let start = Date()
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: nil,
            probeDeadline: 0.2,
            probe: { ep in
                if ep.host == "192.168.1.5" { try await Task.sleep(for: .seconds(5)) }
                return "S"
            },
            confirm: { _ in true },
            send: { _ -> String in "ok" },
            reportedSpki: { _ in "S" })
        guard case .success(let s) = result else { Issue.record("应当换到第二地址：\(result)"); return }
        #expect(s.endpoint.host == ts.host)
        #expect(Date().timeIntervalSince(start) < 3, "不等待探测的空闲超时")
    }

    @Test func sendAbsoluteDeadlineIsOutcomeUnknown() async {
        let result = await PairRoute.pair(
            candidates: [lan, ts], expectedSpki: nil,
            sendDeadline: 0.2,
            probe: { _ in "S" },
            confirm: { _ in true },
            send: { _ -> String in try await Task.sleep(for: .seconds(5)); return "ok" },
            reportedSpki: { _ in "S" })
        guard case .failure(.resultUnknown) = result else { Issue.record("配对请求超过绝对期限应为结果不确定：\(result)"); return }
    }

    // O1-347 S1：候选数上限。
    @Test func candidatesAreCappedAtTheLimit() async {
        let eps = (1...6).map { BridgeEndpoint(host: "192.168.1.\($0)", port: 47821, transport: .https) }
        let probed = Log()
        let result = await PairRoute.pair(
            candidates: eps, expectedSpki: nil,
            probe: { ep in probed.add(ep.host); throw URLError(.cannotConnectToHost) },
            confirm: { _ in true },
            send: { _ -> String in "ok" },
            reportedSpki: { _ in "S" })
        guard case .failure(.unreachable(let tried)) = result else { Issue.record("应当全部不可达：\(result)"); return }
        #expect(probed.all.count == PairRoute.maxCandidates)
        #expect(tried.count == PairRoute.maxCandidates)
    }

    @Test func kindLabelsTailscaleAndLan() {
        #expect(PairRoute.kindLabel("mac.tailnet.ts.net") == "Tailscale")
        #expect(PairRoute.kindLabel("100.101.2.3") == "Tailscale")
        #expect(PairRoute.kindLabel("192.168.1.5") == "局域网")
        #expect(PairRoute.kindLabel("mac.local") == "局域网")
    }

    // O1-347 S1：二维码里的重复地址去重，候选数有上限。
    @Test func pairLinkDeduplicatesAndCapsExtraEndpoints() throws {
        let ep = "lan:10.0.0.1:47821,lan:10.0.0.1:47821,ts:a.ts.net:47821,lan:10.0.0.2:47821,lan:10.0.0.3:47821,lan:10.0.0.4:47821"
        let url = try #require(URL(string: "palmhelm://pair?host=10.0.0.9&port=47821&code=123456&tls=1&ep=\(ep)"))
        let link = try #require(PairLink.parse(url))
        #expect(link.extra.count == PairRoute.maxCandidates - 1, "主地址 + 附带地址不超过上限")
        #expect(Set(link.extra.map { "\($0.host):\($0.port)" }).count == link.extra.count, "同一地址只保留一次")
    }
}
