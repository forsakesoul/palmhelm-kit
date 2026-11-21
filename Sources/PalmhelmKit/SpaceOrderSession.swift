import Foundation

// 空间分组的会话层纯逻辑（#98 接线，两端共用）：从线程输入得出分组、稳定身份、列表段与移动。
// 不读时钟、不写偏好、不做网络：调用方给出输入与生效判定，保存由调用方负责。
// 身份（指纹与组 id 映射）只在“当前代次的有效观察”下变更；无效、过期或不完整的快照只可读取。

/// 一个分组的解析结果（仅本次快照内有效，不持久化）。
public struct SpaceGroupRef: Sendable, Equatable {
    /// 当前稳定组 id（reducer 与偏好使用它）。
    public var id: String
    /// 原始组键（SpaceGroupKey.id 或 SpaceGroupKey.other）。
    public var rawId: String
    public var label: String
    public var isOther: Bool
    public var workspaceId: String?
    public var members: [LensInput]
    /// 组内任一在线成员为 working（离线的 working 不算）。
    public var running: Bool
    public var terminalIds: Set<String>

    public var fingerprint: SpaceFingerprint { SpaceFingerprint(label: label, terminalIds: terminalIds) }
}

public enum SpaceOrderSession {
    /// 分组（只看当前 Bridge）：工作区 ID 优先（新协议）；没有 ID 时按标签（旧协议，改名即新组）；没有工作区的目标归“其他”。
    public static func groups(bridgeId: String, items: [LensInput]) -> [SpaceGroupRef] {
        var order: [String] = []
        var buckets: [String: [LensInput]] = [:]
        var labels: [String: String] = [:]
        var workspaces: [String: String] = [:]
        var others = Set<String>()
        for item in items {
            let label = item.target?.location?.workspace ?? ""
            let raw: String
            if label.isEmpty {
                raw = SpaceGroupKey.other(bridgeId: bridgeId)
                others.insert(raw)
                labels[raw] = LensGrouping.otherSpace
            } else {
                let ws = item.target?.workspaceId.flatMap { $0.isEmpty ? nil : $0 }
                raw = SpaceGroupKey(bridgeId: bridgeId, workspaceId: ws, label: label).id
                labels[raw] = label
                if let ws { workspaces[raw] = ws }
            }
            if buckets[raw] == nil { order.append(raw) }
            buckets[raw, default: []].append(item)
        }
        return order.map { raw in
            let rows = (buckets[raw] ?? []).sorted(by: LensGrouping.spaceOrder)
            let terminals = Set(rows.compactMap { $0.target?.terminalId }.filter { !$0.isEmpty })
            let running = rows.contains { $0.target?.online == true && $0.target.flatMap(ThreadIdentity.status) == .working }
            return SpaceGroupRef(id: raw, rawId: raw, label: labels[raw] ?? raw, isOther: others.contains(raw), workspaceId: workspaces[raw],
                                 members: rows, running: running, terminalIds: terminals)
        }
    }

    /// 稳定 id（只读）。没有记录则用原始键；记录存在且身份为 same/renamed 则沿用；为 newGroup 则取下一代次（原始键#n）。
    /// 下一代次只依赖持久文档里已分配过的最大代次，所以不会撞号，也不会继承旧代次的偏好。
    public static func stableId(rawId: String, current: SpaceFingerprint, isOther: Bool, document: SpaceOrderDocument) -> String {
        if isOther { return rawId }
        let existing = document.groupIds[rawId] ?? rawId
        guard let stored = document.fingerprints[existing] else { return existing }
        switch SpaceIdentity.resolve(stored: stored, current: current) {
        case .same, .renamed: return existing
        case .newGroup: return "\(rawId)#\((document.generations[rawId] ?? 0) + 1)"
        }
    }

    /// 解析后的分组（只读）。
    public static func resolved(bridgeId: String, items: [LensInput], document: SpaceOrderDocument) -> [SpaceGroupRef] {
        groups(bridgeId: bridgeId, items: items).map { g in
            var g = g
            g.id = stableId(rawId: g.rawId, current: g.fingerprint, isOther: g.isOther, document: document)
            return g
        }
    }

    /// 有效快照（完整且新鲜，且不早于已接受的代次）：才更新身份（指纹与组 id 映射）并运行 reducer。
    /// 其它快照一律不改身份，也不运行 reducer（F2）。
    public static func applySnapshot(_ doc: inout SpaceOrderDocument, bridgeId: String, items: [LensInput], effective: Bool, frozen: Bool, generation: Int) {
        guard effective, generation >= doc.state.generation else { return }
        let groups = resolved(bridgeId: bridgeId, items: items, document: doc)
        for g in groups where !g.isOther {
            let previous = doc.groupIds[g.rawId] ?? g.rawId
            if previous != g.id {
                doc.groupIds[g.rawId] = g.id
                if let n = generationNumber(of: g.id, raw: g.rawId) { doc.generations[g.rawId] = max(doc.generations[g.rawId] ?? 0, n) }
            }
            let stored = doc.fingerprints[g.id]
            // 最近见到的 terminalId：本次有则替换，没有则保留（无 agent 的工作区不清空指纹）。
            let terminals = g.terminalIds.isEmpty ? (stored?.terminalIds ?? []) : g.terminalIds
            doc.fingerprints[g.id] = SpaceFingerprint(label: g.label, terminalIds: terminals)
        }
        doc.state = SpaceOrderReducer.reduce(doc.state, .snapshot(groups: observations(groups), effective: true, frozen: frozen, generation: generation))
    }

    /// 失效（断开、换连接、停止）：清除待应用的上移；偏好与身份保留。
    public static func invalidate(_ doc: inout SpaceOrderDocument) {
        doc.state.pending = []
    }

