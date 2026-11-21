import Testing
@testable import PalmhelmKit

/// 骨架显示规则（A2-000 候选 1）：iOS / Mac 共用的唯一矩阵，经 `TranscriptPresentation.showsSkeleton`。
@Suite struct TranscriptPresentationTests {
    private func skeleton(_ id: String, connected: Bool = true, _ a: TranscriptActivation, confirmed: TranscriptActivation.Token?, status: TranscriptThread.Status?) -> Bool {
        TranscriptPresentation.showsSkeleton(targetId: id, connected: connected, current: a.current, confirmed: confirmed, status: status)
    }

    @Test func firstOpenShowsSkeletonUntilTheCurrentTokenIsConfirmed() {
        var a = TranscriptActivation(); let t = a.activate("A")
        #expect(skeleton("A", a, confirmed: nil, status: nil))
        #expect(skeleton("A", a, confirmed: nil, status: .loading))
        #expect(!skeleton("A", a, confirmed: t, status: .ok))
    }

    @Test func blurKeepsConfirmedContentAndRefocusDoesNotFlashTheSkeleton() {
        var a = TranscriptActivation(); let t = a.activate("A")
        a.deactivate()                                   // 失焦：current = nil，最近确认仍是 A
        #expect(!skeleton("A", a, confirmed: t, status: .ok))
        _ = a.activate("A")                              // 重新聚焦：新 Token 尚未确认
        #expect(!skeleton("A", a, confirmed: t, status: .ok))
    }

    @Test func switchingTargetsShowsTheSkeletonUntilTheNewTargetConfirms() {
        var a = TranscriptActivation(); let ta = a.activate("A")
        let tb = a.activate("B")
        #expect(skeleton("B", a, confirmed: ta, status: nil))           // A→B，最近确认 A，B 未确认
        #expect(skeleton("B", a, confirmed: ta, status: .ok))           // B 即使有 .ok 缓存，最近确认不是 B 也先骨架
        #expect(!skeleton("B", a, confirmed: tb, status: .ok))          // B 确认后
        _ = a.activate("A")                                              // B→A：最近确认是 B
        #expect(skeleton("A", a, confirmed: tb, status: .ok))           // A 有缓存也不能沿上一次 A 的确认免骨架
    }

    @Test func settledComparesTheWholeTokenNotJustTheTarget() {
        var a = TranscriptActivation(); let old = a.activate("A")
        a.deactivate(); _ = a.activate("A")                              // 同一目标的新代次
        #expect(!TranscriptPresentation.isSettled(targetId: "A", current: a.current, confirmed: old))
        #expect(TranscriptPresentation.isSettled(targetId: "A", current: a.current, confirmed: a.current))
        #expect(!TranscriptPresentation.isSettled(targetId: "B", current: a.current, confirmed: a.current))
        #expect(!TranscriptPresentation.isSettled(targetId: "A", current: nil, confirmed: old))
    }

    @Test func onlyOkCountsAsReusableContent() {
        var a = TranscriptActivation(); let t = a.activate("A"); a.deactivate(); _ = a.activate("A")
        let nonOk: [TranscriptThread.Status?] = [nil, .loading, .unavailable, .failed("x")]
        for s in nonOk { #expect(skeleton("A", a, confirmed: t, status: s), "\(String(describing: s))") }
    }

    @Test func disconnectedNeverShowsTheSkeleton() {
        var a = TranscriptActivation(); let ta = a.activate("A"); let tb = a.activate("B")
        #expect(!skeleton("B", connected: false, a, confirmed: ta, status: nil))
        #expect(!skeleton("A", connected: false, a, confirmed: tb, status: .loading))
    }

    @Test func blurDoesNotAuthorizeNetworkReads() {
        // 视觉上保留内容不等于允许读取：无激活时读取门禁仍 deferred（显示规则不触碰准入）。
        var a = TranscriptActivation(); let t = a.activate("A"); a.deactivate()
        #expect(!skeleton("A", a, confirmed: t, status: .ok))
        #expect(a.current == nil)
    }
}
