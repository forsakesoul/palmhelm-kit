import Foundation

// 会话页的底部跟随（#60 后续）：两端共用的纯规则，与 Mac ThreadFollow 的判定一致。
// 只有贴底时新消息才跟到底；阅读历史时不拉走。布局变化（内容 / 视口 / 内边距）不改写贴底状态，否则重排会把「在底部」误判成「离开底部」。

public enum ThreadFollowRules {
    /// 距底 40pt 以内算贴底。`contentInsetBottom` 是底部安全区（底栏）遮住的部分，不算可见内容。
    public static func atBottom(contentOffsetY: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat, contentInsetBottom: CGFloat = 0) -> Bool {
        contentOffsetY + containerHeight - contentInsetBottom >= contentHeight - 40
    }

    /// 下一个贴底状态。用户正在滚动时以几何为准；否则布局未变时以几何为准，布局变化时沿用当前状态。
    public static func nextStuck(current: Bool, layoutChanged: Bool, atBottom: Bool, userScrolling: Bool) -> Bool {
        if userScrolling || !layoutChanged { return atBottom }
        return current
    }

    /// 是否跟随到底：贴底、没有定位 pin、对话页（非终端）。
    public static func follows(stuck: Bool, pinnedHit: String?, threadMode: Int) -> Bool {
        stuck && pinnedHit == nil && threadMode == 0
    }
}
