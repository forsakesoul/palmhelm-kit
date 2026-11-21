import Testing
import Foundation
@testable import PalmhelmKit

// #97 S2/S3 终审反例（A1-118，h70 R1/R3/R4）：正工作证据、未知在线与首载的 Kit 规则。
@Suite struct ThreadArchiveSafetyTests {
    static let day = 24 * 60 * 60 * 1000
    static let t0 = 1_700_000_000_000

    /// 第 7 天同帧：先有完整离线观察满 7 天，同一帧里出现新排队指令——必须保护，不得归档。
    @Test func queuedWorkInTheSameSnapshotProtectsOnTheSeventhDay() {
        var r = ArchiveRecord()
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0, complete: true), ArchiveEvidence(online: false))
        let facts = ArchiveWorkFacts(commandStates: ["queued"])
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 7 * Self.day, complete: true), ArchiveEvidence(online: false, facts: facts))
        #expect(r.archived == nil)
        #expect(r.absentSince == nil)
    }

    @Test func unknownAndUnsyncedWorkProtects() {
        for facts in [ArchiveWorkFacts(commandStates: ["unknown"]), ArchiveWorkFacts(pendingSync: 1), ArchiveWorkFacts(unconfirmedSends: 1), ArchiveWorkFacts(commandStates: ["paused"])] {
            var r = ArchiveRecord(absentSince: Self.t0, lastObserved: Self.t0)
            r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0 + 7 * Self.day, complete: true), ArchiveEvidence(online: false, facts: facts))
            #expect(r.archived == nil, "facts \(facts) must protect")
        }
    }

    @Test func finishedCommandsDoNotProtect() {
        #expect(!ArchiveWorkFacts(commandStates: ["finished", "rejected"]).pending)
    }

    @Test func draftBlocksManualArchiveEvenWhenNotSelected() {
        let ev = ArchiveEvidence(online: false, facts: ArchiveWorkFacts(hasDraft: true))
        #expect(ArchiveRules.archiveManually(ArchiveRecord(), ev) == nil)
        #expect(ArchiveRules.delete(ArchiveRecord(), ev) == nil)
    }

    /// 同一时刻的新工作：恢复可见，不受 complete/fresh/t 推进门禁限制。
    @Test func sameTimestampWorkRestoresImmediately() {
        let archived = ArchiveRecord(absentSince: Self.t0, lastObserved: Self.t0 + 7 * Self.day, archived: .auto, title: "A")
        let frame = BridgeObservation(t: Self.t0 + 7 * Self.day, complete: true)
        let r = ArchiveRules.observe(archived, frame, ArchiveEvidence(online: false, facts: ArchiveWorkFacts(commandStates: ["started"])))
        #expect(r.archived == nil && r.absentSince == nil)
    }

    /// 单独的入站事件没有新的观察时刻：仍须恢复（传入 nil 观察）。
    @Test func inboundWorkWithoutAnObservationRestores() {
        let archived = ArchiveRecord(absentSince: Self.t0, lastObserved: Self.t0, archived: .auto, deleted: true)
        let r = ArchiveRules.observe(archived, nil, ArchiveEvidence(online: false, facts: ArchiveWorkFacts(pendingApprovals: 1)))
        #expect(r.archived == nil && r.deleted == false)
    }

    /// 旧历史重放：没有工作证据、观察不完整时，墓碑不复活。
    @Test func tombstoneStaysWithoutPositiveEvidence() {
        let tomb = ArchiveRecord(deleted: true)
        let r = ArchiveRules.observe(tomb, BridgeObservation(t: Self.t0, complete: false), ArchiveEvidence(online: false))
        #expect(r.deleted)
    }

    /// R4：online 为 nil（未知）时不得归档或删除，缺席计时也不推进。
    @Test func unknownOnlineIsNeverOffline() {
        let unknown = ArchiveEvidence(online: nil)
        #expect(ArchiveRules.archiveManually(ArchiveRecord(), unknown) == nil)
        #expect(ArchiveRules.delete(ArchiveRecord(), unknown) == nil)
        var r = ArchiveRecord()
        r = ArchiveRules.observe(r, BridgeObservation(t: Self.t0, complete: true), unknown)
        #expect(r.absentSince == nil)
    }

    /// 明确离线仍可手动整理。
    @Test func explicitOfflineCanBeArchivedByHand() {
        #expect(ArchiveRules.archiveManually(ArchiveRecord(), ArchiveEvidence(online: false)) != nil)
    }

    // R1：首载与续页分开；首载失败可重试；hasMore == false 不再请求。
    @Test func firstLoadIsAllowedAndRetriesAfterFailure() {
        var p = TargetHistoryPaging()
        #expect(p.canLoadInitial && !p.canLoadMore)
        p.beginLoad()
        p.failLoad()
        #expect(p.canLoadInitial && p.failed)
        p.beginLoad()
        p.apply(TargetHistoryPage(items: [], nextBefore: nil, hasMore: false, partial: false), older: false)
        #expect(!p.canLoadInitial && !p.canLoadMore && p.exhausted)
    }

    @Test func olderPagesUseTheOpaqueCursorOnlyAfterTheFirstLoad() {
        var p = TargetHistoryPaging()
        p.beginLoad()
        p.apply(TargetHistoryPage(items: [TargetHistoryRow(id: "outbox:a", source: "outbox", text: "a", t: 1)], nextBefore: "5.6", hasMore: true, partial: false), older: false)
        #expect(p.canLoadMore && !p.canLoadInitial)
        #expect(p.nextBefore == "5.6")
    }

    /// F1：本机未决发送（无指令）保护；已明确终态与已有指令的记录不由此保护。
    @Test func localSendProtectsOnlyWhileUnresolved() {
        #expect(ArchiveWorkFacts.localSendUnresolved(.sending, hasCommand: false))
        #expect(ArchiveWorkFacts.localSendUnresolved(.unknown, hasCommand: false))
        #expect(ArchiveWorkFacts.localSendUnresolved(.nativePending, hasCommand: false))
        for terminal in [OutgoingPhase.done, .failed, .rejected, .withdrawn, .expired] {
            #expect(!ArchiveWorkFacts.localSendUnresolved(terminal, hasCommand: false), "\(terminal) is terminal")
        }
        #expect(!ArchiveWorkFacts.localSendUnresolved(.unknown, hasCommand: true), "commands cover records that have one")
    }
}
