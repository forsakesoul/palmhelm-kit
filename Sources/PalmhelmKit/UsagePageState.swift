import Foundation

/// 用量页的数据状态：决定卡内占位与页头副标题；页面网格始终渲染，状态只换卡内内容，不改卡位（Mac 与 iOS 共用）。
/// 纯函数：输入是会话里的事实（有无快照、是否在途、是否已完成过、错误、连接）。
public enum UsagePageState: Equatable {
    /// 加载中：没有快照，请求在途或尚未完成。
    case loading
    /// 首次无数据：连接正常，本范围请求已完成，但没有可用快照。
    case empty
    /// 加载失败：没有快照，且最近一次请求失败。
    case failed(String)
    /// 未连接：没有快照，也无法请求。
    case disconnected
    /// 有快照：可能正在后台静默刷新、可能离线显示上次数据、可能刷新失败但保留上次结果。
    case ready

    public static func from(hasData: Bool, loading: Bool, settled: Bool, error: String?, connected: Bool) -> UsagePageState {
        if hasData { return .ready }
        if !connected { return .disconnected }
        if let error { return .failed(error) }
        if loading || !settled { return .loading }
        return .empty
    }

    /// 页头副标题（固定一行）：状态替换原来的口径说明。
    public func headline(defaultText: String, lastUpdated: String?, refreshing: Bool, offline: Bool, failure: String?) -> String {
        switch self {
        case .loading: return KitL10n.string("正在加载用量…")
        case .empty: return KitL10n.string("这个范围还没有用量记录")
        case .failed(let e): return KitL10n.format("用量加载失败 · %@", e)
        case .disconnected: return KitL10n.string("未连接这台 Mac，连上后自动加载")
        case .ready:
            if offline, let t = lastUpdated { return KitL10n.format("离线 · 显示 %@ 的上次数据", t) }
            if let failure { return KitL10n.format("更新失败 · %@，下面是上次结果", failure) }
            if refreshing, let t = lastUpdated { return KitL10n.format("正在刷新 · 上次 %@", t) }
            if refreshing { return KitL10n.string("正在刷新…") }
            return defaultText
        }
    }
}
