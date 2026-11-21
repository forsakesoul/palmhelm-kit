import Foundation
import Testing
@testable import PalmhelmKit

/// 方向进度模式（directionalProgress，显式 opt-in）：行程 H、正向隐藏、反向立即恢复、idle 保持、无计时。
/// 旧模式（directional / anyDirectionIdle）的语义由各自的既有测试保证；这里另断言新接口对它们是空操作。
@Suite struct HeaderCollapseProgressTests {
    private let h: CGFloat = 100
    private func fresh() -> HeaderCollapseState { HeaderCollapseState(behavior: .directionalProgress) }
    private func start(_ c: inout HeaderCollapseState, at y: CGFloat = 1000) {
        c.phaseChanged(to: .interacting, at: 0)
        c.moved(to: y, user: true, layoutChanged: false, force: false, at: 0, chromeExtent: h)
    }
    private func move(_ c: inout HeaderCollapseState, to y: CGFloat, user: Bool = true, layout: Bool = false, force: Bool = false) {
        c.moved(to: y, user: user, layoutChanged: layout, force: force, at: 0, chromeExtent: h)
    }

    @Test func positiveDeltaHidesProportionallyAndReverseRevealsImmediately() {
        var c = fresh(); start(&c)
        move(&c, to: 1030)
        #expect(c.progress == 0.3)
        move(&c, to: 1020)
        #expect(c.progress == 0.2, "反向第一笔有效位移即恢复")
        move(&c, to: 1100)
        #expect(c.progress == 1 && c.hidden && c.visibleExtent == 0)
    }

    @Test func endpointsLeaveNoDebt() {
        var c = fresh(); start(&c)
        move(&c, to: 1500) // 远超 H
        #expect(c.progress == 1)
        move(&c, to: 1495)
        #expect(c.progress == 0.95, "p=1 后再滚 400pt，反向 5pt 就应露出 5pt")
        move(&c, to: 700) // 反向超过 H
        #expect(c.progress == 0)
        move(&c, to: 705)
        #expect(c.progress == 0.05, "p=0 后继续反向不欠账")
    }

    @Test func smallDeltasAccumulateAndNothingTimesOut() {
        var c = fresh(); start(&c)
        for i in 1...50 { move(&c, to: 1000 + CGFloat(i) * 0.4) } // 慢拖：每帧 0.4pt
        #expect(abs(c.progress - 0.2) < 1e-6)
        c.phaseChanged(to: .idle, at: 99)
        #expect(c.progress != 0 && c.deadline == nil && !c.expire(token: c.token, at: 1_000_000), "idle 保持，没有恢复计时")
        c.phaseChanged(to: .interacting, at: 200)
        #expect(abs(c.progress - 0.2) < 1e-6, "新一次手势从保持的进度继续")
    }

    @Test func onlyUserFramesDriveAndIsolatedPhasesDoNot() {
        var c = fresh(); start(&c)
        move(&c, to: 1040, user: false)
        #expect(c.progress == 0, "非用户帧只同步参考点")
        move(&c, to: 1050)
        #expect(c.progress == 0.1, "参考点已同步到 1040")
        c.phaseChanged(to: .idle, at: 0)
        c.phaseChanged(to: .decelerating, at: 0) // 孤立的减速：没有来自 interacting 的资格
        move(&c, to: 1200)
        #expect(c.progress == 0.1)
        c.phaseChanged(to: .animating, at: 0)
        move(&c, to: 1400)
        #expect(c.progress == 0.1, "程序化滚动不驱动")
        c.phaseChanged(to: .interacting, at: 0)
        c.phaseChanged(to: .decelerating, at: 0) // 惯性沿用拖动的资格
        move(&c, to: 1420)
        #expect(c.progress == 0.3)
    }

    @Test func layoutCorrectionOnlySyncsTheAnchor() {
        var c = fresh(); start(&c)
        move(&c, to: 1020)
        move(&c, to: 1520, layout: true) // 内容前插 / 流式增长造成的偏移修正
        #expect(c.progress == 0.2)
        move(&c, to: 1530)
        #expect(c.progress == 0.3, "后续合法帧立即继续，不需要静默")
    }

    @Test func forcePositionRevealsButTheSameGestureMayContinue() {
        var c = fresh(); start(&c)
        move(&c, to: 1060)
        move(&c, to: 0, force: true) // 到顶 / 真底：位置强制
        #expect(c.progress == 0)
        move(&c, to: 40)
        #expect(c.progress == 0.4, "离开边界可继续同一次手势")
    }

    @Test func resetIsAContextForceAndNeedsANewGesture() {
        var c = fresh(); start(&c)
        move(&c, to: 1060)
        c.reset()
        #expect(c.progress == 0 && !c.hidden)
        move(&c, to: 1200)
        #expect(c.progress == 0, "reset 清资格与参考点：之后要新的 interacting")
        c.phaseChanged(to: .interacting, at: 0)
        move(&c, to: 1210)
        move(&c, to: 1250)
        #expect(c.progress == 0.5)
    }

    @Test func invalidOrChangedExtentFailsOpenAndRestarts() {
        var c = fresh(); start(&c)
        move(&c, to: 1060)
        c.moved(to: 1100, user: true, layoutChanged: false, force: false, at: 0, chromeExtent: 0)
        #expect(c.progress == 0, "H 无效：失败开放")
        c.moved(to: 1100, user: true, layoutChanged: false, force: false, at: 0, chromeExtent: 80)
        c.moved(to: 1130, user: true, layoutChanged: false, force: false, at: 0, chromeExtent: 80)
        #expect(c.progress == 30.0 / 80)
        c.moved(to: 1160, user: true, layoutChanged: false, force: false, at: 0, chromeExtent: 120) // H 变化
        #expect(c.progress == 0)
        c.moved(to: .nan, user: true, layoutChanged: false, force: false, at: 0, chromeExtent: 120)
        #expect(c.progress == 0)
    }

    @Test func oldModesIgnoreTheExtentParameterAndStayUnchanged() {
        var d = HeaderCollapseState() // directional
        d.scrolled(to: 1000, userGesture: true, at: 5); d.scrolled(to: 1070, userGesture: true, at: 5.3)
        #expect(d.collapsed && d.progress == 1 && d.visibleExtent == 0)
        var a = HeaderCollapseState(behavior: .anyDirectionIdle)
        a.phaseChanged(to: .interacting, at: 10)
        a.moved(to: 1000, user: true, layoutChanged: false, force: false, at: 10.2, chromeExtent: 100)
        a.moved(to: 1060, user: true, layoutChanged: false, force: false, at: 10.3, chromeExtent: 100)
        #expect(a.collapsed, "anyDirectionIdle 的 60pt 规则不受新参数影响")
        a.phaseChanged(to: .idle, at: 10.4)
        #expect(a.deadline != nil, "idle 仍有 1 秒恢复计时")
    }

    @Test func theMeasurementEntryUpdatesTheExtentBeforeAnyGeometryFrame() {
        var c = fresh()
        c.setChromeExtent(100)
        #expect(c.visibleExtent == 100 && c.progress == 0, "首次测量：不等首个几何回调")
        start(&c); move(&c, to: 1030)
        #expect(c.visibleExtent == 70)
        c.setChromeExtent(160)
        #expect(c.visibleExtent == 160 && c.progress == 0, "H 变化：立即是新 H，从显示重新开始")
        var old = HeaderCollapseState(behavior: .anyDirectionIdle)
        old.setChromeExtent(160)
        #expect(old.visibleExtent == 0, "其它模式不受影响")
    }
}
