import Foundation

/// 本机发出的 owner 操作（与飞书私聊同一套指令）的种类。它们没有排队指令记录，结果只来自系统回执 ack:<eventKey>。
public enum OwnerOperationKind: Sendable, Equatable {
    case panel, tasks, resetOccupancy, switchTo
}

public enum OwnerOperation {
    /// Bridge 的 JS `\s` 集合（ownercmd/parse.go jsSpaceSet）：Swift 的 whitespaces 与它不等价（缺 U+FEFF、含 U+0085 等），照服务端定义。
    static func isSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09...0x0d, 0x20, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff: true
        case 0x2000...0x200a: true
        default: false
        }
    }

    /// 整串分类，与服务端 ParseReset / ParseSwitch 的整串语法等价（含 Unicode 空白）：自然语句、多余参数、缺空白都不是 owner 操作。
    public static func kind(ofWire text: String) -> OwnerOperationKind? {
        let tokens = text.unicodeScalars.split(whereSeparator: isSpace).map { String(String.UnicodeScalarView($0)) }
        guard let head = tokens.first else { return nil }
        let rest = Array(tokens.dropFirst())
        if tokens.count == 1, head == OwnerCommand.panel { return .panel }
        if tokens.count == 1, head == OwnerCommand.tasks { return .tasks }
        if head == "重置占用" {
            // 重置占用 X [#<eventKey>]：X 不以 # 开头；条件 key 至少一个字符
            if rest.count == 1, !rest[0].hasPrefix("#") { return .resetOccupancy }
            if rest.count == 2, !rest[0].hasPrefix("#"), rest[1].hasPrefix("#"), rest[1].count > 1 { return .resetOccupancy }
            return nil
        }
        if head == "切换到" || head == "切换" { return (1...2).contains(rest.count) ? .switchTo : nil }
        if head.lowercased() == "switch" {
            if (1...2).contains(rest.count) { return .switchTo }
            if rest.first?.lowercased() == "to", (1...2).contains(rest.count - 1) { return .switchTo }
        }
        return nil
    }
}

/// owner 回执（ack 正文）的结构化结果。只认完整、可信的形式；畸形、负数、未知前缀一律 nil，不当成功。
public enum OwnerOperationResult: Sendable, Equatable {
    case reset(released: Int)
    case switched
    case rejected(String)
}

public enum OwnerOperationParser {
    public static func result(ack text: String) -> OwnerOperationResult? {
        if text.hasPrefix("reset:") {
            let n = text.dropFirst("reset:".count)
            guard !n.isEmpty, n.count <= 9, n.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(n) else { return nil }
            return .reset(released: v)
        }
        if text.hasPrefix("switched:"), text.count > "switched:".count { return .switched }
        if text.hasPrefix("rejected:") { return .rejected(String(text.dropFirst("rejected:".count))) }
        return nil
    }

    /// 结果的人话（同一文案供线程回执行、本机操作行共用）。reset:0 是成功：放弃跟踪 0 条，不是“没执行”。
    public static func summary(_ r: OwnerOperationResult) -> String? {
        switch r {
        case .reset(let n):
            n == 0 ? KitL10n.string("已解除 Bridge 占用（没有需要停止跟踪的命令）；终端里的 agent 不受影响")
                   : KitL10n.format("已解除 Bridge 占用，停止跟踪 %lld 条命令；终端里的 agent 不受影响，可能已执行的输入不会撤销", n)
        case .switched, .rejected: nil
        }
    }
}

extension OwnerCommand {
    /// 对一个稳定目标 id 的人工“重置占用”原文。id 必须能被 Bridge 的指令解析器无损读成同一个名字（无空白、控制字符、`#`），否则 nil，不给入口。
    public static func resetOccupancy(targetId: String) -> String? {
        let bad = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(.illegalCharacters).union(CharacterSet(charactersIn: "#"))
        guard !targetId.isEmpty, targetId.unicodeScalars.allSatisfy({ !bad.contains($0) }) else { return nil }
        return resetOccupancy(targetId)
    }
}

/// 确认框捕获的“重置当前线程”请求：目标与 scope 在打开确认时固定，确认时 Session 复核后才发送，不读飞书绑定。
public struct OwnerResetRequest: Sendable, Equatable {
    public let scope: LedgerScope
    public let displayName: String
    public let command: String

    public init?(scope: LedgerScope, displayName: String) {
        guard let command = OwnerCommand.resetOccupancy(targetId: scope.targetId) else { return nil }
        self.scope = scope; self.displayName = displayName; self.command = command
    }
}

public enum OwnerResetStart: Sendable, Equatable {
    case sent(UUID)
    case refused(String)
}

/// owner 操作在线程里的稳定位置（纯结果）：发起时记录 transcript 尾 itemId 作为本地锚，之后新增的消息排在其后；
/// 锚不在可见窗口（含旧记录没有锚）进入“本机操作记录”分组，不猜位置。
public struct OwnerPlacement<Echo> {
    public var after: [String: [Echo]]
    public var local: [Echo]
    public init(after: [String: [Echo]] = [:], local: [Echo] = []) { self.after = after; self.local = local }
    public var isEmpty: Bool { after.isEmpty && local.isEmpty }
}

extension OwnerPlacement: Equatable where Echo: Equatable {}

public enum OwnerPlacementRules {
    /// `ops` 已按发送序（at、稳定 ID）排序；`anchor` 为发起时的 transcript 尾 itemId。`allowLocal`：只在最新窗显示无锚分组。
    public static func place<Echo>(_ ops: [(op: Echo, anchor: String?)], visibleItemIds: Set<String>, allowLocal: Bool) -> OwnerPlacement<Echo> {
        var p = OwnerPlacement<Echo>()
        for (op, anchor) in ops {
            if let a = anchor, visibleItemIds.contains(a) { p.after[a, default: []].append(op) }
            else if allowLocal { p.local.append(op) }
        }
        return p
    }
}

public enum OwnerOperationCopy {
    public static var scopeChanged: String { KitL10n.string("目标或连接已变化，没有解除占用") }
    public static var noTarget: String { KitL10n.string("没有可用的目标，没有解除占用") }
}
