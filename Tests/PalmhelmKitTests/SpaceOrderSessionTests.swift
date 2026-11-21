import Testing
import Foundation
@testable import PalmhelmKit

// #98 会话层（合成数据）：分组键、身份（改名与复用）、快照与冻结、列表段、移动边界、重置、旧数据兼容。
@Suite struct SpaceOrderSessionTests {
    private static let bridge = "b1"

    private func item(_ key: String, ws: String?, label: String?, status: String = "idle", term: String? = nil) throws -> LensInput {
        var fields = [#""projectName":"\#(key)","id":"\#(key)","online":true"#]
        if let ws { fields.append(#""workspaceId":"\#(ws)""#) }
        if let term { fields.append(#""terminalId":"\#(term)""#) }
        fields.append(#""status":"\#(status)""#)
        if let label { fields.append(#""location":{"workspace":"\#(label)"}"#) }
        let t = try JSONDecoder().decode(TargetSummary.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
        return LensInput(key: key, target: t, title: key, lastActivity: 1)
    }

    private func ids(_ sections: [LensSection]) -> [String] { sections.map(\.title) }

    @Test func groupsUseTheWorkspaceIdAndFallBackToTheLabel() throws {
        let items = [try item("a1", ws: "w1", label: "阿尔法"), try item("a2", ws: "w1", label: "阿尔法"),
                     try item("l1", ws: nil, label: "旧标签"), try item("x", ws: "w9", label: nil)]
        let groups = SpaceOrderSession.groups(bridgeId: Self.bridge, items: items)
        #expect(groups.map(\.label).contains("阿尔法") && groups.first { $0.label == "阿尔法" }?.members.count == 2)
        #expect(groups.first { $0.label == "旧标签" }?.rawId == "b1|label|旧标签", "legacy bridges key by label")
        #expect(groups.first { $0.isOther }?.label == "其他", "targets without a workspace go to other")
    }

    @Test func renameUnderTheSameWorkspaceIdKeepsThePreference() throws {
        var doc = SpaceOrderDocument()
        let before = [try item("a", ws: "w1", label: "alpha", term: "t1"), try item("b", ws: "w2", label: "beta", term: "t2")]
        SpaceOrderSession.applySnapshot(&doc, bridgeId: Self.bridge, items: before, effective: true, frozen: false, generation: 1)
        let renamed = [try item("a", ws: "w1", label: "alpha-2", term: "t1"), try item("b", ws: "w2", label: "beta", term: "t2")]
        let s = SpaceOrderSession.sections(bridgeId: Self.bridge, items: renamed, spaces: nil, document: doc)
        #expect(s.map(\.title).contains("alpha-2"))
        #expect(s.first { $0.title == "alpha-2" }?.id == SpaceOrderSession.sections(bridgeId: Self.bridge, items: before, spaces: nil, document: doc).first { $0.title == "alpha" }?.id, "same workspace id keeps the same stable group")
    }

    @Test func reuseOfTheWorkspaceIdWithoutSurvivingAgentsIsANewGroup() throws {
        var doc = SpaceOrderDocument()
        let before = [try item("a", ws: "w1", label: "alpha", term: "t1")]
        SpaceOrderSession.applySnapshot(&doc, bridgeId: Self.bridge, items: before, effective: true, frozen: false, generation: 1)
        let reused = [try item("c", ws: "w1", label: "gamma", term: "t9")]
        let stable = SpaceOrderSession.resolved(bridgeId: Self.bridge, items: reused, document: doc).first?.id
        #expect(stable?.hasSuffix("#1") == true, "a reused workspace id with no surviving terminal is a new group")
    }

    @Test func legacyRenameIsANewGroup() throws {
        var doc = SpaceOrderDocument()
        SpaceOrderSession.applySnapshot(&doc, bridgeId: Self.bridge, items: [try item("a", ws: nil, label: "alpha")], effective: true, frozen: false, generation: 1)
        let renamed = SpaceOrderSession.resolved(bridgeId: Self.bridge, items: [try item("a", ws: nil, label: "alpha-2")], document: doc)
        #expect(renamed.first?.id == "b1|label|alpha-2", "no migration is guessed for legacy labels")
    }

    // 有效快照上移一次；冻结时不动；离开再回来静默应用。
    @Test func snapshotPromotesOnceAndFreezingDefersUntilReenter() throws {
        var doc = SpaceOrderDocument()
        let idle = [try item("a", ws: "w1", label: "alpha"), try item("b", ws: "w2", label: "beta")]
        SpaceOrderSession.applySnapshot(&doc, bridgeId: Self.bridge, items: idle, effective: true, frozen: false, generation: 1)
        #expect(ids(SpaceOrderSession.sections(bridgeId: Self.bridge, items: idle, spaces: nil, document: doc)) == ["alpha", "beta"])
        let running = [try item("a", ws: "w1", label: "alpha"), try item("b", ws: "w2", label: "beta", status: "working")]
        SpaceOrderSession.applySnapshot(&doc, bridgeId: Self.bridge, items: running, effective: true, frozen: true, generation: 1)
        #expect(ids(SpaceOrderSession.sections(bridgeId: Self.bridge, items: running, spaces: nil, document: doc)) == ["alpha", "beta"], "visible list does not reorder")
        SpaceOrderSession.reenter(&doc, bridgeId: Self.bridge, items: running, effective: true)
        #expect(ids(SpaceOrderSession.sections(bridgeId: Self.bridge, items: running, spaces: nil, document: doc)) == ["beta", "alpha"])
        SpaceOrderSession.applySnapshot(&doc, bridgeId: Self.bridge, items: idle, effective: true, frozen: false, generation: 1)
        #expect(ids(SpaceOrderSession.sections(bridgeId: Self.bridge, items: idle, spaces: nil, document: doc)).first == "beta", "ending does not fall back")
    }

    @Test func incompleteObservationNeverPromotes() throws {
        var doc = SpaceOrderDocument()
        let items = [try item("a", ws: "w1", label: "alpha"), try item("b", ws: "w2", label: "beta", status: "working")]
        SpaceOrderSession.applySnapshot(&doc, bridgeId: Self.bridge, items: items, effective: false, frozen: false, generation: 1)
        #expect(doc.state.promoted.isEmpty)
    }

    @Test func pinnedSectionLeadsAndOtherIsLast() throws {
        var doc = SpaceOrderDocument()
        let items = [try item("a", ws: "w1", label: "alpha"), try item("b", ws: "w2", label: "beta"), try item("x", ws: nil, label: nil)]
        SpaceOrderSession.applySnapshot(&doc, bridgeId: Self.bridge, items: items, effective: true, frozen: false, generation: 1)
        let beta = SpaceOrderSession.resolved(bridgeId: Self.bridge, items: items, document: doc).first { $0.label == "beta" }!.id
        doc.state = SpaceOrderReducer.reduce(doc.state, .pin(beta))
        let s = SpaceOrderSession.sections(bridgeId: Self.bridge, items: items, spaces: nil, document: doc)
        #expect(ids(s) == ["beta", "alpha", "其他"])
    }

    @Test func moveStopsAtThePinnedBoundaryAndSwapsNeighbours() throws {
        var doc = SpaceOrderDocument()
        let items = [try item("a", ws: "w1", label: "alpha"), try item("b", ws: "w2", label: "beta"), try item("c", ws: "w3", label: "gamma")]
        SpaceOrderSession.applySnapshot(&doc, bridgeId: Self.bridge, items: items, effective: true, frozen: false, generation: 1)
        let g = SpaceOrderSession.resolved(bridgeId: Self.bridge, items: items, document: doc)
        let id = { (label: String) in g.first { $0.label == label }!.id }
        doc.state = SpaceOrderReducer.reduce(doc.state, .pin(id("alpha")))
        let visible = SpaceOrderSession.sections(bridgeId: Self.bridge, items: items, spaces: nil, document: doc).compactMap { SpaceOrderSession.groupId(sectionId: $0.id) }
        SpaceOrderSession.move(&doc, id: id("beta"), delta: -1, visible: visible)
        #expect(ids(SpaceOrderSession.sections(bridgeId: Self.bridge, items: items, spaces: nil, document: doc)) == ["alpha", "beta", "gamma"], "beta cannot cross the pinned alpha")
        SpaceOrderSession.move(&doc, id: id("gamma"), delta: -1, visible: visible)
        #expect(ids(SpaceOrderSession.sections(bridgeId: Self.bridge, items: items, spaces: nil, document: doc)) == ["alpha", "gamma", "beta"])
        SpaceOrderSession.move(&doc, id: id("gamma"), delta: 1, visible: ["alpha", id("gamma"), id("beta")])
        #expect(ids(SpaceOrderSession.sections(bridgeId: Self.bridge, items: items, spaces: nil, document: doc)) == ["alpha", "beta", "gamma"])
    }

    @Test func resetReturnsToTheAutomaticOrder() throws {
        var doc = SpaceOrderDocument()
        let items = [try item("a", ws: "w1", label: "alpha"), try item("b", ws: "w2", label: "beta", status: "working")]
        SpaceOrderSession.applySnapshot(&doc, bridgeId: Self.bridge, items: items, effective: true, frozen: false, generation: 1)
        SpaceOrderSession.reset(&doc, bridgeId: Self.bridge, items: items)
        #expect(doc.state.promoted.isEmpty && doc.state.layout.isEmpty == false)
        #expect(ids(SpaceOrderSession.sections(bridgeId: Self.bridge, items: items, spaces: nil, document: doc)) == ["alpha", "beta"])
    }

    @Test func documentsSavedBeforeTheIdentityMapStillLoad() throws {
        let old = #"{"version":1,"state":{"layout":["b1|ws|w1"],"pinned":[],"manual":[],"promoted":[],"anchors":{}},"fingerprints":{}}"#
        let doc = try JSONDecoder().decode(SpaceOrderDocument.self, from: Data(old.utf8))
        #expect(doc.groupIds.isEmpty && doc.state.layout == ["b1|ws|w1"])
    }

    @Test func aliasMapRoundTrips() throws {
        var doc = SpaceOrderDocument()
        doc.groupIds["b1|ws|w1"] = "b1|ws|w1#1"
        let back = try JSONDecoder().decode(SpaceOrderDocument.self, from: JSONEncoder().encode(doc))
        #expect(back.groupIds == ["b1|ws|w1": "b1|ws|w1#1"])
    }
}