    /// 离开列表再回来：静默应用冻结期间记下的上移（仍在运行的组）。只在当前代次有效时应用。
    public static func reenter(_ doc: inout SpaceOrderDocument, bridgeId: String, items: [LensInput], effective: Bool) {
        guard effective else { return }
        let groups = resolved(bridgeId: bridgeId, items: items, document: doc)
        doc.state = SpaceOrderReducer.reduce(doc.state, .reenter(groups: observations(groups), effective: true))
    }

    /// 列表段（纯投影）：置顶区在前，其余按偏好顺序；偏好里没有的新组按自动顺序补在末尾。
    public static func sections(bridgeId: String, items: [LensInput], spaces: [SpaceInfo]?, document: SpaceOrderDocument) -> [LensSection] {
        let groups = resolved(bridgeId: bridgeId, items: items, document: document)
        let byId = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let visible = Set(groups.map(\.id))
        let projected = SpaceOrderReducer.project(document.state, visible: visible)
        var ordered = projected.pinned + projected.rest
        let known = Set(ordered)
        ordered += SpaceOrderReducer.autoOrder(observations(groups)).filter { !known.contains($0) }
        return ordered.compactMap { id -> LensSection? in
            guard let g = byId[id] else { return nil }
            let urgency = g.members.map(\.urgency).max() ?? .idle
            let footer = g.isOther ? nil : LensGrouping.agentlessFooter(spaceInfo(for: g, in: spaces))
            return LensSection(id: "space:\(g.id)", title: g.label, urgency: urgency, keys: g.members.map(\.key), footer: footer, collapsedByDefault: false)
        }
    }

    /// 页脚对应的空间：新协议按工作区 ID；只有旧 Bridge（没有 ID）才按标签。
    static func spaceInfo(for g: SpaceGroupRef, in spaces: [SpaceInfo]?) -> SpaceInfo? {
        if let ws = g.workspaceId { return spaces?.first { $0.workspaceId == ws } }
        return spaces?.first { $0.workspaceId == nil && $0.workspace == g.label }
    }

    /// 段 id（"space:" 前缀）→ 稳定组 id。
    public static func groupId(sectionId: String) -> String? {
        sectionId.hasPrefix("space:") ? String(sectionId.dropFirst("space:".count)) : nil
    }

    /// 能否移动（读屏动作与菜单据此禁用边界动作）。置顶组只在置顶区内移动；普通组不越过置顶区。
    public static func canMove(_ doc: SpaceOrderDocument, id: String, delta: Int, visible: [String]) -> Bool {
        guard visible.contains(id) else { return false }
        if doc.state.pinned.contains(id) { return pinNeighbour(doc, id: id, delta: delta, visible: visible) != nil }
        guard let i = visible.firstIndex(of: id), visible.indices.contains(i + delta) else { return false }
        return !(delta < 0 && doc.state.pinned.contains(visible[i + delta]))
    }

    /// 置顶组一步移动的目标：投影后可见置顶组中的邻居（隐藏的置顶偏好不计入，但保留在存储里）。
    private static func pinNeighbour(_ doc: SpaceOrderDocument, id: String, delta: Int, visible: [String]) -> String? {
        let shown = SpaceOrderReducer.project(doc.state, visible: Set(visible)).pinned
        guard let j = shown.firstIndex(of: id), shown.indices.contains(j + delta) else { return nil }
        return shown[j + delta]
    }

    /// 手动移动：delta 为 -1（上移一位）或 +1（下移一位），visible 为当前显示的分组 id 顺序（含置顶区）。
    public static func move(_ doc: inout SpaceOrderDocument, id: String, delta: Int, visible: [String]) {
        guard canMove(doc, id: id, delta: delta, visible: visible), let i = visible.firstIndex(of: id) else { return }
        if doc.state.pinned.contains(id) {
            // 完整偏好里的步数：跨过隐藏的置顶组一起计入，使它们的偏好位置保持不变（pinMove 的 delta 即此差值）。
            guard let nb = pinNeighbour(doc, id: id, delta: delta, visible: visible),
                  let from = doc.state.pinned.firstIndex(of: id), let to = doc.state.pinned.firstIndex(of: nb) else { return }
            doc.state = SpaceOrderReducer.reduce(doc.state, .pinMove(key: id, delta: to - from))
            return
        }
        // 把 id 放到目标位置的前面：上移时放在前一个之前；下移时放在后一个之后（即后一个的下一个之前）。
        let neighbour = delta < 0 ? visible[i + delta] : (visible.indices.contains(i + delta + 1) ? visible[i + delta + 1] : nil)
        doc.state = SpaceOrderReducer.reduce(doc.state, .move(key: id, before: neighbour))
    }

    /// 重置（设置里的确认后调用）：偏好回到自动规则；身份映射保留。
    public static func reset(_ doc: inout SpaceOrderDocument, bridgeId: String, items: [LensInput]) {
        let groups = resolved(bridgeId: bridgeId, items: items, document: doc)
        doc.state = SpaceOrderReducer.reduce(doc.state, .reset(groups: observations(groups)))
    }

    static func observations(_ groups: [SpaceGroupRef]) -> [SpaceGroupObservation] {
        groups.map { SpaceGroupObservation(id: $0.id, label: $0.label, running: $0.running, isOther: $0.isOther, terminalIds: $0.terminalIds) }
    }

    /// "原始键#n" 中的 n；没有后缀为 nil。
    static func generationNumber(of id: String, raw: String) -> Int? {
        guard id.hasPrefix(raw + "#") else { return nil }
        return Int(id.dropFirst(raw.count + 1))
    }
}
