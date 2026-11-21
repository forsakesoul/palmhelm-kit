import Foundation
import Testing
@testable import PalmhelmKit

/// 头部收起的不分方向 + idle 恢复模式（anyDirectionIdle，显式 opt-in）：纯状态，时钟由调用者显式传入。
/// 默认 directional 的行为由 HeaderCollapseRulesTests 保证不变；这里同时断言两种模式互不影响。
@Suite struct HeaderCollapseIdleModeTests {
    private func fresh() -> HeaderCollapseState { HeaderCollapseState(behavior: .anyDirectionIdle) }

    /// interacting 起步 → 0.2s 定参考点 → 净位移 delta（时刻 t+0.3）。
    private func drag(_ c: inout HeaderCollapseState, from y: CGFloat = 1000, delta: CGFloat, at t: Double = 10) {
        c.phaseChanged(to: .interacting, at: t)
        c.moved(to: y, user: true, layoutChanged: false, force: false, at: t + 0.2)
        c.moved(to: y + delta, user: true, layoutChanged: false, force: false, at: t + 0.3)
    }

    private func expired(_ c: inout HeaderCollapseState, _ token: Int, at t: Double) -> Bool { c.expire(token: token, at: t) }

    private func hidden(at t: Double = 10) -> HeaderCollapseState { var c = fresh(); drag(&c, delta: 100, at: t); return c }

    // MARK: 兼容

    @Test func theDefaultStaysDirectionalAndIgnoresTheIdleApi() {
        var c = HeaderCollapseState()
        #expect(c.behavior == .directional)
        c.phaseChanged(to: .interacting, at: 1)
        c.moved(to: 1000, user: true, layoutChanged: false, force: false, at: 1.2)
        c.moved(to: 1100, user: true, layoutChanged: false, force: false, at: 1.3)
        #expect(!c.collapsed && c.deadline == nil, "directional 状态不响应新接口")
        c.scrolled(to: 1000, userGesture: true, at: 5); c.scrolled(to: 1070, userGesture: true, at: 5.3)
        #expect(c.collapsed, "原有方向规则不变")
        c.scrolled(to: 1040, userGesture: true, at: 6); c.scrolled(to: 1010, userGesture: true, at: 6.1)
        #expect(!c.collapsed, "directional：反向 24pt 展开（不分方向模式不用它）")
    }

    // MARK: 触发（60 / 150ms / 抖动 / 反向）

    @Test func collapsesAtSixtyInEitherDirectionAndNotAtFiftyNine() {
        for sign: CGFloat in [1, -1] {
            var c = fresh()
            drag(&c, delta: sign * 59)
            #expect(!c.hidden, "59pt 不收起（\(sign)）")
            var d = fresh()
            drag(&d, delta: sign * 60)
            #expect(d.hidden, "60pt 收起（\(sign)）")
        }
    }

    @Test func theFirstHundredFiftyMillisecondsOnlySyncTheReference() {
        var c = fresh()
        c.phaseChanged(to: .interacting, at: 10)
        c.moved(to: 1000, user: true, layoutChanged: false, force: false, at: 10.0)
        c.moved(to: 1200, user: true, layoutChanged: false, force: false, at: 10.1)
        #expect(!c.hidden)
        c.moved(to: 1259, user: true, layoutChanged: false, force: false, at: 10.2)
        #expect(!c.hidden)
        c.moved(to: 1260, user: true, layoutChanged: false, force: false, at: 10.21)
        #expect(c.hidden)
    }

    @Test func jitterDoesNotAccumulateByPathLengthAndReversalDoesNotReveal() {
        var c = fresh()
        c.phaseChanged(to: .interacting, at: 10)
        c.moved(to: 1000, user: true, layoutChanged: false, force: false, at: 10.0)
        var y: CGFloat = 1000
        for i in 0..<60 { y += i.isMultiple(of: 2) ? 6 : -6; c.moved(to: y, user: true, layoutChanged: false, force: false, at: 10.2 + Double(i) * 0.016) }
        #expect(!c.hidden, "来回 6pt 抖动路程累计远超 60 也不收起")
        var h = hidden()
        h.moved(to: 1040, user: true, layoutChanged: false, force: false, at: 10.4); h.moved(to: 900, user: true, layoutChanged: false, force: false, at: 10.5)
        #expect(h.hidden, "反向（含 24pt 以上）不立即展开")
    }

