import Foundation

/// 无目标归属的条目（A1-035 第六条）：没有对应线程的请求、提醒或回执，需要决定它放在哪里。
public enum OrphanItem: Sendable, Equatable {
    /// 审批 / 提问 / 计划等请求：归全局待答（不属于任何线程）。
    case request(RequestCardKind)
    /// 失败或超时的提醒：归收件箱的提醒区（不计角标）。
    case alert
    /// 系统回执原文（switched:、ack:、queued:、配对等）。
    case receipt(String)
}

/// 无目标条目的去向。
public enum OrphanRoute: Sendable, Equatable {
    case pendingRequest, alert, drop
}

public enum ThreadRouting {
    /// 无目标条目的分类（表驱动，两端共用）。纯回执不展示；直达被拒（rejected:）属于失败，归提醒区。
    public static func route(_ item: OrphanItem) -> OrphanRoute {
        switch item {
        case .request: .pendingRequest
        case .alert: .alert
        case .receipt(let text): text.hasPrefix("rejected:") ? .alert : .drop
        }
    }
}
