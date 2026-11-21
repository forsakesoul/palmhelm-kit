import Testing
@testable import PalmhelmKit

@Suite struct LatestWindowRulesTests {
    @Test func localWindowAdvanceWithoutNewMessages() {
        // 无新网络消息：窗口底部之下还有已加载的行，手势结束即本地展开，不回最新
        #expect(LatestWindowRules.actionAtWindowBottom(stuck: true, userScrolling: false, pinned: false, hasRowsBelowWindow: true, hasNewer: false) == .showNewerRows)
    }

    @Test func rowsBelowWinsOverNewerWhenBothHold() {
        // hasNewer 与 hasRowsBelowWindow 同时成立：先走本地下一段，不跳过仍在内存的较新历史
        #expect(LatestWindowRules.actionAtWindowBottom(stuck: true, userScrolling: false, pinned: false, hasRowsBelowWindow: true, hasNewer: true) == .showNewerRows)
    }

    @Test func resumesOnlyAtTheCachedTail() {
        #expect(LatestWindowRules.actionAtWindowBottom(stuck: true, userScrolling: false, pinned: false, hasRowsBelowWindow: false, hasNewer: true) == .resumeLatest)
        #expect(LatestWindowRules.actionAtWindowBottom(stuck: true, userScrolling: false, pinned: false, hasRowsBelowWindow: false, hasNewer: false) == .none)
    }

    @Test func pinnedViewExtendsLocallyButNeverJumpsToLatest() {
        #expect(LatestWindowRules.actionAtWindowBottom(stuck: true, userScrolling: false, pinned: true, hasRowsBelowWindow: true, hasNewer: true) == .showNewerRows)
        #expect(LatestWindowRules.actionAtWindowBottom(stuck: true, userScrolling: false, pinned: true, hasRowsBelowWindow: false, hasNewer: true) == .none)
    }

    @Test func noActionWhileDraggingOrAwayFromBottom() {
        #expect(LatestWindowRules.actionAtWindowBottom(stuck: true, userScrolling: true, pinned: false, hasRowsBelowWindow: true, hasNewer: true) == .none, "手势未结束不推进")
        #expect(LatestWindowRules.actionAtWindowBottom(stuck: false, userScrolling: false, pinned: false, hasRowsBelowWindow: true, hasNewer: true) == .none, "离开底部不推进")
    }

    @Test func backToLatestEntryKeepsAccessWhenWindowIsLocal() {
        // F2：本地窗口下方有行 → 一定有入口（含 iOS 17：stuck 不更新）
        #expect(LatestWindowRules.showsBackToLatest(stuck: false, hasRowsBelowWindow: true, hasNewer: false))
        #expect(LatestWindowRules.showsBackToLatest(stuck: true, hasRowsBelowWindow: true, hasNewer: false))
        // 只有真正未加载的较新内容且离开底部才出现
        #expect(LatestWindowRules.showsBackToLatest(stuck: false, hasRowsBelowWindow: false, hasNewer: true))
        #expect(!LatestWindowRules.showsBackToLatest(stuck: true, hasRowsBelowWindow: false, hasNewer: true))
        #expect(!LatestWindowRules.showsBackToLatest(stuck: false, hasRowsBelowWindow: false, hasNewer: false))
    }
}

@Suite struct LatestWindowRulesIOS17Tests {
    @Test func iOS17KeepsAnExplicitRestoreWhenNewerIsTrimmed() {
        // A1-383 R3：iOS 17 没有可靠的 stuck，trimNewest 后（hasRowsBelowWindow 为假）仍须有恢复入口
        #expect(LatestWindowRules.showsBackToLatest(stuck: true, hasRowsBelowWindow: false, hasNewer: true, hasReliableBottom: false))
        #expect(!LatestWindowRules.showsBackToLatest(stuck: true, hasRowsBelowWindow: false, hasNewer: true, hasReliableBottom: true), "iOS 18+ 在底部时不重复出现")
    }
}