    @Test func layoutSettleSuppressesAndNonUserGeometryOnlyResetsTheReference() {
        var c = fresh()
        c.phaseChanged(to: .interacting, at: 10)
        c.moved(to: 1000, user: true, layoutChanged: false, force: false, at: 10.2)
        c.moved(to: 1100, user: true, layoutChanged: true, force: false, at: 10.3)   // 布局变化：静默 300ms
        #expect(!c.hidden)
        c.moved(to: 1300, user: false, layoutChanged: false, force: false, at: 10.7)  // 非用户：只重定参考
        #expect(!c.hidden)
        c.moved(to: 1359, user: true, layoutChanged: false, force: false, at: 10.8)
        #expect(!c.hidden)
        c.moved(to: 1360, user: true, layoutChanged: false, force: false, at: 10.9)
        #expect(c.hidden)
    }

    // MARK: 强制显示与重置

    @Test func forceShowsAndWinsOverEveryGateAndDoesNotRestoreOldHidden() {
        var c = hidden()
        c.moved(to: 0, user: true, layoutChanged: false, force: true, at: 11)
        #expect(!c.hidden && c.deadline == nil)
        c.moved(to: 5, user: true, layoutChanged: false, force: false, at: 11.1)
        #expect(!c.hidden, "强制条件解除不恢复旧的收起；旧累计已清")
    }

    @Test func resetShowsClearsDeadlineAndInvalidatesTheOldTicket() {
        var c = hidden()
        c.phaseChanged(to: .idle, at: 12)
        let old = c.token
        c.reset()
        #expect(!c.hidden && c.deadline == nil)
        #expect(c.token > old)
        #expect(!expired(&c, old, at: 20), "reset 前的票据无效")
        // reset 后同一次拖动不再有效：必须有新的 interacting
        c.moved(to: 1000, user: true, layoutChanged: false, force: false, at: 21)
        c.moved(to: 1100, user: true, layoutChanged: false, force: false, at: 21.5)
        #expect(!c.hidden)
    }

    // MARK: 恢复（idle + 1 秒）

    @Test func restoresOneSecondAfterTheRealIdleNotAfterDeceleration() {
        var c = hidden()
        #expect(c.hidden)
        c.phaseChanged(to: .decelerating, at: 10.5)
        #expect(c.deadline == nil, "惯性不开始倒计时")
        c.phaseChanged(to: .idle, at: 12)
        let token = c.token
        #expect(c.deadline == 13)
        #expect(!expired(&c, token, at: 12.999), "idle + 0.999 不显示")
        #expect(c.hidden)
        #expect(expired(&c, token, at: 13.0), "idle + 1.000 显示")
        #expect(!c.hidden && c.deadline == nil)
        #expect(!expired(&c, token, at: 14), "同一恢复到期后即结束")
    }

    @Test func repeatedIdleDoesNotExtendAndNewTouchCancels() {
        var c = hidden()
        c.phaseChanged(to: .idle, at: 12)
        c.moved(to: 1100, user: false, layoutChanged: true, force: false, at: 12.5)
        c.phaseChanged(to: .idle, at: 12.6)
        #expect(c.deadline == 13, "不被几何帧也不被重复 idle 续期")
        let old = c.token
        c.phaseChanged(to: .tracking, at: 12.8)
        #expect(c.deadline == nil, "重新 tracking 使旧 deadline 失效")
        #expect(!expired(&c, old, at: 13.5))
        c.phaseChanged(to: .idle, at: 20)
        #expect(!expired(&c, old, at: 21), "旧票据对新 deadline 同样无效")
        #expect(expired(&c, c.token, at: 21))
    }

    @Test func programmaticScrollNeitherAccumulatesNorBlocksTheFinalRestoreAndExpiryNeedsIdle() {
        var c = hidden()
        c.phaseChanged(to: .idle, at: 12)
        c.phaseChanged(to: .animating, at: 12.4)
        #expect(c.deadline == nil)
        c.moved(to: 5000, user: false, layoutChanged: false, force: false, at: 12.5)
        c.phaseChanged(to: .idle, at: 13)
        #expect(c.deadline == 14)
        var d = hidden()
        d.phaseChanged(to: .idle, at: 12)
        let token = d.token
        d.phaseChanged(to: .animating, at: 12.5)
        #expect(!expired(&d, token, at: 13), "到期要求仍在 idle")
        #expect(expired(&c, c.token, at: 14))
    }

    @Test func idleWhileShownSchedulesNothing() {
        var c = fresh()
        c.phaseChanged(to: .interacting, at: 10)
        c.phaseChanged(to: .idle, at: 11)
        #expect(c.deadline == nil, "没有收起就不安排恢复")
    }
}
