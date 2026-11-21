import Foundation

// 对话列表的“视角”（设计文档 reins-thread-identity §8）：同一批线程按不同规则分组。
// 纯函数，两端共用；输入只用线程编号与身份字段，应用自己把编号映射回行。

/// 对话列表的视角（h10a）：只有「收件箱」（需要你处理：待答 + 工作中）与「空间」（按工作区列全部）。
/// 旧版本存过的 branch / group 不再是视角，解码与读取偏好时回落为空间。
public enum ThreadLens: String, Sendable, CaseIterable, Codable {
    case inbox, spaces

    public var label: String {
        switch self { case .spaces: KitL10n.string("空间"); case .inbox: KitL10n.string("收件箱") }
    }

    /// 从持久化值还原：未知、旧值（branch / group）与缺省都回落为空间。
    public static func fromStored(_ raw: String?) -> ThreadLens { raw.flatMap(ThreadLens.init(rawValue:)) ?? .spaces }

    public init(from decoder: Decoder) throws {
        self = ThreadLens.fromStored(try decoder.singleValueContainer().decode(String.self))
    }
}

/// 紧急度：等你 > 完成未读 > 工作中 > 空闲。
public enum Urgency: Int, Sendable, Comparable {
    case idle = 0, working, unread, waiting

    public static func < (a: Urgency, b: Urgency) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self { case .waiting: KitL10n.string("等你"); case .unread: KitL10n.string("完成未读"); case .working: KitL10n.string("工作中"); case .idle: KitL10n.string("空闲") }
    }
}

public struct LensInput: Sendable, Equatable {
    public var key: String
    public var target: TargetSummary?
    public var title: String
    /// 最近活动的单调序号（回执 seq 等）；越大越新。
    public var lastActivity: Int
    public var pendingApprovals: Int
    public var unread: Bool
    public var pinned: Bool

    public init(key: String, target: TargetSummary?, title: String, lastActivity: Int, pendingApprovals: Int = 0, unread: Bool = false, pinned: Bool = false) {
        self.key = key; self.target = target; self.title = title; self.lastActivity = lastActivity
        self.pendingApprovals = pendingApprovals; self.unread = unread; self.pinned = pinned
    }

    public var urgency: Urgency {
        if pendingApprovals > 0 || target.flatMap(ThreadIdentity.status) == .blocked { return .waiting }
        if target.flatMap(ThreadIdentity.status) == .working { return .working }
        return unread ? .unread : .idle
    }
}

public struct LensSection: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// 组内最紧急的状态（空间视角显示在组名后）；收件箱视角的段本身就是紧急度。
    public var urgency: Urgency
    public var keys: [String]
    /// 组底说明，如“另有 2 个标签没有 agent”。
    public var footer: String?
    public var collapsedByDefault: Bool
    public init(id: String, title: String, urgency: Urgency, keys: [String], footer: String? = nil, collapsedByDefault: Bool = false) {
        self.id = id; self.title = title; self.urgency = urgency; self.keys = keys; self.footer = footer; self.collapsedByDefault = collapsedByDefault
    }
}

public enum LensGrouping {
    /// 没有工作区的条目：展示为“其他”，分组键用不会与真实 label 冲突的内部值（不拿显示文本当身份）。
    public static var otherSpace: String { KitL10n.string("其他") }
    static let otherKey = "\u{0}other"

    public static func sections(_ lens: ThreadLens, _ items: [LensInput], spaces: [SpaceInfo]? = nil) -> [LensSection] {
        switch lens {
        case .spaces: bySpace(items, spaces: spaces)
        case .inbox: byUrgency(items)
        }
    }

    /// 推荐视角：≥ 2 个工作区 → 空间，否则收件箱。
    public static func recommend(_ items: [LensInput], spaces: [SpaceInfo]? = nil) -> ThreadLens {
        workspaceCount(items, spaces) >= 2 ? .spaces : .inbox
    }

    /// 结构签名：只随工作区数变化（编组 / 分支已不是视角）。
    public static func structureSignature(_ items: [LensInput], spaces: [SpaceInfo]? = nil) -> String {
        "w\(workspaceCount(items, spaces))"
    }

    static func workspaceCount(_ items: [LensInput], _ spaces: [SpaceInfo]?) -> Int {
        Set(items.compactMap { $0.target?.location?.workspace }.filter { !$0.isEmpty }).union((spaces ?? []).map(\.workspace)).count
    }

