import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct StaleStateTests {
    private func cmd(_ state: String, target: String? = "target:a") -> ApiCommand {
        ApiCommand(key: "k-\(state)", inboxSeq: 1, text: "x", origin: "api", targetId: target, state: state)
    }
    private let live: Set<String> = ["target:a"]

    @Test func knownQueuedStartedNeedLinkAndTargetSnapshot() {
        #expect(CurrentActivity.phase(of: cmd("started"), linked: true, targets: live) == .working)
        #expect(CurrentActivity.phase(of: cmd("queued"), linked: true, targets: live) == .queued)
        #expect(CurrentActivity.phase(of: cmd("started"), linked: false, targets: live) == .pendingSync, "离线：待同步，不是工作中")
        #expect(CurrentActivity.phase(of: cmd("queued"), linked: true, targets: nil) == .pendingSync, "没有目标快照")
        #expect(CurrentActivity.phase(of: cmd("started", target: "target:gone"), linked: true, targets: live) == .history, "目标已不在快照")
        #expect(CurrentActivity.phase(of: cmd("queued", target: nil), linked: true, targets: live) == .history)
    }

    @Test func unknownAndUnrecognizedAreNeverCurrentNorSuccess() {
        #expect(CurrentActivity.phase(of: cmd("unknown"), linked: true, targets: live) == .resultUnknown)
        #expect(CurrentActivity.phase(of: cmd("brand_new"), linked: true, targets: live) == .unsupported)
        for s in ["unknown", "brand_new", "finished", "paused", "rejected"] {
            #expect(!CurrentActivity.isCurrent(CurrentActivity.phase(of: cmd(s), linked: true, targets: live)), Comment(rawValue: s))
        }
        #expect(CurrentActivity.note(.resultUnknown) == "结果未知")
        #expect(CurrentActivity.note(.unsupported) == "暂不支持此状态")
        #expect(CurrentActivity.note(.pendingSync) == "状态待同步")
        let all = ["started", "unknown", "brand_new", "paused"].map { cmd($0) }
        #expect(CurrentActivity.current(all, linked: true, targets: live).map(\.state) == ["started"])
    }

    @Test func displayLabelsAreHonest() {
        func l(_ c: ApiCommand, linked: Bool = true, t: Set<String>? = ["target:a"]) -> String { CurrentActivity.displayLabel(of: c, linked: linked, targets: t) }
        #expect(l(cmd("started")) == "已送达", "缺 phase 的 started 是中性“已送达”，与 OutgoingStatus 同一文案（A-F4）")
        #expect(l(cmd("started"), linked: false) == "状态待同步")
        #expect(l(cmd("unknown")) == "结果未知")
        #expect(l(cmd("weird")) == "暂不支持此状态")
        #expect(l(cmd("queued", target: "target:gone")) == "目标已不在 · 结果未确认", "可能已经执行：不能说未执行")
        #expect(!l(cmd("started", target: "target:gone")).contains("未执行"))
        #expect(l(cmd("paused")) == "已停止跟踪，可能已执行", "缺键的暂停保守：不写被拒绝 / 未发出")
        #expect(CurrentActivity.unresolved(["unknown", "weird", "started", "paused"].map { cmd($0) }, linked: true, targets: ["target:a"]) == 2)
    }

    private func reminder(_ uuid: String, key: String?, target: String? = "target:a", seq: Int = 1) -> HistoryItem {
        HistoryItem(seq: seq, uuid: uuid, text: "[a] x", kind: "text", replyTo: key, target: target.map { TargetRef(id: $0, projectName: "a") })
    }

    @Test func reminderIsCurrentOnlyWhenTargetAndEventKeyBothMatch() {
        let a = reminder("nblocked2:cA", key: "evA")
        let onlyB = [CurrentBlocked(targetId: "target:a", eventKey: "evB", blockedSince: 1)]
        #expect(ReminderRules.status(of: a, currentBlocked: onlyB, evidenceFresh: true, linked: true, commandsTruncated: false) == .history, "A 超时 → A 完成 → B 工作/阻塞：A 不再是当前")
        #expect(ReminderRules.status(of: a, currentBlocked: [CurrentBlocked(targetId: "target:a", eventKey: "evA", blockedSince: 1)], evidenceFresh: true, linked: true, commandsTruncated: false) == .current(eventKey: "evA"))
        #expect(ReminderRules.status(of: a, currentBlocked: [CurrentBlocked(targetId: "target:z", eventKey: "evA", blockedSince: 1)], evidenceFresh: true, linked: true, commandsTruncated: false) == .history, "目标不同")
        #expect(ReminderRules.status(of: a, currentBlocked: [], evidenceFresh: true, linked: true, commandsTruncated: false) == .history, "新 Bridge 空投影 = 没有阻塞")
    }

    @Test func evidenceGapsAreUnverifiedAndDisableReset() {
        let a = reminder("nblocked2:cA", key: "evA")
        let proj = [CurrentBlocked(targetId: "target:a", eventKey: "evA", blockedSince: 1)]
        #expect(ReminderRules.status(of: a, currentBlocked: nil, evidenceFresh: true, linked: true, commandsTruncated: false) == .unverified, "旧 Bridge")
        #expect(ReminderRules.status(of: a, currentBlocked: proj, evidenceFresh: true, linked: false, commandsTruncated: false) == .unverified, "离线")
        #expect(ReminderRules.status(of: a, currentBlocked: proj, evidenceFresh: true, linked: true, commandsTruncated: true) == .unverified, "截断")
        #expect(ReminderRules.status(of: reminder("nblocked2:c", key: nil), currentBlocked: proj, evidenceFresh: true, linked: true, commandsTruncated: false) == .unverified, "缺 eventKey")
        #expect(ReminderRules.status(of: a, currentBlocked: proj, evidenceFresh: false, linked: true, commandsTruncated: false) == .unverified, "支持但证据过期（Herdr 快照过期）")
        #expect(ReminderRules.status(of: a, currentBlocked: [], evidenceFresh: false, linked: true, commandsTruncated: false) == .unverified, "过期的空数组不是可靠的「没有阻塞」")
        #expect(ReminderRules.status(of: a, currentBlocked: [], evidenceFresh: nil, linked: true, commandsTruncated: false) == .unverified, "没有新鲜度字段：旧 Bridge")
        #expect(ReminderStatus.unverified.label == "历史提醒 · 当前状态待核")
        #expect(!ReminderStatus.unverified.allowsReset && !ReminderStatus.history.allowsReset && ReminderStatus.current(eventKey: "e").allowsReset)
    }

    @Test func ledgerSnapshotMarkSeenKeepsLaterArrivalsUnread() {
        var l = ReminderLedger()
        let a = reminder("nblocked2:1", key: "e1", seq: 1), b = reminder("nblocked2:2", key: "e2", seq: 2)
        l.markSeen(bridgeId: "B1", [a])
        #expect(l.unread(bridgeId: "B1", [a, b]).map(\.uuid) == ["nblocked2:2"], "只标打开时看到的")
        #expect(l.unread(bridgeId: "B2", [a]).count == 1, "别的 Bridge 互不影响")
    }

    @Test func firstUpgradeBaselineMovesOldRemindersToHistoryOnce() {
        var l = ReminderLedger()
        let old = reminder("nblocked2:o", key: "eo", seq: 1), cur = reminder("nblocked2:c", key: "ec", seq: 2)
        l.baselineIfNeeded(bridgeId: "B1", items: [old, cur], keepUnread: { $0.uuid == "nblocked2:c" })
        #expect(l.unread(bridgeId: "B1", [old, cur]).map(\.uuid) == ["nblocked2:c"])
        let later = reminder("nblocked2:n", key: "en", seq: 3)
        l.baselineIfNeeded(bridgeId: "B1", items: [later]) // 已有基线：不再吞新提醒
        #expect(l.unread(bridgeId: "B1", [later]).count == 1)
    }

    @Test func ledgerCapIsPerBridgeAndNeverEvictsAnotherBridgesReadRecords() {
        var l = ReminderLedger()
        let a = (1...600).map { "a\($0)" }, b = (1...600).map { "b\($0)" }
        l.markSeen(bridgeId: "A", ids: a)
        l.markSeen(bridgeId: "B", ids: b)
        #expect(a.allSatisfy { l.isSeen(bridgeId: "A", id: $0) }, "跨 Bridge 总数超过 500：A 的已读不被 B 挤掉，回访不复活")
        #expect(b.allSatisfy { l.isSeen(bridgeId: "B", id: $0) })
        l.markSeen(bridgeId: "A", ids: (1...(ReminderLedger.perBridgeLimit + 20)).map { "x\($0)" })
        #expect(l.seenByBridge["A"]?.count == ReminderLedger.perBridgeLimit, "单个 Bridge 内部有界")
        #expect(l.seenByBridge["B"]?.count == 600, "别的 Bridge 不受影响")
        #expect(l.unread(bridgeId: "A", ids: ["fresh-unread"]) == ["fresh-unread"], "未读不进已读，不受裁剪")
    }

    @Test func retainedReadMarksSurviveCapacityEviction() {
        var l = ReminderLedger()
        let old = ReminderLedger.sentId(UUID()) // 一条已读的旧失败项（本机 Sent 一直追加，没有对应上限）
        l.markSeen(bridgeId: "B", ids: [old])
        let later = (1...(ReminderLedger.perBridgeLimit + 300)).map { "rj:\($0)" }
        l.markSeen(bridgeId: "B", ids: later, retained: [old]) // 它仍在保留集里
        #expect(l.isSeen(bridgeId: "B", id: old), "后来超过容量的已读不能把仍保留着的已读标记挤掉")
        #expect(l.seenByBridge["B"]!.count <= ReminderLedger.perBridgeLimit + 1)
        // 不在保留集里的最旧已读才被淘汰
        #expect(!l.isSeen(bridgeId: "B", id: "rj:1"))
        #expect(l.isSeen(bridgeId: "B", id: "rj:\(ReminderLedger.perBridgeLimit + 300)"))
    }

    @Test func identityFallsBackToStableAccountKeyAndNeverSharesLocal() {
        #expect(ReminderLedger.identity(bridgeId: "b1", accountKey: "a").id == "b1")
        let a = ReminderLedger.identity(bridgeId: nil, accountKey: "acc-1"), b = ReminderLedger.identity(bridgeId: "", accountKey: "acc-2")
        #expect(a.id != b.id && a.persistent && b.persistent, "两个没有 id 的账号互不共用")
        let none = ReminderLedger.identity(bridgeId: nil, accountKey: nil)
        #expect(!none.persistent, "没有任何稳定身份：不持久化")
        #expect(none.id != "local")
    }

    @Test func legacyGlobalLedgerFormatIsMigrated() throws {
        let old = #"{"seen":["B1~nblocked2:1","B2~nblocked2:9"],"baselined":["B1"]}"#
        let l = try JSONDecoder().decode(ReminderLedger.self, from: Data(old.utf8))
        #expect(l.isSeen(bridgeId: "B1", id: "nblocked2:1") && l.isSeen(bridgeId: "B2", id: "nblocked2:9"))
        #expect(l.baselined == ["B1"])
    }

    @Test func sentFailuresShareTheSameLedger() {
        var l = ReminderLedger()
        let u = UUID()
        #expect(l.unread(bridgeId: "B", ids: [ReminderLedger.sentId(u)]).count == 1)
        l.markSeen(bridgeId: "B", ids: [ReminderLedger.sentId(u)])
        #expect(l.unread(bridgeId: "B", ids: [ReminderLedger.sentId(u)]).isEmpty)
        #expect(l.unread(bridgeId: "B2", ids: [ReminderLedger.sentId(u)]).count == 1, "按 Bridge 身份区分")
    }

    @Test func waitedMinutesFollowsTheNewBlockedSince() {
        let it = reminder("nblocked2:c", key: "ev")
        let first = [CurrentBlocked(targetId: "target:a", eventKey: "ev", blockedSince: 0)]
        #expect(ReminderRules.waitedMinutes(of: it, currentBlocked: first, nowMs: 600_000) == 10)
        let again = [CurrentBlocked(targetId: "target:a", eventKey: "ev", blockedSince: 540_000)] // 解除后再次阻塞：按新的起点
        #expect(ReminderRules.waitedMinutes(of: it, currentBlocked: again, nowMs: 600_000) == 1)
        #expect(ReminderRules.waitedMinutes(of: it, currentBlocked: [], nowMs: 600_000) == nil)
    }

    @Test func ledgerPersistsAcrossLoads() {
        let d = UserDefaults(suiteName: "StaleStateTests.\(UUID().uuidString)")!
        var l = ReminderLedger.load(from: d)
        l.markSeen(bridgeId: "B", [reminder("nblocked2:1", key: nil)])
        l.save(to: d)
        #expect(ReminderLedger.load(from: d).seenByBridge["B"] == ["nblocked2:1"])
    }

    @Test func conditionalResetText() {
        #expect(OwnerCommand.resetOccupancy("p", expectedEventKey: "ev-1") == "重置占用 p #ev-1")
    }
}

