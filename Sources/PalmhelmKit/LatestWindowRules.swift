import Foundation

// 对话区渲染窗口到底之后的动作与「↓ 回到最新」入口的判定（O1-381）。纯规则，不碰视图；视图负责执行并在执行前复核。

/// 手势结束、停在渲染窗口底部时的动作。
public enum LatestWindowAction: Equatable, Sendable {
    /// 本地向下展开一段：行已在内存里，不请求网络。
    case showNewerRows
    /// 已在真正缓存的尾端，只剩被裁掉的较新内容：回到最新（补拉）。
    case resumeLatest
    case none
}

public enum LatestWindowRules {
    /// 本地还有已加载未渲染的行时先本地展开（定位视图也允许，但不因此跳到最新）；
    /// 只有渲染窗口已在缓存尾端、且有被裁掉的较新内容时才回到最新。
    public static func actionAtWindowBottom(stuck: Bool, userScrolling: Bool, pinned: Bool, hasRowsBelowWindow: Bool, hasNewer: Bool) -> LatestWindowAction {
        guard stuck, !userScrolling else { return .none }
        if hasRowsBelowWindow { return .showNewerRows }
        if pinned { return .none }
        return hasNewer ? .resumeLatest : .none
    }

    /// 「↓ 回到最新」入口：本地窗口下方还有行，或离开底部且有被裁掉的较新内容。
    /// `hasReliableBottom` 为假（iOS 17：没有滚动相位，stuck 不随手势更新）时，被裁掉的较新内容始终保留显式入口（A1-383 R3）。
    public static func showsBackToLatest(stuck: Bool, hasRowsBelowWindow: Bool, hasNewer: Bool, hasReliableBottom: Bool = true) -> Bool {
        hasRowsBelowWindow || (hasNewer && (!stuck || !hasReliableBottom))
    }
}
