import Testing
@testable import PalmhelmKit

// #85（A1-059）：重连退避、路径变化触发、蜂窝下的地址后置。纯规则，不碰网络。
@Suite struct ReconnectPolicyTests {
    private typealias P = ReconnectPolicy

    @Test func backoffDoublesFromOneSecondAndCapsAtThirty() {
        let middle = 0.5 // 抖动取中间值：因子为 1
        #expect(P.delay(attempt: 1, jitter: middle) == 1)
        #expect(P.delay(attempt: 2, jitter: middle) == 2)
        #expect(P.delay(attempt: 3, jitter: middle) == 4)
        #expect(P.delay(attempt: 4, jitter: middle) == 8)
        #expect(P.delay(attempt: 5, jitter: middle) == 16)
        #expect(P.delay(attempt: 6, jitter: middle) == 30, "32 秒被上限截到 30")
        #expect(P.delay(attempt: 40, jitter: middle) == 30, "很多次失败后仍不超过上限")
    }

    @Test func jitterStaysWithinTwentyPercentAndNeverExceedsTheCap() {
        #expect(abs(P.delay(attempt: 3, jitter: 0) - 3.2) < 0.0001, "4s × 0.8")
        #expect(abs(P.delay(attempt: 3, jitter: 1) - 4.8) < 0.0001, "4s × 1.2")
        #expect(P.delay(attempt: 6, jitter: 1) == 30, "上限后的抖动不超过 30")
        #expect(abs(P.delay(attempt: 1, jitter: -5) - 0.8) < 0.0001, "随机数越界时夹到 0 对应的下界")
        #expect(abs(P.delay(attempt: 1, jitter: 9) - 1.2) < 0.0001, "随机数越界时夹到 1 对应的上界")
    }

    private func sig(_ satisfied: Bool, wifi: Bool = false, cellular: Bool = false, vpn: Bool = false) -> P.PathSignature {
        .init(satisfied: satisfied, wifi: wifi, cellular: cellular, vpn: vpn)
    }

    @Test func firstSampleNeverTriggers() {
        #expect(P.pathChangeNeedsReconnect(old: nil, new: sig(true, wifi: true)) == false)
    }

    @Test func unavailableToAvailableTriggers() {
        #expect(P.pathChangeNeedsReconnect(old: sig(false), new: sig(true, cellular: true)) == true)
    }

    @Test func interfaceOrVpnChangeTriggers() {
        #expect(P.pathChangeNeedsReconnect(old: sig(true, wifi: true), new: sig(true, cellular: true)) == true, "Wi‑Fi → 蜂窝")
        #expect(P.pathChangeNeedsReconnect(old: sig(true, cellular: true), new: sig(true, cellular: true, vpn: true)) == true, "VPN 出现")
        #expect(P.pathChangeNeedsReconnect(old: sig(true, cellular: true, vpn: true), new: sig(true, cellular: true)) == true, "VPN 消失")
    }

    @Test func unchangedOrBecomingUnavailableDoesNotTrigger() {
        #expect(P.pathChangeNeedsReconnect(old: sig(true, wifi: true), new: sig(true, wifi: true)) == false)
        #expect(P.pathChangeNeedsReconnect(old: sig(true, cellular: true), new: sig(false)) == false, "掉线交给重连环，不在这里抢先重连")
    }

    @Test func cellularOnlyMeansCellularWithoutWifi() {
        #expect(sig(true, cellular: true).cellularOnly)
        #expect(sig(true, wifi: true, cellular: true).cellularOnly == false)
        #expect(sig(true, wifi: true).cellularOnly == false)
    }
}

@Suite struct CellularEndpointOrderTests {
    private let lan = BridgeEndpoint(host: "192.168.5.12", port: 47821, transport: .https)
    private let ts = BridgeEndpoint(host: "mac.tailnet.ts.net", port: 47821, transport: .https)
    private let loop = BridgeEndpoint(host: "127.0.0.1", port: 47821, transport: .http)

    @Test func withoutCellularOnlyTheOrderIsUnchanged() {
        #expect(EndpointRotation.order([lan, ts, loop], preferred: 1) == [1, 0, 2], "首选优先，其余按 局域网 → 域名 → 回环")
    }

    @Test func cellularOnlyPutsLanLiteralAfterTheHostnameEvenWhenPreferred() {
        #expect(EndpointRotation.order([lan, ts, loop], preferred: 0, cellularOnly: true) == [1, 0, 2], "蜂窝下域名先于局域网字面量")
    }

    @Test func scanReordersWhenTheCellularStateChanges() {
        var scan = EndpointScan()
        let eps = [lan, ts, loop]
        #expect(scan.plan(endpoints: eps, preferred: 0) == [0, 1, 2])
        #expect(scan.plan(endpoints: eps, preferred: 0, cellularOnly: true) == [1, 0, 2], "进入蜂窝即重排")
    }
}