// t18：提醒页只显示 72 小时内、未处理的项；可见性规则只在 ReminderRules.visibleIds 一处。
@Suite struct ReminderVisibilityTests {
    private let now = 1_800_000_000_000
    private var edge: Int { now - ReminderRules.maxAgeMs }
    private func plain(_ id: String, t: Int?, seen: Bool = false, restorable: Bool = false, restored: Bool = false) -> ReminderCandidate {
        ReminderCandidate(id: id, t: t, kind: .plain, seen: seen, restorable: restorable, restored: restored)
    }
    private func blocked(_ id: String, _ s: ReminderStatus, t: Int?, seen: Bool = false) -> ReminderCandidate {
        ReminderCandidate(id: id, t: t, kind: .blocked(s), seen: seen)
    }
    private func shown(_ items: [ReminderCandidate], retained: Set<String> = []) -> [String] {
        ReminderRules.visibleIds(items, retained: retained, nowMs: now)
    }

    @Test func threeDayWindowIsInclusiveAtTheEdgeAndBeatsEverythingElse() {
        #expect(shown([plain("old", t: edge - 1)]).isEmpty, "72 小时外隐藏（毫秒）")
        #expect(shown([plain("edge", t: edge)]) == ["edge"], "恰好 72 小时保留")
        #expect(shown([plain("fresh", t: edge + 1)]) == ["fresh"])
        #expect(shown([blocked("cur", .current(eventKey: "e"), t: edge - 1)]).isEmpty, "超过 72 小时的超时卡即使仍是当前也隐藏")
        #expect(shown([plain("restorable-old", t: edge - 1, restorable: true)]).isEmpty, "可恢复项同样受 72 小时约束")
    }

