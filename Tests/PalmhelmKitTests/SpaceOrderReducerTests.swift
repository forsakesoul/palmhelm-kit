import Testing
import Foundation
@testable import PalmhelmKit

// #98 空间分组排序的纯 reducer（合成数据，不读时钟）：原型六个场景 + 排序细节 + 有效观察门禁。
@Suite struct SpaceOrderReducerTests {
    private func g(_ id: String, _ label: String, running: Bool = false, other: Bool = false, terms: Set<String> = []) -> SpaceGroupObservation {
        SpaceGroupObservation(id: id, label: label, running: running, isOther: other, terminalIds: terms)
    }

    private func snap(_ s: SpaceOrderState, _ groups: [SpaceGroupObservation], effective: Bool = true, frozen: Bool = false, gen: Int = 1) -> SpaceOrderState {
        SpaceOrderReducer.reduce(s, .snapshot(groups: groups, effective: effective, frozen: frozen, generation: gen))
    }

    /// 初始：按名称排序（alpha、beta、gamma），“其他”在最后。
    private let initial: [SpaceGroupObservation] = [
        SpaceGroupObservation(id: "alpha", label: "alpha", running: false),
        SpaceGroupObservation(id: "beta", label: "beta", running: false),
        SpaceGroupObservation(id: "gamma", label: "gamma", running: false),
        SpaceGroupObservation(id: "other", label: "其他", running: false, isOther: true),
    ]

    private func rest(_ s: SpaceOrderState) -> [String] { s.layout }

    @Test func autoOrderIsByNameWithOtherLast() {
        #expect(SpaceOrderReducer.autoOrder(initial) == ["alpha", "beta", "gamma", "other"])
    }

    // 场景 1：首次有效运行整组上移一次。
    @Test func firstEffectiveRunMovesTheGroupToTheTopOnce() {
        var s = snap(SpaceOrderState(), initial)
        #expect(rest(s) == ["alpha", "beta", "gamma", "other"])
        s = snap(s, initial.map { $0.id == "gamma" ? g("gamma", "gamma", running: true) : $0 })
        #expect(rest(s) == ["gamma", "alpha", "beta", "other"])
        #expect(s.promoted == ["gamma"])
    }

    // 场景 2：运行结束不回落；再次运行不争顶。
    @Test func endingDoesNotFallBackAndRerunningDoesNotFightForTop() {
        var s = snap(SpaceOrderState(), initial)
        s = snap(s, initial.map { $0.id == "gamma" ? g("gamma", "gamma", running: true) : $0 })
        s = snap(s, initial.map { $0.id == "gamma" ? g("gamma", "gamma", running: false) : $0 })
        #expect(rest(s).first == "gamma", "ending must not move it back")
        s = snap(s, initial.map { $0.id == "alpha" ? g("alpha", "alpha", running: true) : $0 })
        // alpha 首次有效运行：上移到第 1 位；gamma 之前的上移不被撤销，只是退到第 2 位。
        #expect(rest(s) == ["alpha", "gamma", "beta", "other"])
        // 再次运行与结束都不再移动已上移的组。
        s = snap(s, initial.map { $0.id == "alpha" ? g("alpha", "alpha", running: false) : $0 })
        s = snap(s, initial.map { $0.id == "alpha" ? g("alpha", "alpha", running: true) : $0 })
        #expect(rest(s) == ["alpha", "gamma", "beta", "other"], "a rerun does not move an already promoted group again")
    }

    // 场景 3：浏览时冻结；离开列表再回来才静默应用。
    @Test func frozenViewDoesNotReorderAndReenterAppliesSilently() {
        var s = snap(SpaceOrderState(), initial)
        let running = initial.map { $0.id == "beta" ? g("beta", "beta", running: true) : $0 }
        s = snap(s, running, frozen: true)
        #expect(rest(s) == ["alpha", "beta", "gamma", "other"], "visible list must not reorder")
        #expect(s.pending == ["beta"])
        s = SpaceOrderReducer.reduce(s, .reenter(groups: running, effective: true))
        #expect(rest(s).first == "beta")
        #expect(s.pending.isEmpty)
    }

    @Test func pendingPromotionIsDroppedIfTheGroupStoppedRunning() {
        var s = snap(SpaceOrderState(), initial)
        s = snap(s, initial.map { $0.id == "beta" ? g("beta", "beta", running: true) : $0 }, frozen: true)
        s = SpaceOrderReducer.reduce(s, .reenter(groups: initial, effective: true))
        #expect(rest(s) == ["alpha", "beta", "gamma", "other"], "re-verified: not running any more, so no move")
    }

    // 场景 4：置顶区固定在顶部，区内保持置顶的先后；普通组的运行不改变它。
    @Test func pinnedGroupsStayAtTheTopInTheirOwnOrder() {
        var s = snap(SpaceOrderState(), initial)
        s = SpaceOrderReducer.reduce(s, .pin("gamma"))
        s = SpaceOrderReducer.reduce(s, .pin("alpha"))
        #expect(s.pinned == ["gamma", "alpha"])
        s = snap(s, initial.map { $0.id == "beta" ? g("beta", "beta", running: true) : $0 })
        let p = SpaceOrderReducer.project(s, visible: ["alpha", "beta", "gamma", "other"])
        #expect(p.pinned == ["gamma", "alpha"])
        #expect(p.rest.first == "beta")
    }

