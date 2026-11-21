import Testing
import Foundation
@testable import PalmhelmKit

// #98 接线审查 F1–F5（A1-146）：复用代次不撞号、无效观察不改身份、离线 working 不上移、页脚按工作区 ID。
@Suite struct SpaceWiringRegressionTests {
    private func item(_ label: String, _ term: String, online: Bool = true, working: Bool = false, ws: String = "w1") -> LensInput {
        let t = TargetSummary(projectName: label, online: online, targetId: label, status: working ? "working" : "idle",
                              location: TargetLocation(workspace: label), workspaceId: ws, terminalId: term)
        return LensInput(key: label, target: t, title: label, lastActivity: 1)
    }

    // F1：连续四次复用（每次标签与 terminal 都不同）得到四个不同的身份。
    @Test func repeatedReuseNeverRecyclesAGroupIdentity() {
        var d = SpaceOrderDocument()
        var ids: [String] = []
        for i in 0..<4 {
            let items = [item("name-\(i)", "term-\(i)")]
            SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: items, effective: true, frozen: false, generation: 1)
            ids.append(SpaceOrderSession.resolved(bridgeId: "b", items: items, document: d)[0].id)
        }
        #expect(Set(ids).count == ids.count, "identities=\(ids)")
    }

    // F1：第三代的置顶不被第四代继承。
    @Test func aNewerGenerationDoesNotInheritAPinnedOlderOne() {
        var d = SpaceOrderDocument()
        let first = [item("n0", "t0")]
        SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: first, effective: true, frozen: false, generation: 1)
        let id2 = { (n: Int) -> String in
            let items = [item("n\(n)", "t\(n)")]
            SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: items, effective: true, frozen: false, generation: 1)
            return SpaceOrderSession.resolved(bridgeId: "b", items: items, document: d)[0].id
        }
        _ = id2(1)
        let pinnedOne = id2(2)
        d.state = SpaceOrderReducer.reduce(d.state, .pin(pinnedOne))
        let fourth = id2(3)
        #expect(!d.state.pinned.contains(fourth) && d.state.pinned == [pinnedOne])
    }

    // F2：无效观察不得改动身份证据；之后有效快照仍命中原置顶组。
    @Test func ineffectiveSnapshotDoesNotChangeIdentityEvidence() {
        var d = SpaceOrderDocument()
        let valid = [item("alpha", "t1")]
        SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: valid, effective: true, frozen: false, generation: 3)
        let original = SpaceOrderSession.resolved(bridgeId: "b", items: valid, document: d)[0].id
        d.state = SpaceOrderReducer.reduce(d.state, .pin(original))
        let before = d.fingerprints
        let ids = d.groupIds
        SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: [item("other", "t2")], effective: false, frozen: true, generation: 3)
        #expect(d.fingerprints == before && d.groupIds == ids, "an ineffective snapshot changed identity state")
        let restored = SpaceOrderSession.resolved(bridgeId: "b", items: valid, document: d)[0].id
        #expect(restored == original && d.state.pinned.contains(restored), "the valid original group keeps its pin")
    }

    // F2：过期代次的快照不改身份。
    @Test func staleGenerationSnapshotDoesNotChangeIdentity() {
        var d = SpaceOrderDocument()
        SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: [item("alpha", "t1")], effective: true, frozen: false, generation: 5)
        let before = d.fingerprints
        SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: [item("zeta", "t9")], effective: true, frozen: false, generation: 2)
        #expect(d.fingerprints == before)
    }

    // F4：离线的 working 成员不上移，也不消耗一次性标记。
    @Test func offlineWorkingDoesNotPromoteOrConsumeThePromotion() {
        var d = SpaceOrderDocument()
        let items = [item("alpha", "t1"), item("beta", "t2", online: false, working: true, ws: "w2")]
        SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: items, effective: true, frozen: false, generation: 1)
        #expect(d.state.promoted.isEmpty)
        let back = [item("alpha", "t1"), item("beta", "t2", online: true, working: true, ws: "w2")]
        SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: back, effective: true, frozen: false, generation: 1)
        #expect(d.state.promoted == ["b|ws|w2"], "once back online the group is promoted")
    }

    // F5：同名工作区按工作区 ID 取页脚（计数不同即不同）。
    @Test func footersMatchTheWorkspaceIdNotTheLabel() {
        var d = SpaceOrderDocument()
        let items = [item("same", "t1", ws: "w1"), item("same", "t2", ws: "w2")]
        let spaces = [SpaceInfo(workspace: "same", agentlessTabCount: 1, workspaceId: "w1"), SpaceInfo(workspace: "same", agentlessTabCount: 2, workspaceId: "w2")]
        let sections = SpaceOrderSession.sections(bridgeId: "b", items: items, spaces: spaces, document: d)
        #expect(sections.count == 2 && sections[0].footer != sections[1].footer, "footers: \(sections.map(\.footer))")
        d = SpaceOrderDocument()
    }

    // F3：失效入口清除待应用的上移。
    @Test func invalidateDropsDeferredPromotions() {
        var d = SpaceOrderDocument()
        let idle = [item("alpha", "t1"), item("beta", "t2", ws: "w2")]
        SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: idle, effective: true, frozen: false, generation: 1)
        let running = [item("alpha", "t1"), item("beta", "t2", working: true, ws: "w2")]
        SpaceOrderSession.applySnapshot(&d, bridgeId: "b", items: running, effective: true, frozen: true, generation: 1)
        #expect(!d.state.pending.isEmpty)
        SpaceOrderSession.invalidate(&d)
        SpaceOrderSession.reenter(&d, bridgeId: "b", items: running, effective: true)
        #expect(SpaceOrderSession.sections(bridgeId: "b", items: idle, spaces: nil, document: d).first?.title == "alpha", "invalidated promotions are not applied")
    }
}

