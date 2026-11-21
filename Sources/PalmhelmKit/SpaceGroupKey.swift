import Foundation

// 空间分组的稳定键（#98）：bridgeId + workspaceId。旧 Bridge 没有 workspaceId 时退到 legacy 标签命名空间（改名视为新组，不猜迁移）。
// 只描述身份与指纹，不读取网络、不写偏好。

public struct SpaceGroupKey: Hashable, Sendable {
    public let bridgeId: String
    /// 新协议的工作区 ID；nil 表示旧 Bridge。
    public let workspaceId: String?
    /// 显示标签；只在旧协议下参与键。
    public let label: String

    public init(bridgeId: String, workspaceId: String?, label: String) {
        self.bridgeId = bridgeId; self.workspaceId = workspaceId; self.label = label
    }

    public var id: String {
        if let workspaceId { return "\(bridgeId)|ws|\(workspaceId)" }
        return "\(bridgeId)|label|\(label)"
    }

    /// “其他”分组（没有工作区的目标）的键：不随标签变化。
    public static func other(bridgeId: String) -> String { "\(bridgeId)|other" }
}

/// 分组的指纹：保存时的标签与最近见到的 agent terminalId 集合（只用于本机判定改名与复用，不外发）。
public struct SpaceFingerprint: Codable, Sendable, Equatable {
    public var label: String
    public var terminalIds: Set<String>

    public init(label: String, terminalIds: Set<String>) {
        self.label = label; self.terminalIds = terminalIds
    }
}

/// 同一工作区 ID 下，标签变化时的判定（W2-107 规则）。
public enum SpaceIdentityDecision: Equatable, Sendable {
    /// 标签相同：同组。
    case same
    /// 标签变化，但记录过的任一 terminalId 仍在：视为改名，保留偏好。
    case renamed
    /// 标签变化且没有任何 terminalId 存活（或没有指纹证据）：视为新组，不继承偏好。
    case newGroup
}

public enum SpaceIdentity {
    public static func resolve(stored: SpaceFingerprint, current: SpaceFingerprint) -> SpaceIdentityDecision {
        if stored.label == current.label { return .same }
        if !stored.terminalIds.isDisjoint(with: current.terminalIds) { return .renamed }
        return .newGroup
    }
}

/// 有效观察门禁（#98 与 #97 共用的口径）：完整且新鲜（fresh 明确为真）。客户端不以收到时间代替新鲜度。
/// #97 提交后，ThreadArchive 的观察判定改为调用这里（另包）；本文件先不改 #97 的文件。
public enum SpaceObservationGate {
    public static func effective(complete: Bool, fresh: Bool?) -> Bool {
        complete && fresh == true
    }
}