    @Test func unpinReturnsToTheRememberedAnchor() {
        var s = snap(SpaceOrderState(), initial)
        s = SpaceOrderReducer.reduce(s, .pin("beta")) // 锚点：alpha
        s = SpaceOrderReducer.reduce(s, .unpin("beta"))
        #expect(s.layout == ["alpha", "beta", "gamma", "other"])
        s = SpaceOrderReducer.reduce(s, .pin("alpha")) // 锚点：空（最前）
        s = SpaceOrderReducer.reduce(s, .unpin("alpha"))
        #expect(s.layout.first == "alpha")
    }

    @Test func pinMoveStaysWithinTheSection() {
        var s = snap(SpaceOrderState(), initial)
        s = SpaceOrderReducer.reduce(s, .pin("alpha"))
        s = SpaceOrderReducer.reduce(s, .pin("beta"))
        s = SpaceOrderReducer.reduce(s, .pinMove(key: "beta", delta: -5))
        #expect(s.pinned == ["beta", "alpha"])
        s = SpaceOrderReducer.reduce(s, .pinMove(key: "beta", delta: 9))
        #expect(s.pinned == ["alpha", "beta"])
    }

    // 场景 5：拖动后的组停在原处，不再被运行移动；其余组仍按运行上移。
    @Test func draggedGroupStaysPutWhileOthersStillPromote() {
        var s = snap(SpaceOrderState(), initial)
        s = SpaceOrderReducer.reduce(s, .move(key: "gamma", before: "alpha"))
        #expect(rest(s) == ["gamma", "alpha", "beta", "other"])
        s = snap(s, initial.map { $0.id == "gamma" || $0.id == "beta" ? g($0.id, $0.label, running: true) : $0 })
        // gamma 是手动槽位（第 1 位），不被挤动；自动槽位内 beta 上移到其余自动组之前。
        #expect(rest(s) == ["gamma", "beta", "alpha", "other"], "the manual slot stays put; only automatic slots reorder")
        #expect(!s.promoted.contains("gamma"))
    }

    // 场景 6：设置里的重置回到自动规则，清除置顶、拖动与上移记录。
    @Test func resetReturnsToTheAutomaticRule() {
        var s = snap(SpaceOrderState(), initial)
        s = snap(s, initial.map { $0.id == "gamma" ? g("gamma", "gamma", running: true) : $0 })
        s = SpaceOrderReducer.reduce(s, .pin("beta"))
        s = SpaceOrderReducer.reduce(s, .move(key: "alpha", before: nil))
        s = SpaceOrderReducer.reduce(s, .reset(groups: initial))
        #expect(s.layout == ["alpha", "beta", "gamma", "other"])
        #expect(s.pinned.isEmpty && s.manual.isEmpty && s.promoted.isEmpty && s.anchors.isEmpty)
        s = snap(s, initial.map { $0.id == "gamma" ? g("gamma", "gamma", running: true) : $0 })
        #expect(rest(s).first == "gamma", "after a reset the next run promotes again")
    }

    // 排序细节：同批按当前序；幂等；代次过期。
    @Test func sameBatchFollowsTheCurrentOrderNotArrival() {
        var s = snap(SpaceOrderState(), initial)
        s = snap(s, initial.map { $0.id == "gamma" || $0.id == "alpha" ? g($0.id, $0.label, running: true) : $0 })
        #expect(rest(s) == ["alpha", "gamma", "beta", "other"])
    }

    @Test func repeatedSnapshotsAreIdempotentAndStaleGenerationsAreIgnored() {
        var s = snap(SpaceOrderState(), initial)
        let running = initial.map { $0.id == "beta" ? g("beta", "beta", running: true) : $0 }
        let once = snap(s, running, gen: 2)
        let twice = snap(once, running, gen: 2)
        #expect(once == twice)
        let stale = snap(twice, initial.map { $0.id == "gamma" ? g("gamma", "gamma", running: true) : $0 }, gen: 1)
        #expect(stale == twice, "a snapshot from an older connection generation is not accepted")
    }

    // 有效观察门禁：不完整或不新鲜的快照不触发上移，也不清除已有偏好。
    @Test func ineffectiveSnapshotsNeverPromoteAndKeepThePreferences() {
        var s = snap(SpaceOrderState(), initial)
        s = snap(s, initial.map { $0.id == "gamma" ? g("gamma", "gamma", running: true) : $0 }, effective: false)
        #expect(rest(s) == ["alpha", "beta", "gamma", "other"])
        s = snap(s, initial.map { $0.id == "gamma" ? g("gamma", "gamma", running: true) : $0 })
        s = snap(s, initial, effective: false)
        #expect(s.promoted == ["gamma"], "offline or incomplete snapshots do not clear the promoted mark")
        #expect(rest(s).first == "gamma")
    }

