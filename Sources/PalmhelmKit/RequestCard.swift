import Foundation

/// 请求卡的类型（h11 样式 A）：审批、提问、计划，以及提醒（超时 / 失败）。两端共用的纯数据映射，不含 UI。
public enum RequestCardKind: String, Sendable, CaseIterable {
    case approval, question, plan, alert

    public var symbolName: String {
        switch self {
        case .approval: "hand.raised"
        case .question: "questionmark.bubble"
        case .plan: "list.bullet.clipboard"
        case .alert: "clock"
        }
    }

    public var label: String {
        switch self {
        case .approval: KitL10n.string("审批")
        case .question: KitL10n.string("提问")
        case .plan: KitL10n.string("计划")
        case .alert: KitL10n.string("已超时 / 失败")
        }
    }

    /// 语义色角色：审批等你处理用 warn；提问与计划用 accent；超时 / 失败用 bad。
    public var tone: RequestCardTone {
        switch self {
        case .approval: .warn
        case .question, .plan: .accent
        case .alert: .bad
        }
    }
}

/// 卡片的语义色角色；具体颜色由调用方经 PalmhelmSemanticColor（warn / bad）或主题 token（accent）解析。
public enum RequestCardTone: Sendable, Equatable {
    case warn, accent, bad
}

/// 卡片上的独立 badge（不属于卡类型，可与任一类型并存）。
public enum RequestCardBadge: String, Sendable, CaseIterable {
    case offline, readOnly, inferredOwner

    public var label: String {
        switch self {
        case .offline: KitL10n.string("离线")
        case .readOnly: KitL10n.string("只读")
        case .inferredOwner: KitL10n.string("推测归属")
        }
    }
}