    @Test func blockedReminderShowsOnlyWhileCurrentOrUnverifiedAndUnread() {
        #expect(shown([blocked("c", .current(eventKey: "e"), t: now, seen: true)]) == ["c"], "current 已读也保留：需要操作")
        #expect(shown([blocked("h", .history, t: now)]).isEmpty, "history 即已处理")
        #expect(shown([blocked("u", .unverified, t: now)]) == ["u"], "unverified 未读时显示")
        #expect(shown([blocked("u", .unverified, t: now, seen: true)]).isEmpty, "unverified 已读即隐藏")
        #expect(shown([blocked("nc", .current(eventKey: "e"), t: nil)]) == ["nc"], "无时间的 current 不因缺时间隐藏")
        #expect(shown([blocked("nu", .unverified, t: nil)]).isEmpty, "无可信时间的非 current 超时卡隐藏")
    }

    @Test func readPlainItemsHideUnlessRetainedByThisPresentation() {
        #expect(shown([plain("unread", t: now)]) == ["unread"])
        #expect(shown([plain("read", t: now, seen: true)]).isEmpty)
        #expect(shown([plain("read", t: now, seen: true)], retained: ["read"]) == ["read"], "本次打开的保留集只豁免本次标已读造成的隐藏")
        #expect(shown([plain("notime", t: nil)]) == ["notime"])
        #expect(shown([plain("notime", t: nil, seen: true)]).isEmpty, "无时间的普通项按已读收敛，不无限期保留")
    }

    @Test func retainedNeverOverridesAgeHistoryOrRestored() {
        #expect(shown([plain("aged", t: edge - 1, seen: true)], retained: ["aged"]).isEmpty, "72 小时到期优先于保留集")
        #expect(shown([blocked("h", .history, t: now, seen: true)], retained: ["h"]).isEmpty, "history 优先于保留集")
        #expect(shown([plain("done", t: now, seen: true, restored: true)], retained: ["done"]).isEmpty, "恢复成功优先隐藏")
    }

    @Test func recoverableFailureIgnoresReadUntilRestored() {
        #expect(shown([plain("r", t: now, seen: true, restorable: true)]) == ["r"], "恢复成功前不按已读隐藏")
        #expect(shown([plain("r", t: now, seen: true, restorable: false, restored: true)]).isEmpty, "恢复后即使仍在候选里也隐藏")
    }
}
