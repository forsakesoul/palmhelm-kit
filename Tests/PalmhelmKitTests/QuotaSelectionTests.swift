import XCTest
@testable import PalmhelmKit

final class QuotaSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var future: Int { Int(now.timeIntervalSince1970 * 1000) + 3_600_000 }

    func testWhitelistKeepsOnlyConfirmedWindows() {
        let claude = AccountSnapshot(provider: "claude", accountId: "c", windows: [
            AccountWindow(id: "five_hour:primary", usedPercent: 10, windowMins: 300),
            AccountWindow(id: "seven_day:primary", usedPercent: 20, windowMins: 10080),
            AccountWindow(id: "seven_day:fable", usedPercent: 30, windowMins: 10080),
            AccountWindow(id: "seven_day_opus:primary", usedPercent: 40, windowMins: 10080),
        ], source: "s", status: "ok")
        XCTAssertEqual(QuotaWindowPolicy.windows(of: claude).map(\.id), ["five_hour:primary", "seven_day:primary", "seven_day:fable"])
        let codex = AccountSnapshot(provider: "codex", accountId: "x", windows: [
            AccountWindow(id: "bucket0:primary", usedPercent: 42, windowMins: 300),
            AccountWindow(id: "bucket1:primary", usedPercent: 12, windowMins: 10080),
            AccountWindow(id: "bucket2:primary", usedPercent: 99, windowMins: 1440),
        ], source: "s", status: "ok")
        XCTAssertEqual(QuotaWindowPolicy.windows(of: codex).map(\.id), ["bucket0:primary", "bucket1:primary"])
    }

    func testDefaultPicksTightestValidSubscriptionAndSkipsApiAndFailures() {
        let api = AccountSnapshot(provider: "codex", accountId: "api", billingMode: "api", source: "s", status: "ok")
        let failed = AccountSnapshot(provider: "claude", accountId: "f", source: "s", status: "error")
        let loose = AccountSnapshot(provider: "codex", accountId: "a", windows: [AccountWindow(id: "bucket0:primary", usedPercent: 20, windowMins: 300, resetAt: future)], source: "s", status: "ok")
        let tight = AccountSnapshot(provider: "claude", accountId: "b", windows: [AccountWindow(id: "five_hour:primary", usedPercent: 61, windowMins: 300, resetAt: future)], source: "s", status: "ok")
        let picked = AccountSelection.tightest([api, failed, loose, tight], now: now)
        XCTAssertEqual(picked.map(AccountSelection.key), "claude|b")
    }

    func testSavedSelectionSurvivesRefreshAndFallsBackWhenGone() {
        let a = AccountSnapshot(provider: "codex", accountId: "a", windows: [AccountWindow(id: "bucket0:primary", usedPercent: 10, windowMins: 300, resetAt: future)], source: "s", status: "ok")
        let b = AccountSnapshot(provider: "claude", accountId: "b", windows: [AccountWindow(id: "five_hour:primary", usedPercent: 80, windowMins: 300, resetAt: future)], source: "s", status: "ok")
        XCTAssertEqual(AccountSelection.resolve(selectedKey: "codex|a", accounts: [b, a], now: now)?.accountId, "a")
        XCTAssertEqual(AccountSelection.resolve(selectedKey: "codex|gone", accounts: [a, b], now: now)?.accountId, "b")
    }

    func testPageStateMapping() {
        XCTAssertEqual(UsagePageState.from(hasData: true, loading: true, settled: false, error: "x", connected: false), .ready)
        XCTAssertEqual(UsagePageState.from(hasData: false, loading: false, settled: false, error: nil, connected: false), .disconnected)
        XCTAssertEqual(UsagePageState.from(hasData: false, loading: false, settled: true, error: "timeout", connected: true), .failed("timeout"))
        XCTAssertEqual(UsagePageState.from(hasData: false, loading: true, settled: false, error: nil, connected: true), .loading)
        XCTAssertEqual(UsagePageState.from(hasData: false, loading: false, settled: true, error: nil, connected: true), .empty)
    }
}
