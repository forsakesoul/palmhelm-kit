import Testing
import Foundation
@testable import PalmhelmKit

@Suite struct AccountsTests {
    @Test func pairResponseAndBridgeMetaDecodeEndpoints() throws {
        let r = try JSONDecoder().decode(PairResponse.self, from: Data(#"{"deviceId":"0123456789abcdef","token":"t","endpoints":[{"host":"192.168.1.8","port":47821,"transport":"https","kind":"lan"},{"host":"mbp.tail-9a86.ts.net","port":47821,"transport":"https","kind":"tailscale"}]}"#.utf8))
        #expect(r.endpoints?.count == 2 && r.endpoints?[1].kind == "tailscale")
        let old = try JSONDecoder().decode(PairResponse.self, from: Data(#"{"deviceId":"0123456789abcdef","token":"t"}"#.utf8))
        #expect(old.endpoints == nil)
    }

    @Test func rotationPrefersLastSuccessThenLanThenHostname() {
        let eps = [BridgeEndpoint(host: "mbp.tail.ts.net", port: 1, transport: .https), BridgeEndpoint(host: "192.168.1.8", port: 1, transport: .https), BridgeEndpoint(host: "127.0.0.1", port: 1)]
        #expect(EndpointRotation.order(eps, preferred: 0) == [0, 1, 2])
        #expect(EndpointRotation.order(eps, preferred: 1) == [1, 0, 2])
        #expect(EndpointRotation.order(eps, preferred: 9) == [1, 0, 2])
    }

    @Test func networkFailureClassification() {
        #expect(EndpointRotation.isNetworkFailure(URLError(.cannotConnectToHost)))
        #expect(EndpointRotation.isNetworkFailure(URLError(.secureConnectionFailed)))
        #expect(!EndpointRotation.isNetworkFailure(BridgeError.http(status: 401)))
        #expect(!EndpointRotation.isNetworkFailure(URLError(.cancelled)))
    }

    @Test func mergeKeepsPinAndCurrent() {
        let a = BridgeAccount(name: "Mac", endpoints: [BridgeEndpoint(host: "mbp.tail.ts.net", port: 47821, transport: .https, spkiSha256: "PIN")], deviceName: "iPhone")
        let m = EndpointRotation.merge(a, with: [ApiEndpoint(host: "192.168.1.8", port: 47821, transport: .https, kind: "lan"), ApiEndpoint(host: "127.0.0.1", port: 47821, transport: .http, kind: "loopback")])
        #expect(m.endpoints.map(\.host) == ["mbp.tail.ts.net", "192.168.1.8"]) // 回环不保留；当前主机名保留在前
        #expect(m.endpoints.allSatisfy { $0.spkiSha256 == "PIN" } && m.current?.host == "mbp.tail.ts.net")
    }

    @Test func mergeReplacesStaleTailscaleName() {
        let a = BridgeAccount(name: "Mac", endpoints: [BridgeEndpoint(host: "wrong.ts.net", port: 47821, transport: .https, spkiSha256: "PIN")], deviceName: "iPhone")
        let m = EndpointRotation.merge(a, with: [ApiEndpoint(host: "192.168.1.8", port: 47821, transport: .https, kind: "lan"), ApiEndpoint(host: "mbp.tail.ts.net", port: 47821, transport: .https, kind: "tailscale")])
        #expect(m.endpoints.map(\.host) == ["192.168.1.8", "mbp.tail.ts.net"]) // Bridge 自报的 MagicDNS 名取代过期名
        #expect(m.current?.host == "192.168.1.8" && m.endpoints.allSatisfy { $0.spkiSha256 == "PIN" })
    }

    @Test func pairLinkParsesExtraEndpoints() throws {
        let u = try #require(URL(string: "palmhelm://pair?host=192.168.1.8&port=47821&code=482913&tls=1&fp=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D&ep=lan%3A192.168.1.8%3A47821%2Cts%3Ambp.tail.ts.net%3A47821"))
        let l = try #require(PairLink.parse(u))
        #expect(l.host == "192.168.1.8" && l.tls && l.fp == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" && l.extra.map(\.host) == ["mbp.tail.ts.net"])
        #expect(PairLink.parse(URL(string: "palmhelm://pair?host=x&code=12")!) == nil)
    }

    // 配对链接的形态校验集中在 parse：非法端口 / 主机 / 非 ASCII 验证码 / 非完整 SPKI 一律拒绝，不回落默认值。
    @Test func pairLinkRejectsMalformedValues() {
        func p(_ s: String) -> PairLink? { URL(string: s).flatMap(PairLink.parse) }
        #expect(p("palmhelm://pair?host=192.0.2.5&code=123456")?.port == BridgeAPI.defaultPort)
        #expect(p("palmhelm://pair?host=192.0.2.5&port=0&code=123456") == nil)
        #expect(p("palmhelm://pair?host=192.0.2.5&port=70000&code=123456") == nil)
        #expect(p("palmhelm://pair?host=192.0.2.5&port=47a&code=123456") == nil)
        #expect(p("palmhelm://pair?host=evil%2Fpath&code=123456") == nil)
        #expect(p("palmhelm://pair?host=192.0.2.5&code=%EF%BC%91%EF%BC%92%EF%BC%93%EF%BC%94%EF%BC%95%EF%BC%96") == nil) // 全角数字
        #expect(p("palmhelm://pair?host=192.0.2.5&code=123456&tls=1&fp=abc") == nil)
        #expect(p("palmhelm://pair?host=::1&code=123456")?.host == "::1")
    }
}
