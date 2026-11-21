import Foundation
import Testing
@testable import PalmhelmKit

// 底部跟随：贴底阈值 40pt；布局变化不改写贴底；用户滚动以几何为准；定位与终端不跟随。
@Suite struct ThreadFollowRulesTests {
    @Test func bottomSlackIsFortyPoints() {
        // 内容 1000，视口 500：offset 500 正好到底
        #expect(ThreadFollowRules.atBottom(contentOffsetY: 500, contentHeight: 1000, containerHeight: 500))
        #expect(ThreadFollowRules.atBottom(contentOffsetY: 460, contentHeight: 1000, containerHeight: 500), "距底 40pt 仍算贴底")
        #expect(!ThreadFollowRules.atBottom(contentOffsetY: 459, contentHeight: 1000, containerHeight: 500), "距底超过 40pt 不算贴底")
    }

    @Test func bottomInsetIsNotVisibleContent() {
        #expect(!ThreadFollowRules.atBottom(contentOffsetY: 500, contentHeight: 1000, containerHeight: 500, contentInsetBottom: 100))
        #expect(ThreadFollowRules.atBottom(contentOffsetY: 600, contentHeight: 1000, containerHeight: 500, contentInsetBottom: 100))
    }

    @Test func layoutChangeKeepsStuckState() {
        // 贴底时内容增高：几何上已不在底部，但这是布局变化，沿用贴底状态
        #expect(ThreadFollowRules.nextStuck(current: true, layoutChanged: true, atBottom: false, userScrolling: false))
        // 离开底部后内容增高：仍不贴底
        #expect(!ThreadFollowRules.nextStuck(current: false, layoutChanged: true, atBottom: false, userScrolling: false))
    }

    @Test func userScrollFollowsGeometry() {
        #expect(!ThreadFollowRules.nextStuck(current: true, layoutChanged: true, atBottom: false, userScrolling: true), "用户上翻立即失去贴底")
        #expect(ThreadFollowRules.nextStuck(current: false, layoutChanged: false, atBottom: true, userScrolling: false), "无布局变化时几何为准")
    }

    @Test func followOnlyWhenStuckOnChatWithoutPin() {
        #expect(ThreadFollowRules.follows(stuck: true, pinnedHit: nil, threadMode: 0))
        #expect(!ThreadFollowRules.follows(stuck: false, pinnedHit: nil, threadMode: 0))
        #expect(!ThreadFollowRules.follows(stuck: true, pinnedHit: "m1", threadMode: 0), "定位视图不跟随")
        #expect(!ThreadFollowRules.follows(stuck: true, pinnedHit: nil, threadMode: 1), "终端页不跟随")
    }
}
