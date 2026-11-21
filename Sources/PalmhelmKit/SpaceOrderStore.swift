import Foundation

/// 空间分组偏好的本机存储（#98）：独立键，与 ThreadArchiveStore、ThreadMarkStore 隔离。
/// 只存组键、顺序、置顶、手动与上移标记，以及用于改名判定的指纹；不存正文、权限或网络数据。
/// 损坏、未知版本或解码失败时安全回退为空（相当于自动规则）。
///
/// 加载与重置的契约（两端共用，A1-134 R5）：
/// - 加载得到的状态代次为 0、待应用上移为空；调用方的第一个有效快照（代次 ≥ 0）即被接受。
/// - 同一会话内，代次更小的快照不被接受（过期连接的迟到快照）。
/// - 重置（SpaceOrderEvent.reset）只清偏好与标记，不改变会话代次；两端应在用户确认后发送一次 reset，并保存返回的状态。
public struct SpaceOrderDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int = SpaceOrderDocument.currentVersion
    public var state: SpaceOrderState = SpaceOrderState()
    /// 组键 → 指纹（标签与最近见到的 terminalId）。键为稳定组 id。
    public var fingerprints: [String: SpaceFingerprint] = [:]
    /// 原始组键 → 当前稳定组 id（同一工作区 ID 下“复用为新组”时稳定 id 变为 原始键#n）。旧数据没有该字段。
    public var groupIds: [String: String] = [:]
    /// 原始组键 → 已分配过的最大代次（只增不减，复用时从它之后取号，旧代次的偏好永不串给新组）。
    public var generations: [String: Int] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case version, state, fingerprints, groupIds, generations }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? SpaceOrderDocument.currentVersion
        state = try c.decodeIfPresent(SpaceOrderState.self, forKey: .state) ?? SpaceOrderState()
        fingerprints = try c.decodeIfPresent([String: SpaceFingerprint].self, forKey: .fingerprints) ?? [:]
        groupIds = try c.decodeIfPresent([String: String].self, forKey: .groupIds) ?? [:]
        generations = try c.decodeIfPresent([String: Int].self, forKey: .generations) ?? [:]
    }
}

public final class SpaceOrderStore: @unchecked Sendable {
    public static let defaultKey = "palmhelm.spaceOrder.v1"
    private let defaults: UserDefaults
    private let storageKey: String

    public init(defaults: UserDefaults = .standard, storageKey: String = SpaceOrderStore.defaultKey) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// 读取；数据缺失、损坏或版本不认识时返回空文档。
    public func load() -> SpaceOrderDocument {
        guard let data = defaults.data(forKey: storageKey),
              let doc = try? JSONDecoder().decode(SpaceOrderDocument.self, from: data),
              doc.version == SpaceOrderDocument.currentVersion else {
            return SpaceOrderDocument()
        }
        return doc
    }

    /// 保存；编码失败时返回 false，调用方保留原内存状态。
    @discardableResult
    public func save(_ doc: SpaceOrderDocument) -> Bool {
        guard let data = try? JSONEncoder().encode(doc) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    /// 重置：删除偏好（回到自动规则）。
    public func clear() {
        defaults.removeObject(forKey: storageKey)
    }
}