    /// 空间：按工作区 label 分组，组的顺序按名字固定（不随新消息跳动）；组内按 设计 → 执行 → 顾问 → 其他，再按标签、标题。
    static func bySpace(_ items: [LensInput], spaces: [SpaceInfo]?) -> [LensSection] {
        let groups = Dictionary(grouping: items) { $0.target?.location?.workspace.flatMap { $0.isEmpty ? nil : $0 } ?? otherKey }
        let names = groups.keys.sorted { a, b in
            if (a == otherKey) != (b == otherKey) { return b == otherKey }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return names.map { name in
            let rows = groups[name]!.sorted(by: spaceOrder)
            let isOther = name == otherKey
            return LensSection(id: "space:\(name)", title: isOther ? otherSpace : name, urgency: rows.map(\.urgency).max() ?? .idle,
                               keys: rows.map(\.key), footer: isOther ? nil : agentlessFooter(spaces?.first { $0.workspace == name }), collapsedByDefault: false)
        }
    }

    /// 组内先按标签（一个标签通常就是一个编组），标签内再按 设计 → 执行 → 顾问。
    static func spaceOrder(_ a: LensInput, _ b: LensInput) -> Bool {
        let ta = a.target?.location?.tab ?? "", tb = b.target?.location?.tab ?? ""
        if ta != tb { return ta.localizedStandardCompare(tb) == .orderedAscending }
        let ra = a.target.flatMap(ThreadIdentity.role)?.order ?? 9, rb = b.target.flatMap(ThreadIdentity.role)?.order ?? 9
        if ra != rb { return ra < rb }
        if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
        return a.key < b.key // 展示字段全同时按编号，输入顺序变化也不换序
    }

    static func agentlessFooter(_ space: SpaceInfo?) -> String? {
        guard let n = space?.agentlessTabCount, n > 0 else { return nil }
        return KitL10n.format("另有 %lld 个标签没有 agent", n)
    }

    /// 收件箱（h10a K1）：只含需要你处理的——等你（待答）与工作中；空闲与已读不出现，去空间视角看。
    /// 段内钉住的在前，再按最近活动。
    static func byUrgency(_ items: [LensInput]) -> [LensSection] {
        let groups = Dictionary(grouping: items.filter { $0.urgency == .waiting || $0.urgency == .working }, by: \.urgency)
        return [Urgency.waiting, .working].compactMap { u in
            guard let rows = groups[u], !rows.isEmpty else { return nil }
            let sorted = rows.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return a.lastActivity != b.lastActivity ? a.lastActivity > b.lastActivity : a.key < b.key
            }
            return LensSection(id: "urgency:\(u.rawValue)", title: u.label, urgency: u, keys: sorted.map(\.key), footer: nil, collapsedByDefault: false)
        }
    }
}

/// 已读 / 钉住 / 标为未读：由 Palmhelm 自己记，每台设备各自一份，不跟随 Herdr 的 done 标记（§8）。
public struct ThreadMarks: Codable, Sendable, Equatable {
    public var seen: Int = 0
    public var pinned = false
    public var markedUnread = false
    public init() {}

    public func isUnread(lastActivity: Int) -> Bool { markedUnread || lastActivity > seen }
}

public final class ThreadMarkStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()
    private var cache: [String: ThreadMarks]

    public init(defaults: UserDefaults = .standard, storageKey: String = "palmhelm.threadMarks.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        cache = (defaults.data(forKey: storageKey)).flatMap { try? JSONDecoder().decode([String: ThreadMarks].self, from: $0) } ?? [:]
    }

    public func marks(_ key: String) -> ThreadMarks { lock.withLock { cache[key] ?? ThreadMarks() } }

    /// 打开线程：看到的位置推进到 lastActivity，并清掉手动未读。
    public func markSeen(_ key: String, through lastActivity: Int) { update(key) { $0.seen = max($0.seen, lastActivity); $0.markedUnread = false } }
    public func setPinned(_ key: String, _ pinned: Bool) { update(key) { $0.pinned = pinned } }
    public func markUnread(_ key: String) { update(key) { $0.markedUnread = true } }

    /// 每台 Mac（bridge 编号）只做一次的初始基线：把装上新版本前已有的线程记为已看，免得旧对话全成未读。
    /// 基线建立之后新出现的线程从 seen=0 开始（刷新不会把还没看的新线程当成已读）。
    public func seedBaselineIfNeeded(bridge: String, _ entries: [(key: String, lastActivity: Int)]) {
        lock.withLock {
            let flag = "\(storageKey).baseline.\(bridge)"
            guard !defaults.bool(forKey: flag) else { return }
            for e in entries where cache[e.key] == nil { var m = ThreadMarks(); m.seen = e.lastActivity; cache[e.key] = m }
            if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: storageKey) }
            defaults.set(true, forKey: flag)
        }
    }

    private func update(_ key: String, _ change: (inout ThreadMarks) -> Void) {
        lock.withLock {
            var m = cache[key] ?? ThreadMarks()
            change(&m)
            cache[key] = m
            if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: storageKey) }
        }
    }
}
