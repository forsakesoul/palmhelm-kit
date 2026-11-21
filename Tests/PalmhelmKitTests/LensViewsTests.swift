import Testing
import Foundation
@testable import PalmhelmKit

// h10a K1：视角收口为「收件箱 / 空间」。收件箱只含待答与工作中；空间按工作区分组列全部；旧持久化值回落空间。
@Suite struct LensViewsTests {
    private func t(_ id: String, ws: String? = nil, tab: String? = nil, role: String? = nil) -> TargetSummary {
        TargetSummary(projectName: id, online: true, targetId: id, agentName: "\(id)_agent", kind: "claude", status: "idle", role: role,
                      location: TargetLocation(workspace: ws, tab: tab, pane: "w1:p1"))
    }
    private func i(_ t: TargetSummary, _ n: Int = 0, pending: Int = 0, unread: Bool = false, pinned: Bool = false) -> LensInput {
        LensInput(key: t.id, target: t, title: t.id, lastActivity: n, pendingApprovals: pending, unread: unread, pinned: pinned)
    }
    private func working(_ id: String, _ n: Int = 0) -> LensInput {
        LensInput(key: id, target: TargetSummary(projectName: id, targetId: id, status: "working"), title: id, lastActivity: n)
    }

    // 旧版本持久化的 branch / group 回落为空间；未知值与缺省也是空间。
    @Test func storedLensFallsBackToSpaces() throws {
        #expect(ThreadLens.allCases == [.inbox, .spaces])
        #expect(try JSONDecoder().decode(ThreadLens.self, from: Data("\"branch\"".utf8)) == .spaces)
        #expect(try JSONDecoder().decode(ThreadLens.self, from: Data("\"group\"".utf8)) == .spaces)
        #expect(try JSONDecoder().decode(ThreadLens.self, from: Data("\"inbox\"".utf8)) == .inbox)
        #expect(ThreadLens.fromStored("branch") == .spaces)
        #expect(ThreadLens.fromStored("group") == .spaces)
        #expect(ThreadLens.fromStored(nil) == .spaces)
        #expect(ThreadLens.fromStored("") == .spaces)
        #expect(ThreadLens.fromStored("inbox") == .inbox)
    }

    // 收件箱只含待答（waiting）与工作中（working）；空闲与已读不出现。
    @Test func inboxHoldsOnlyWaitingAndWorking() {
        let idle = i(t("idle"), 999)
        let read = i(t("read"), 998)
        let unread = i(t("unread"), 997, unread: true)
        let waiting = i(t("wait"), 1, pending: 1)
        let work = working("work", 2)
        let s = LensGrouping.sections(.inbox, [idle, read, unread, waiting, work])
        #expect(s.map(\.title) == ["等你", "工作中"])
        #expect(s.flatMap(\.keys) == ["wait", "work"])
        #expect(s.allSatisfy { !$0.collapsedByDefault })
    }

    // 收件箱段内：钉住在前，再按最近活动。
    @Test func inboxOrdersPinnedThenRecent() {
        let old = i(t("old"), 1, pending: 1)
        let new = i(t("new"), 20, pending: 1)
        let pinnedOld = i(t("pin"), 2, pending: 1, pinned: true)
        #expect(LensGrouping.sections(.inbox, [old, new, pinnedOld]).first?.keys == ["pin", "new", "old"])
    }

    // 空间：按工作区分组列全部 agent，名字固定排序，“其他”在最后；组内按标签、角色。
    @Test func spacesGroupAllByWorkspace() {
        let a = i(t("a-design", ws: "beta", tab: "t1", role: "design"), 1)
        let b = i(t("b-exec", ws: "alpha", tab: "t2", role: "execute"), 2)
        let c = i(t("c-none"), 3)
        let s = LensGrouping.sections(.spaces, [a, b, c])
        #expect(s.map(\.title) == ["alpha", "beta", LensGrouping.otherSpace])
        #expect(s.flatMap(\.keys) == ["b-exec", "a-design", "c-none"])
    }

    // 推荐只在空间与收件箱之间：≥2 个工作区 → 空间，否则收件箱。
    @Test func recommendSpacesOrInbox() {
        #expect(LensGrouping.recommend([i(t("x", ws: "a")), i(t("y", ws: "b"))]) == .spaces)
        #expect(LensGrouping.recommend([i(t("x", ws: "a"))]) == .inbox)
        #expect(LensGrouping.recommend([i(t("only"))]) == .inbox)
    }

    // 结构签名只随工作区数变化。
    @Test func signatureTracksWorkspacesOnly() {
        let a = [i(t("x", ws: "a")), i(t("y", ws: "b"))]
        let same = [i(t("x", ws: "a"), 9), i(t("y", ws: "b"), 9)]
        let more = a + [i(t("z", ws: "c"))]
        #expect(LensGrouping.structureSignature(a) == LensGrouping.structureSignature(same))
        #expect(LensGrouping.structureSignature(a) != LensGrouping.structureSignature(more))
    }

    // 身份行不再随视角变化（编组 / 分支去重已随视角删除）。
    @Test func identityLineIsLensIndependent() {
        let x = TargetSummary(projectName: "bridge", targetId: "t", agentName: "task_b373_design", group: "task_b373", kind: "claude", role: "design", groupShort: "b373")
        #expect(ThreadIdentity.line(x).contains("b373"))
    }
}

@Suite struct LensPreferenceTests {
    @Test func recommendOnceUntilSignatureChanges() {
        var e = LensPreferenceStore.Entry()
        #expect(LensPreferenceStore.shouldRecommend(current: .inbox, recommended: .spaces, signature: "w2", entry: e))
        e.lastSignature = "w2"
        #expect(!LensPreferenceStore.shouldRecommend(current: .inbox, recommended: .spaces, signature: "w2", entry: e))
        #expect(LensPreferenceStore.shouldRecommend(current: .inbox, recommended: .spaces, signature: "w3", entry: e))
        e.ignoredSignature = "w3"
        #expect(!LensPreferenceStore.shouldRecommend(current: .inbox, recommended: .spaces, signature: "w3", entry: e))
        #expect(!LensPreferenceStore.shouldRecommend(current: .spaces, recommended: .spaces, signature: "zz", entry: e))
    }

    @Test func storePersistsPerMachineAndFallsBackOldValues() {
        let d = UserDefaults(suiteName: "palmhelm.test.PalmhelmKit")!
        let key = "lens.\(UUID().uuidString)"
        defer { d.removeObject(forKey: key) }
        let s = LensPreferenceStore(defaults: d, storageKey: key)
        s.setLens("m1", .inbox); s.ignore("m2", signature: "sig")
        let again = LensPreferenceStore(defaults: d, storageKey: key)
        #expect(again.entry("m1").lens == .inbox && again.entry("m1").ignoredSignature == nil)
        #expect(again.entry("m2").ignoredSignature == "sig" && again.entry("m2").lens == nil)
        // 旧版本写入的 "branch" 回落为空间，不影响解码其他字段
        d.set(Data(#"{"m3":{"lens":"branch","lastSignature":"w1"}}"#.utf8), forKey: key)
        #expect(LensPreferenceStore(defaults: d, storageKey: key).entry("m3").lens == .spaces)
        #expect(LensPreferenceStore(defaults: d, storageKey: key).entry("m3").lastSignature == "w1")
    }
}
