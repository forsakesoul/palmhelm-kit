import Testing
import Foundation
@testable import PalmhelmKit

// #97 历史会话整理的规则矩阵（合成数据，注入的 Bridge 观察时刻，不读取墙钟）。
@Suite struct ThreadArchiveTests {
    static let day = 24 * 60 * 60 * 1000
    static let t0 = 1_700_000_000_000
    static let absent = ArchiveEvidence(online: false)
    static let online = ArchiveEvidence(online: true)

    @Test func sixDaysTwentyThreeHoursDoesNotArchiveAndSevenDaysDoes() {
        var r = ArchiveRecord()
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0, complete: true), Self.absent)
        #expect(r.absentSince == Self.t0 && r.archived == nil)
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 7 * Self.day - 1, complete: true), Self.absent)
        #expect(r.archived == nil)
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 7 * Self.day, complete: true), Self.absent)
        #expect(r.archived == .auto)
    }

    @Test func missingOrIncompleteEvidenceNeverStartsOrAdvancesTheCandidate() {
        var r = ArchiveRecord()
        r = ArchiveRules.observe(r, nil, Self.absent) // 旧 Bridge：没有 observation
        #expect(r == ArchiveRecord())
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0, complete: false), Self.absent) // 部分清单
        #expect(r == ArchiveRecord())
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 30 * Self.day, complete: true), Self.absent)
        #expect(r.archived == nil && r.absentSince == Self.t0 + 30 * Self.day)
    }

    @Test func staleOrMissingFreshnessNeverCountsAsAbsenceEvidence() {
        var r = ArchiveRecord()
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0, complete: true, fresh: false), Self.absent) // 服务端判定过期
        #expect(r == ArchiveRecord())
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0, complete: true, fresh: nil), Self.absent) // 缺少 fresh
        #expect(r == ArchiveRecord())
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 30 * Self.day, complete: true, fresh: false), Self.absent)
        #expect(r == ArchiveRecord(), "a stale snapshot days later must not start or complete a candidate")
    }

    @Test func repeatedOrStaleFramesDoNotAdvanceEvidence() {
        var r = ArchiveRecord()
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + Self.day, complete: true), Self.absent)
        let same = r
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + Self.day, complete: true), Self.absent)
        #expect(r == same)
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 9 * Self.day, complete: true), Self.absent)
        let advanced = r
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 9 * Self.day - 6 * 3600 * 1000, complete: true), Self.absent) // 较早到达的陈旧帧
        #expect(r == advanced, "a stale frame within a day must not change the record")
    }

    @Test func clockRollbackRestartsTheCandidateInsteadOfArchiving() {
        var r = ArchiveRecord()
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 5 * Self.day, complete: true), Self.absent)
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0, complete: true), Self.absent) // 回拨
        #expect(r.absentSince == nil && r.archived == nil && r.lastObserved == Self.t0)
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 1000, complete: true), Self.absent)
        #expect(r.archived == nil && r.absentSince == Self.t0 + 1000)
    }

    @Test func onlineClearsCandidateAndRestoresAnAutoArchivedThread() {
        var r = ArchiveRecord(absentSince: Self.t0, lastObserved: Self.t0 + 8 * Self.day, archived: .auto)
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 9 * Self.day, complete: true), Self.online)
        #expect(r.archived == nil && r.absentSince == nil)
        #expect(!ArchiveRules.isHiddenFromMain(r))
    }

    @Test func pendingWorkOrProtectionBlocksAutoArchive() {
        var r = ArchiveRecord()
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0, complete: true), Self.absent)
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 8 * Self.day, complete: true), ArchiveEvidence(online: false, protected: true))
        #expect(r.archived == nil)
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 9 * Self.day, complete: true), ArchiveEvidence(online: false, pendingWork: true))
        #expect(r.archived == nil && r.absentSince == nil, "pending work counts as presence and restarts the 7-day candidate")
    }

    @Test func manualArchiveAndDeleteOnlyForHistoricalOfflineThreads() {
        let rec = ArchiveRecord()
        #expect(ArchiveRules.archiveManually(rec, Self.online) == nil)
        #expect(ArchiveRules.archiveManually(rec, ArchiveEvidence(online: false, pendingWork: true)) == nil)
        #expect(ArchiveRules.archiveManually(rec, ArchiveEvidence(online: false, protected: true)) == nil)
        #expect(ArchiveRules.archiveManually(rec, Self.absent)?.archived == .manual)
        #expect(ArchiveRules.delete(rec, Self.online) == nil)
        #expect(ArchiveRules.delete(rec, Self.absent)?.deleted == true)
    }

    @Test func manualRestoreRestartsTheSevenDayCandidate() {
        var r = ArchiveRules.archiveManually(ArchiveRecord(absentSince: Self.t0, lastObserved: Self.t0 + 1000), Self.absent)!
        r = ArchiveRules.restore(r)
        #expect(r.archived == nil && r.absentSince == nil)
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 2000, complete: true), Self.absent)
        #expect(r.archived == nil, "a restored thread must not be archived again on the next frame")
        #expect(r.absentSince == Self.t0 + 2000)
    }

    @Test func tombstoneHidesOldHistoryUntilOnlineOrNewWork() {
        var r = ArchiveRules.delete(ArchiveRecord(), Self.absent)!
        #expect(ArchiveRules.isHiddenFromMain(r))
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0, complete: true), ArchiveEvidence(online: false))
        #expect(r.deleted, "a historical absence must not resurrect the deleted thread")
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 1, complete: true), ArchiveEvidence(online: false, pendingWork: true))
        #expect(!r.deleted && !ArchiveRules.isHiddenFromMain(r))
    }

    @Test func storeRoundTripsDirectoryAndStateOnlyWhenChanged() throws {
        let suite = "archive-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let key = ThreadArchiveStore.key(bridgeId: "bridge-1", targetId: "target:alpha")
        #expect(key == "bridge-1|target:alpha")
        let a = ThreadArchiveStore(defaults: d)
        a.touch(key, title: "alpha", lastActivity: 10)
        a.observe(key, BridgeObservation(t: Self.t0, complete: true), Self.absent)
        #expect(a.transform(key) { ArchiveRules.archiveManually($0, Self.absent) })
        let b = ThreadArchiveStore(defaults: d)
        #expect(b.record(key)?.archived == .manual && b.record(key)?.title == "alpha" && b.record(key)?.lastActivity == 10)
        #expect(b.transform(key) { ArchiveRules.archiveManually($0, Self.online) } == false, "a refused change must not persist")
    }

    @Test func pagingMergesOlderPagesByIdAndStopsAfterEmptyPartials() {
        func row(_ n: Int) -> TargetHistoryRow { TargetHistoryRow(id: "outbox:u\(n)", source: "outbox", text: "t\(n)", t: n * 10) }
        var p = TargetHistoryPaging()
        p.beginLoad()
        p.apply(TargetHistoryPage(items: [row(5), row(6)], nextBefore: "c1", hasMore: true, partial: false), older: false)
        #expect(p.canLoadMore && !p.shouldContinue)
        p.beginLoad()
        p.apply(TargetHistoryPage(items: [row(3), row(5)], nextBefore: "c2", hasMore: true, partial: false), older: true)
        #expect(p.items.map(\.id) == ["outbox:u3", "outbox:u5", "outbox:u6"], "older pages are prepended, de-duplicated by id, and time-ordered")
        for _ in 0..<TargetHistoryPaging.maxEmptyPartials {
            p.beginLoad()
            p.apply(TargetHistoryPage(items: [], nextBefore: "c3", hasMore: true, partial: true), older: true)
            #expect(p.shouldContinue)
        }
        p.beginLoad()
        p.apply(TargetHistoryPage(items: [], nextBefore: "c4", hasMore: true, partial: true), older: true)
        #expect(!p.shouldContinue && p.canLoadMore, "after the cap the user drives the next request")
        p.beginLoad()
        p.apply(TargetHistoryPage(items: [], nextBefore: nil, hasMore: false, partial: false), older: true)
        #expect(p.exhausted && !p.canLoadMore)
    }

    @Test func rowsDecodeStableIdsAndEitherTimeField() throws {
        let page = try JSONDecoder().decode(TargetHistoryPage.self, from: Data(#"{"items":[{"id":"inbox:api:d:1","source":"inbox","text":"你好","createdT":1700,"targetId":"target:a","state":"finished"},{"id":"outbox:u9","source":"outbox","text":"回执","kind":"text","replyTo":"api:d:1","t":1701}],"nextBefore":"12.34","hasMore":true,"partial":false}"#.utf8))
        #expect(page.items.map(\.id) == ["inbox:api:d:1", "outbox:u9"])
        #expect(page.items.map(\.t) == [1700, 1701])
        #expect(page.nextBefore == "12.34" && page.hasMore)
    }

    @Test func historyAndObservationDecodeWithAndWithoutTheNewFields() throws {
        let page = try JSONDecoder().decode(TargetHistoryPage.self, from: Data(#"{"items":[],"nextBefore":"12","hasMore":true,"partial":true}"#.utf8))
        #expect(page.nextBefore == "12" && page.partial && page.items.isEmpty)
        let end = try JSONDecoder().decode(TargetHistoryPage.self, from: Data(#"{"items":[],"nextBefore":null,"hasMore":false,"partial":false}"#.utf8))
        #expect(end.nextBefore == nil && !end.hasMore)
        let withObs = try JSONDecoder().decode(BridgeState.self, from: Data(Self.stateWithObservation.utf8))
        #expect(withObs.observation == BridgeObservation(t: 42, complete: true, fresh: true))
        let noFresh = try JSONDecoder().decode(BridgeObservation.self, from: Data(#"{"t":42,"complete":true}"#.utf8))
        #expect(noFresh.fresh == nil && ArchiveRules.observe(ArchiveRecord(), noFresh, Self.absent) == ArchiveRecord())
        let old = try JSONDecoder().decode(BridgeState.self, from: Data(Self.stateWithoutObservation.utf8))
        #expect(old.observation == nil, "an old Bridge without the field must decode as no evidence")
    }

    static let stateWithObservation = #"{"occupancy":"idle","targets":[],"history":{"highWater":0,"items":[]},"observation":{"t":42,"complete":true,"fresh":true},"inflight":[]}"#
    static let stateWithoutObservation = #"{"occupancy":"idle","targets":[],"history":{"highWater":0,"items":[]},"inflight":[]}"#
}

/// 统计写盘次数的偏好域（只计 set，不影响行为）。
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    nonisolated(unsafe) var sets = 0
    override func set(_ value: Any?, forKey defaultName: String) { sets += 1; super.set(value, forKey: defaultName) }
}

/// 一次观察的批量更新：证据完整推进并保存、整轮最多保存一次；展示是否变化单独报告。
@Suite struct ThreadArchiveBatchTests {
    static let day = ThreadArchiveTests.day
    static let t0 = ThreadArchiveTests.t0

    private func store() -> (ThreadArchiveStore, CountingDefaults, String) {
        let name = "archive-batch-\(UUID().uuidString)"
        let d = CountingDefaults(suiteName: name)!
        return (ThreadArchiveStore(defaults: d), d, name)
    }
    private func steps(_ n: Int, t: Int, ev: ArchiveEvidence = ThreadArchiveTests.absent, complete: Bool = true, fresh: Bool? = true) -> [ThreadArchiveStore.Step] {
        (0..<n).map { .observe(key: "b|t\($0)", observation: BridgeObservation(t: t, complete: complete, fresh: fresh), evidence: ev) }
    }
    private func titled(_ n: Int) -> [ThreadArchiveStore.Step] {
        (0..<n).map { .touch(key: "b|t\($0)", title: "T\($0)", lastActivity: 5) }
    }

    /// 40 条明确离线的记录：新的有效观察使 lastObserved 全部推进，但只保存一次，展示不变。
    @Test func aFreshObservationOfFortyOfflineRecordsSavesOnceAndKeepsTheDisplay() {
        let (s, d, name) = store(); defer { d.removePersistentDomain(forName: name) }
        s.apply(steps(40, t: Self.t0) + titled(40))
        let base = d.sets
        let r = s.apply(steps(40, t: Self.t0 + 5_000) + titled(40))
        #expect((0..<40).allSatisfy { s.record("b|t\($0)")?.lastObserved == Self.t0 + 5_000 }, "证据全部推进")
        #expect(d.sets - base == 1, "整轮只保存一次（逐条为 40 次）")
        #expect(r == .init(displayChanged: false, changed: true, persisted: true), "只有证据变化：展示不变")
    }

    /// 没有任何变化（重复/陈旧/不完整/未知在线）：不保存、不报变化。
    @Test func unchangedEvidenceDoesNotSaveOrReportAChange() {
        let (s, d, name) = store(); defer { d.removePersistentDomain(forName: name) }
        s.apply(steps(3, t: Self.t0) + titled(3))
        let base = d.sets
        for (label, batch) in [
            ("重复", steps(3, t: Self.t0)),
            ("陈旧（早半小时）", steps(3, t: Self.t0 - 30 * 60_000)),
            ("不完整", steps(3, t: Self.t0 + 1_000, complete: false)),
            ("不新鲜", steps(3, t: Self.t0 + 1_000, fresh: false)),
            ("未知在线", steps(3, t: Self.t0 + 1_000, ev: ArchiveEvidence(online: nil))),
        ] {
            let r = s.apply(batch)
            #expect(r == .init(displayChanged: false, changed: false, persisted: true), "\(label)：无变化")
        }
        #expect(d.sets == base, "无变化不保存")
    }

    /// 展示变化的正控：满 7 天自动归档、新证据恢复、保护目标不归档、回拨重新计时（证据变、展示不变）。
    @Test func displayChangesAreStillReported() {
        let (s, d, name) = store(); defer { d.removePersistentDomain(forName: name) }
        s.apply(steps(2, t: Self.t0) + titled(2))
        var base = d.sets
        var r = s.apply(steps(2, t: Self.t0 + 7 * Self.day - 1))
        #expect(!r.displayChanged && s.record("b|t0")?.archived == nil, "差 1 毫秒不满 7 天")
        base = d.sets
        r = s.apply(steps(1, t: Self.t0 + 7 * Self.day) + [.observe(key: "b|t1", observation: BridgeObservation(t: Self.t0 + 7 * Self.day, complete: true, fresh: true), evidence: ArchiveEvidence(online: false, protected: true))])
        #expect(r.displayChanged && s.record("b|t0")?.archived == .auto, "满 7 天归档")
        #expect(s.record("b|t1")?.archived == nil, "保护目标不归档")
        #expect(d.sets - base == 1)
        r = s.apply([.observe(key: "b|t0", observation: nil, evidence: ArchiveEvidence(online: true))])
        #expect(r.displayChanged && s.record("b|t0")?.archived == nil, "正证据恢复")
        r = s.apply(steps(1, t: Self.t0 - 2 * Self.day))
        #expect(!r.displayChanged && r.changed, "回拨：清空候选并记新时刻，展示不变")
        #expect(s.record("b|t0")?.absentSince == nil && s.record("b|t0")?.lastObserved == Self.t0 - 2 * Self.day, "候选清空，从新时刻重新计时")
    }

    /// 目录增删与标题 / 最近活动变化属于展示；onlyIfUntitled 不覆盖已有标题。
    @Test func directoryChangesAreDisplayChangesAndUntitledTouchKeepsTheTitle() {
        let (s, d, name) = store(); defer { d.removePersistentDomain(forName: name) }
        #expect(s.apply([.touch(key: "b|x", title: "标题", lastActivity: 3)]).displayChanged, "新增条目")
        #expect(!s.apply([.touch(key: "b|x", title: "标题", lastActivity: 3)]).changed, "相同的登记不变")
        #expect(s.apply([.touch(key: "b|x", title: "标题", lastActivity: 9)]).displayChanged, "最近活动变化")
        _ = s.apply([.touch(key: "b|x", title: "x", lastActivity: 0, onlyIfUntitled: true)])
        #expect(s.record("b|x")?.title == "标题", "已有标题保留")
        #expect(s.apply([.touch(key: "b|y", title: "y", lastActivity: 0, onlyIfUntitled: true)]).displayChanged && s.record("b|y")?.title == "y", "没有标题才登记")
    }

    /// 批量与逐条调用结果一致（同样的规则、同样的顺序）。
    @Test func batchMatchesPerRecordApplication() {
        let (a, da, na) = store(); defer { da.removePersistentDomain(forName: na) }
        let (b, db, nb) = store(); defer { db.removePersistentDomain(forName: nb) }
        let batch = steps(6, t: Self.t0) + titled(6) + steps(6, t: Self.t0 + 7 * Self.day)
        a.apply(batch)
        for step in batch {
            switch step {
            case let .observe(k, o, e): b.observe(k, o, e)
            case let .touch(k, t, l, _): b.touch(k, title: t, lastActivity: l)
            }
        }
        #expect(a.all == b.all)
    }
}
