import Testing
import Foundation
@testable import PalmhelmKit

// #98 分组键与身份判定：同 ID 改名、复用、无 agent 降级、旧协议的 legacy 命名空间。
@Suite struct SpaceGroupKeyTests {
    @Test func newProtocolKeysUseTheWorkspaceIdNotTheLabel() {
        let a = SpaceGroupKey(bridgeId: "b1", workspaceId: "w7", label: "alpha")
        let b = SpaceGroupKey(bridgeId: "b1", workspaceId: "w7", label: "renamed")
        #expect(a.id == b.id)
        #expect(SpaceGroupKey(bridgeId: "b2", workspaceId: "w7", label: "alpha").id != a.id, "bridge id is part of the key")
    }

    @Test func sameIdentityWhenTheLabelIsUnchanged() {
        let fp = SpaceFingerprint(label: "alpha", terminalIds: ["t1"])
        #expect(SpaceIdentity.resolve(stored: fp, current: SpaceFingerprint(label: "alpha", terminalIds: [])) == .same)
    }

    @Test func renameKeepsThePreferenceWhileAnAgentTerminalSurvives() {
        let stored = SpaceFingerprint(label: "alpha", terminalIds: ["t1", "t2"])
        let current = SpaceFingerprint(label: "alpha-2", terminalIds: ["t2", "t9"])
        #expect(SpaceIdentity.resolve(stored: stored, current: current) == .renamed)
    }

    @Test func reuseOfTheWorkspaceIdWithNoSurvivingTerminalIsANewGroup() {
        let stored = SpaceFingerprint(label: "alpha", terminalIds: ["t1"])
        let current = SpaceFingerprint(label: "beta", terminalIds: ["t8"])
        #expect(SpaceIdentity.resolve(stored: stored, current: current) == .newGroup)
    }

    @Test func withoutAgentsOnlyTheLabelDecides() {
        // Herdr 重启后工作区没有 agent：标签变化即视为新组（已知限制：偏好可能丢失，不猜测）。
        let stored = SpaceFingerprint(label: "alpha", terminalIds: [])
        #expect(SpaceIdentity.resolve(stored: stored, current: SpaceFingerprint(label: "beta", terminalIds: [])) == .newGroup)
        #expect(SpaceIdentity.resolve(stored: stored, current: SpaceFingerprint(label: "alpha", terminalIds: [])) == .same)
    }

    @Test func legacyBridgesFallBackToTheLabelNamespace() {
        let old = SpaceGroupKey(bridgeId: "b1", workspaceId: nil, label: "alpha")
        let renamed = SpaceGroupKey(bridgeId: "b1", workspaceId: nil, label: "alpha-2")
        #expect(old.id != renamed.id, "legacy rename is a new group; no migration is guessed")
        #expect(old.id.contains("label"))
    }

    @Test func otherKeyIsStableAcrossLabels() {
        #expect(SpaceGroupKey.other(bridgeId: "b1") == "b1|other")
    }
}
