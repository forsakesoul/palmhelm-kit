import Foundation
import Testing
@testable import PalmhelmKit

// 会话页头部：收起需要累计 60pt，展开需要反向 24pt（或到顶）；手势起始 150ms 不判定；静默期与切换迟滞；120Hz 布局修正不翻转。
@Suite struct HeaderCollapseRulesTests {
    @Test func thresholdsAreSixtyToCollapseTwentyFourToExpand() {
        #expect(HeaderCollapseRules.collapseThreshold == 60)
        #expect(HeaderCollapseRules.expandThreshold == 24)
        #expect(HeaderCollapseRules.gestureLeadSeconds == 0.15)
        #expect(HeaderCollapseRules.next(previousOffset: 100, newOffset: 160, atTop: false, collapsed: false))
        #expect(!HeaderCollapseRules.next(previousOffset: 100, newOffset: 159, atTop: false, collapsed: false))
        #expect(!HeaderCollapseRules.next(previousOffset: 100, newOffset: 76, atTop: false, collapsed: true))
    }

    @Test func fingerJitterBelowThresholdNeverToggles() {
        var s = HeaderCollapseState()
        s.scrolled(to: 1000, userGesture: true, at: 0)
        s.gestureBegan(at: 0)
        for i in 1...20 { s.scrolled(to: 1000 + CGFloat(i % 2 == 0 ? 6 : 0), userGesture: true, at: 0.2 + Double(i) * 0.02) }
        #expect(!s.collapsed)
    }

    @Test func scrollingFortyPointsDoesNotCollapseButSixtyDoes() {
        var s = HeaderCollapseState()
        s.scrolled(to: 1000, userGesture: true, at: 0)
        s.gestureBegan(at: 0)
        s.scrolled(to: 1040, userGesture: true, at: 0.5)   // 刚开始滚 40pt：不收起
        #expect(!s.collapsed)
        s.scrolled(to: 1060, userGesture: true, at: 0.7)   // 累计 60pt：收起
        #expect(s.collapsed)
    }

    @Test func gestureLeadWindowIgnoresEarlyMovement() {
        var s = HeaderCollapseState()
        s.scrolled(to: 1000, userGesture: true, at: 0)
        s.gestureBegan(at: 1.0)
        s.scrolled(to: 1080, userGesture: true, at: 1.1)   // 150ms 内移动 80pt：只同步参考点
        #expect(!s.collapsed)
        s.scrolled(to: 1140, userGesture: true, at: 1.5)   // 之后累计 60pt：收起
        #expect(s.collapsed)
    }

    @Test func expandNeedsReverseTwentyFourPoints() {
        var s = HeaderCollapseState()
        s.scrolled(to: 1000, userGesture: true, at: 0)
        s.gestureBegan(at: 0)
        s.scrolled(to: 1070, userGesture: true, at: 0.5)   // 收起
        #expect(s.collapsed)
        s.scrolled(to: 1055, userGesture: true, at: 1.0)   // 反向 15pt：不展开
        #expect(s.collapsed)
        s.scrolled(to: 1046, userGesture: true, at: 1.5)   // 反向累计 24pt：展开
        #expect(!s.collapsed)
    }

    @Test func atTopAlwaysExpands() {
        var s = HeaderCollapseState()
        s.scrolled(to: 0, userGesture: true, at: 0)
        s.gestureBegan(at: 0)
        s.scrolled(to: 80, userGesture: true, at: 0.5)
        #expect(s.collapsed)
        s.scrolled(to: 0, userGesture: true, at: 1.0)
        #expect(!s.collapsed)
    }

    @Test func programmaticAndSettlingFramesOnlyMoveTheAnchor() {
        var s = HeaderCollapseState()
        s.scrolled(to: 5000, userGesture: false, at: 0)
        s.scrolled(to: 5300, userGesture: false, at: 1)
        #expect(!s.collapsed, "程序化跟底不收起")
        s.layoutChanged(at: 2)
        s.gestureBegan(at: 2)
        s.scrolled(to: 5400, userGesture: true, at: 2.2)   // 静默期内的修正
        #expect(!s.collapsed)
    }

    @Test func resetExpandsAndClearsAllWindows() {
        var s = HeaderCollapseState()
        s.scrolled(to: 0, userGesture: true, at: 0)
        s.gestureBegan(at: 0)
        s.scrolled(to: 80, userGesture: true, at: 0.5)
        s.reset()
        #expect(!s.collapsed)
        s.scrolled(to: 0, userGesture: true, at: 0.51)
        s.gestureBegan(at: 0.52)
        s.scrolled(to: 80, userGesture: true, at: 0.9)
        #expect(s.collapsed, "重置后立即可以判定，不受旧窗口影响")
    }

    @Test func settleWindowAfterSwitchBlocksImmediateFlip() {
        var s = HeaderCollapseState()
        s.scrolled(to: 1000, userGesture: true, at: 0)
        s.gestureBegan(at: 0)
        s.scrolled(to: 1070, userGesture: true, at: 0.5)   // 收起，静默到 0.8
        s.scrolled(to: 1000, userGesture: true, at: 0.6)   // 静默期内：只同步参考点
        #expect(s.collapsed)
    }

    // 真机 120Hz：收起动画 200ms 内，每 8ms 一次几何回调，偏移被系统连续修正（总计远超 60pt），都标记为用户手势。
    // 时间静默窗口应挡住整段动画，不翻转；静默结束后真正的手指移动仍然生效。
    @Test func oneHundredTwentyHertzLayoutAnimationDoesNotFlip() {
        var s = HeaderCollapseState()
        s.scrolled(to: 7000, userGesture: true, at: 0)
        s.gestureBegan(at: 0)
        var t = 0.0
        var y: CGFloat = 7000
        s.layoutChanged(at: 0.0)
        while t < 0.2 {
            t += 0.008
            y += 3
            s.layoutChanged(at: t)
            s.scrolled(to: y, userGesture: true, at: t)
        }
        #expect(!s.collapsed, "动画期间的修正不能触发收起")
        s.gestureBegan(at: t + 0.4)
        s.scrolled(to: y + 70, userGesture: true, at: t + 0.6)
        #expect(s.collapsed)
    }
}