// h91：边界与置顶区的可移动判定（读屏动作按它禁用）。
@Suite struct SpaceMoveBoundaryTests {
    @Test func boundariesAndPinnedSectionAreReportedAsNotMovable() {
        var d = SpaceOrderDocument()
        d.state.layout = ["a", "b", "c"]
        d.state.pinned = []
        let visible = ["a", "b", "c"]
        #expect(!SpaceOrderSession.canMove(d, id: "a", delta: -1, visible: visible), "the first group cannot move up")
        #expect(!SpaceOrderSession.canMove(d, id: "c", delta: 1, visible: visible), "the last group cannot move down")
        #expect(SpaceOrderSession.canMove(d, id: "b", delta: -1, visible: visible))
        d.state.pinned = ["a"]
        d.state.layout = ["b", "c"]
        let pinnedVisible = ["a", "b", "c"]
        #expect(!SpaceOrderSession.canMove(d, id: "b", delta: -1, visible: pinnedVisible), "a regular group cannot cross the pinned section")
        #expect(!SpaceOrderSession.canMove(d, id: "a", delta: 1, visible: pinnedVisible), "a single pinned group has no pinned neighbour")
    }

    /// A1 探针：隐藏的置顶组不能占用“一位”——上移必须真的改变可见顺序。
    @Test func movingUpSkipsAHiddenPinnedGroupAndKeepsItsPreference() {
        var d = SpaceOrderDocument()
        d.state.pinned = ["a", "hidden", "c"]
        d.state.layout = ["z"]
        let visible = ["a", "c", "z"]
        #expect(SpaceOrderSession.canMove(d, id: "c", delta: -1, visible: visible))
        SpaceOrderSession.move(&d, id: "c", delta: -1, visible: visible)
        #expect(SpaceOrderReducer.project(d.state, visible: Set(visible)).pinned == ["c", "a"], "moving up must change the visible position")
        #expect(d.state.pinned == ["c", "a", "hidden"], "the hidden preference is kept, not dropped or reordered")
    }

    /// A1 探针：最后一个可见置顶组不能借隐藏组“下移”进普通区。
    @Test func lastVisiblePinCannotMoveIntoTheRegularSection() {
        var d = SpaceOrderDocument()
        d.state.pinned = ["a", "hidden"]
        d.state.layout = ["z"]
        #expect(!SpaceOrderSession.canMove(d, id: "a", delta: 1, visible: ["a", "z"]))
        SpaceOrderSession.move(&d, id: "a", delta: 1, visible: ["a", "z"])
        #expect(d.state.pinned == ["a", "hidden"], "a refused move leaves the preference untouched")
    }

    /// 隐藏组在中间：下移一位跨过隐藏组到下一个可见置顶组之后。
    @Test func movingDownSkipsAHiddenPinnedGroupInTheMiddle() {
        var d = SpaceOrderDocument()
        d.state.pinned = ["a", "hidden", "c"]
        d.state.layout = ["z"]
        let visible = ["a", "c", "z"]
        SpaceOrderSession.move(&d, id: "a", delta: 1, visible: visible)
        #expect(SpaceOrderReducer.project(d.state, visible: Set(visible)).pinned == ["c", "a"])
        #expect(d.state.pinned == ["hidden", "c", "a"])
    }

    /// 隐藏组在最前：上移第一个可见置顶组不可行（它已经是可见的第一位），下移正常。
    @Test func hiddenPinnedGroupAtTheFrontDoesNotCountAsAPosition() {
        var d = SpaceOrderDocument()
        d.state.pinned = ["hidden", "a", "c"]
        d.state.layout = ["z"]
        let visible = ["a", "c", "z"]
        #expect(!SpaceOrderSession.canMove(d, id: "a", delta: -1, visible: visible), "a is already the first visible pin")
        #expect(SpaceOrderSession.canMove(d, id: "c", delta: -1, visible: visible))
        SpaceOrderSession.move(&d, id: "c", delta: -1, visible: visible)
        #expect(SpaceOrderReducer.project(d.state, visible: Set(visible)).pinned == ["c", "a"])
    }

    /// 普通组上移时，隐藏的普通组偏好留在原地，目标是可见的前一组。
    @Test func regularMoveKeepsHiddenLayoutEntriesInPlace() {
        var d = SpaceOrderDocument()
        d.state.layout = ["h2", "b", "c"]
        let visible = ["b", "c"]
        SpaceOrderSession.move(&d, id: "c", delta: -1, visible: visible)
        #expect(d.state.layout == ["h2", "c", "b"])
    }
}
