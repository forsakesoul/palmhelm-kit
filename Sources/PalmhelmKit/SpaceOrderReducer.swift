import Foundation

// 空间分组排序的纯 reducer（#98，设计 work/design/10-space-group-order.md）。
// 两端共用这一个规则：AppSession / MacSession 只在有效快照与用户动作时发送事件，并负责冻结（可见 / 离开）与渲染。
// 不读时钟、不写偏好、不做网络；输入全部由调用方给出。

/// 一个分组在某次快照中的事实。`id` 为 SpaceGroupKey.id（或 SpaceGroupKey.other）。
public struct SpaceGroupObservation: Sendable, Equatable {
    public var id: String
    public var label: String
    /// 组内任一在线成员为 working（仅阻塞不算）。
    public var running: Bool
    public var isOther: Bool
    public var terminalIds: Set<String>

    public init(id: String, label: String, running: Bool, isOther: Bool = false, terminalIds: Set<String> = []) {
        self.id = id; self.label = label; self.running = running; self.isOther = isOther; self.terminalIds = terminalIds
    }
}

/// 取消置顶时的前后锚点（置顶时的前一个、后一个组键；缺失为 nil）。
public struct SpaceAnchor: Codable, Sendable, Equatable {
    public var prev: String?
    public var next: String?
    public init(prev: String?, next: String?) { self.prev = prev; self.next = next }

    /// 旧数据只保存了前锚（字符串）：兼容解码为只有前锚的记录。
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let p = try? single.decode(String.self) {
            self.init(prev: p.isEmpty ? nil : p, next: nil)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(prev: try c.decodeIfPresent(String.self, forKey: .prev), next: try c.decodeIfPresent(String.self, forKey: .next))
    }

    private enum CodingKeys: String, CodingKey { case prev, next }
}

/// 持久状态（只存组键、顺序与标记，不存正文或权限）。代次与冻结中的待应用上移是会话瞬态，不写入存储；加载时从 0 开始。
public struct SpaceOrderState: Codable, Sendable, Equatable {
    /// 非置顶组的当前顺序（自动顺序与用户拖动的结果）。
    public var layout: [String] = []
    /// 置顶区顺序。
    public var pinned: [String] = []
    /// 拖动过的组：不再受运行状态移动，槽位固定。
    public var manual: Set<String> = []
    /// 已完成首次有效运行上移的组（结束与再次运行都不再移动它）。
    public var promoted: Set<String> = []
    /// 取消置顶时回到的前后锚点（会话内的组键）。
    public var anchors: [String: SpaceAnchor] = [:]
    /// 冻结期间记下、等离开列表再回来时应用的上移（按发生顺序）。会话瞬态，不持久化。
    public var pending: [String] = []
    /// 已接受的最新连接代次；更小的快照视为过期。会话瞬态，不持久化。
    public var generation: Int = 0

    public init() {}

    private enum CodingKeys: String, CodingKey { case layout, pinned, manual, promoted, anchors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decodeIfPresent([String].self, forKey: .layout) ?? []
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        manual = try c.decodeIfPresent(Set<String>.self, forKey: .manual) ?? []
        promoted = try c.decodeIfPresent(Set<String>.self, forKey: .promoted) ?? []
        anchors = try c.decodeIfPresent([String: SpaceAnchor].self, forKey: .anchors) ?? [:]
        pending = []
        generation = 0
    }

    /// 只写持久字段：代次与 pending 不进入存储。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(layout, forKey: .layout)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(manual, forKey: .manual)
        try c.encode(promoted, forKey: .promoted)
        try c.encode(anchors, forKey: .anchors)
    }
}

public enum SpaceOrderEvent: Sendable, Equatable {
    /// 一次快照。`effective` 由 SpaceObservationGate 给出；`frozen` 表示列表可见（浏览、拖动、焦点、滚动中）。
    case snapshot(groups: [SpaceGroupObservation], effective: Bool, frozen: Bool, generation: Int)
    /// 离开列表再回来：静默应用冻结期间记下的上移（仍在运行的组）。
    case reenter(groups: [SpaceGroupObservation], effective: Bool)
    /// 拖动（或读屏上移下移）：移到 `before` 之前；nil 表示末尾。标记为手动。
    case move(key: String, before: String?)
    case pin(String)
    case unpin(String)
    /// 置顶区内上移（delta < 0）或下移（delta > 0）。
    case pinMove(key: String, delta: Int)
    /// 设置里的“重置分组排序”：全部回到自动规则。
    case reset(groups: [SpaceGroupObservation])
}

/// 列表投影：置顶区与其余组（都已按可见集合过滤，保持稳定顺序）。纯函数，不写偏好。
public struct SpaceOrderProjection: Sendable, Equatable {
    public var pinned: [String]
    public var rest: [String]
}