    @Test func effectiveGateNeedsCompleteAndFreshTrue() {
        #expect(SpaceObservationGate.effective(complete: true, fresh: true))
        #expect(!SpaceObservationGate.effective(complete: true, fresh: false))
        #expect(!SpaceObservationGate.effective(complete: true, fresh: nil))
        #expect(!SpaceObservationGate.effective(complete: false, fresh: true))
    }

    // “其他”分组同规则：运行时同样上移一次；默认最后。
    @Test func otherGroupFollowsTheSameRule() {
        var s = snap(SpaceOrderState(), initial)
        s = snap(s, initial.map { $0.id == "other" ? g("other", "其他", running: true, other: true) : $0 })
        #expect(rest(s).first == "other")
        s = snap(s, initial.map { $0.id == "other" ? g("other", "其他", running: false, other: true) : $0 })
        #expect(rest(s).first == "other", "no fallback")
    }

    // #97 空组隐藏：投影过滤，偏好保留（再次可见时回到原位）。
    @Test func hiddenGroupKeepsItsPlaceAndPromotion() {
        var s = snap(SpaceOrderState(), initial)
        s = snap(s, initial.map { $0.id == "gamma" ? g("gamma", "gamma", running: true) : $0 })
        let hidden = SpaceOrderReducer.project(s, visible: ["alpha", "beta", "other"])
        #expect(hidden.rest == ["alpha", "beta", "other"])
        #expect(s.promoted.contains("gamma"))
        let back = SpaceOrderReducer.project(s, visible: ["alpha", "beta", "gamma", "other"])
        #expect(back.rest.first == "gamma")
    }

    @Test func newGroupsAppearInAutomaticPositionWithoutMovingExistingOnes() {
        var s = snap(SpaceOrderState(), initial)
        let withDelta = initial + [g("delta", "delta")]
        s = snap(s, withDelta)
        #expect(rest(s) == ["alpha", "beta", "delta", "gamma", "other"])
    }

    // R3：中间的手动槽位不被挤动，自动槽位内重排。
    @Test func manualSlotInTheMiddleStaysFixedWhenAnotherGroupRuns() {
        var s = snap(SpaceOrderState(), initial)
        s = SpaceOrderReducer.reduce(s, .move(key: "gamma", before: "alpha")) // 手动：gamma 到第 1 位
        #expect(rest(s) == ["gamma", "alpha", "beta", "other"])
        // 手动槽在第 1 位；自动槽内 beta 上移到 alpha 之前。
        s = snap(s, initial.map { $0.id == "beta" ? g("beta", "beta", running: true) : $0 })
        #expect(rest(s) == ["gamma", "beta", "alpha", "other"], "the manual gamma keeps slot 1; beta takes the first automatic slot")
    }

    // R4：前锚失效时用仍存活的后锚，不跨过无关组。
    @Test func unpinUsesTheSurvivingNextAnchorWhenThePreviousIsGone() {
        var s = snap(SpaceOrderState(), [g("a", "a"), g("b", "b"), g("c", "c"), g("d", "d")])
        s = SpaceOrderReducer.reduce(s, .pin("c")) // 前 b、后 d
        s = SpaceOrderReducer.reduce(s, .pin("b")) // 前 a、后 d
        #expect(s.layout == ["a", "d"])
        s = SpaceOrderReducer.reduce(s, .unpin("c"))
        #expect(s.layout == ["a", "c", "d"], "the previous anchor b is pinned away; the surviving next d places c before it")
    }

    // R5：代次与待应用上移是会话瞬态：编码不含它们，解码后从 0 开始。
    @Test func generationAndPendingAreNotPersisted() throws {
        var s = snap(SpaceOrderState(), initial, gen: 5)
        s = snap(s, initial.map { $0.id == "beta" ? g("beta", "beta", running: true) : $0 }, frozen: true, gen: 5)
        #expect(s.generation == 5 && s.pending == ["beta"])
        let loaded = try JSONDecoder().decode(SpaceOrderState.self, from: JSONEncoder().encode(s))
        #expect(loaded.generation == 0 && loaded.pending.isEmpty)
        let next = snap(loaded, initial.map { $0.id == "beta" ? g("beta", "beta", running: true) : $0 }, gen: 1)
        #expect(rest(next).first == "beta", "a new session's first snapshot is accepted and promotes")
    }

    // 兼容：旧数据的锚点只有前锚（字符串）。
    @Test func legacyPrevOnlyAnchorsStillDecode() throws {
        let json = #"{"layout":["a","b"],"pinned":["c"],"manual":[],"promoted":[],"anchors":{"c":"b"}}"#
        let s = try JSONDecoder().decode(SpaceOrderState.self, from: Data(json.utf8))
        #expect(s.anchors["c"] == SpaceAnchor(prev: "b", next: nil))
    }
}