public enum SpaceOrderReducer {
    public static func reduce(_ s: SpaceOrderState, _ e: SpaceOrderEvent) -> SpaceOrderState {
        var s = s
        switch e {
        case let .snapshot(groups, effective, frozen, generation):
            guard generation >= s.generation else { return s } // 过期代次：不接受
            s.generation = generation
            insertNew(groups, into: &s)
            let runners = groups.filter(\.running).map(\.id)
            if frozen {
                // 可见时不重排：只记下待应用的上移。
                for id in runners where eligible(id, in: s) && !s.pending.contains(id) { s.pending.append(id) }
            } else if effective {
                // 应用时重新核对：待应用的组必须仍在运行。
                let candidates = (s.pending.filter { runners.contains($0) } + runners).uniqued()
                apply(orderedBatch(candidates, in: s, groups: groups), in: &s)
                s.pending = []
            }
        case let .reenter(groups, effective):
            guard effective else { return s }
            let stillRunning = Set(groups.filter(\.running).map(\.id))
            let batch = orderedBatch(s.pending.filter { stillRunning.contains($0) }, in: s, groups: groups)
            apply(batch, in: &s)
            s.pending = []
        case let .move(key, before):
            guard !s.pinned.contains(key) else { return s }
            s.layout.removeAll { $0 == key }
            if let before, let i = s.layout.firstIndex(of: before) {
                s.layout.insert(key, at: i)
            } else {
                s.layout.append(key)
            }
            s.manual.insert(key)
            s.pending.removeAll { $0 == key }
        case let .pin(key):
            guard !s.pinned.contains(key), let i = s.layout.firstIndex(of: key) else { return s }
            s.anchors[key] = SpaceAnchor(prev: i > 0 ? s.layout[i - 1] : nil, next: i + 1 < s.layout.count ? s.layout[i + 1] : nil)
            s.layout.remove(at: i)
            s.pinned.append(key)
            s.pending.removeAll { $0 == key }
        case let .unpin(key):
            guard let i = s.pinned.firstIndex(of: key) else { return s }
            s.pinned.remove(at: i)
            let anchor = s.anchors.removeValue(forKey: key) ?? SpaceAnchor(prev: nil, next: nil)
            // 前锚仍在普通区：放在它之后；前锚已失效：用仍存活的后锚，放在它之前；两者都失效或原本在最前：放在最前。
            if let prev = anchor.prev, let at = s.layout.firstIndex(of: prev) {
                s.layout.insert(key, at: at + 1)
            } else if let next = anchor.next, let at = s.layout.firstIndex(of: next) {
                s.layout.insert(key, at: at)
            } else {
                s.layout.insert(key, at: 0)
            }
        case let .pinMove(key, delta):
            guard let i = s.pinned.firstIndex(of: key) else { return s }
            let j = min(max(i + delta, 0), s.pinned.count - 1)
            s.pinned.remove(at: i)
            s.pinned.insert(key, at: j)
        case let .reset(groups):
            s.layout = autoOrder(groups)
            s.pinned = []
            s.manual = []
            s.promoted = []
            s.pending = []
            s.anchors = [:]
        }
        return s
    }

    /// 纯投影：只过滤与保序，不改变存储的顺序（没有可见线程的组被隐藏，偏好保留）。
    public static func project(_ s: SpaceOrderState, visible: Set<String>) -> SpaceOrderProjection {
        SpaceOrderProjection(pinned: s.pinned.filter(visible.contains), rest: s.layout.filter(visible.contains))
    }

    /// 自动顺序：按名称，“其他”最后。
    public static func autoOrder(_ groups: [SpaceGroupObservation]) -> [String] {
        groups.sorted { a, b in
            if a.isOther != b.isOther { return !a.isOther }
            let c = a.label.localizedStandardCompare(b.label)
            if c != .orderedSame { return c == .orderedAscending }
            return a.id < b.id
        }.map(\.id)
    }

    // MARK: - 内部

    /// 可以被运行上移的组：不在置顶区、不是手动排序、尚未上移过。
    private static func eligible(_ id: String, in s: SpaceOrderState) -> Bool {
        !s.pinned.contains(id) && !s.manual.contains(id) && !s.promoted.contains(id)
    }

    /// 同批的顺序取当前布局中的顺序（不看到达顺序）。
    private static func orderedBatch(_ ids: [String], in s: SpaceOrderState, groups: [SpaceGroupObservation]) -> [String] {
        let live = Set(groups.map(\.id))
        let wanted = ids.filter { live.contains($0) && eligible($0, in: s) }
        return s.layout.filter { wanted.contains($0) }.uniqued()
    }

    /// 上移只在自动槽位内重排：手动槽位保持原位，自动槽位依次填入“本批 + 其余自动组（保持原相对顺序）”。
    private static func apply(_ batch: [String], in s: inout SpaceOrderState) {
        guard !batch.isEmpty else { return }
        let autoIdx = s.layout.indices.filter { !s.manual.contains(s.layout[$0]) }
        let autoIDs = autoIdx.map { s.layout[$0] }
        let newAuto = batch + autoIDs.filter { !batch.contains($0) }
        for (k, i) in autoIdx.enumerated() { s.layout[i] = newAuto[k] }
        s.promoted.formUnion(batch)
    }

    /// 新出现的组按自动顺序插入：放在第一个自动排序更靠后的、非手动非上移组之前；找不到则放在末尾。
    private static func insertNew(_ groups: [SpaceGroupObservation], into s: inout SpaceOrderState) {
        let known = Set(s.layout + s.pinned)
        let order = autoOrder(groups)
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        for id in order where !known.contains(id) {
            let r = rank[id] ?? 0
            let at = s.layout.firstIndex { other in
                guard let orr = rank[other], eligible(other, in: s) else { return false }
                return orr > r
            }
            if let at { s.layout.insert(id, at: at) } else { s.layout.append(id) }
        }
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
