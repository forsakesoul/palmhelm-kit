import Foundation

/// Bridge 为一条 canonical 状态文案附带的语义（`displayMessage:{key,params}`）。只是展示建议：
/// 不能据它决定权限、恢复/发送动作、来源归属；任何不合规（未知 key、缺必需参数、签名外参数、类型/上限不符、未知枚举）都只回退该条原 text。
public struct DisplayMessage: Sendable, Equatable {
    public indirect enum Param: Sendable, Equatable {
        case text(String)
        case count(Int)
        /// Bridge 生成的名称占位（unnamed / hidden / target）：客户端显示本地化占位。
        case placeholder(String)
        case lines([[String: Param]])
        /// 形状非法的参数值（布尔、嵌套错误的对象等）：保留这一事实，渲染时整条回退原文。
        case invalid
    }
    public let key: String
    public let params: [String: Param]
    public init(key: String, params: [String: Param]) { self.key = key; self.params = params }
}

/// 宽松解码：形状不对只得到 nil（或带 .invalid 参数的消息），绝不使整条记录/整批解码失败。
public struct LossyDisplayMessage: Codable, Sendable, Equatable {
    public let value: DisplayMessage?
    public init(_ value: DisplayMessage?) { self.value = value }

    private enum Raw: Decodable {
        case string(String), int(Int), object([String: Raw]), array([Raw]), other
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let v = try? c.decode(Int.self) { self = .int(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([String: Raw].self) { self = .object(v) }
            else if let v = try? c.decode([Raw].self) { self = .array(v) }
            else { self = .other }
        }
        var param: DisplayMessage.Param {
            switch self {
            case .string(let s): return .text(s)
            case .int(let n): return .count(n)
            case .object(let o):
                if o.count == 1, case .string(let p)? = o["placeholder"] { return .placeholder(p) }
                return .invalid
            case .array(let a):
                var rows: [[String: DisplayMessage.Param]] = []
                for r in a { guard case .object(let o) = r else { return .invalid }; rows.append(o.mapValues(\.param)) }
                return .lines(rows)
            case .other: return .invalid
            }
        }
    }

    public init(from decoder: Decoder) throws {
        struct Wire: Decodable { let key: String; let params: [String: Raw]? }
        guard let w = try? Wire(from: decoder) else { value = nil; return }
        value = DisplayMessage(key: w.key, params: (w.params ?? [:]).mapValues(\.param))
    }

    /// 与解码对称：写回原 key/params；无有效值写 null。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        guard let v = value else { try c.encodeNil(); return }
        struct Out: Encodable {
            let key: String; let params: [String: P]
            struct P: Encodable {
                let p: DisplayMessage.Param
                func encode(to e: Encoder) throws {
                    var c = e.singleValueContainer()
                    switch p {
                    case .text(let s): try c.encode(s)
                    case .count(let n): try c.encode(n)
                    case .placeholder(let k): try c.encode(["placeholder": k])
                    case .lines(let rows): try c.encode(rows.map { $0.mapValues { P(p: $0) } })
                    case .invalid: try c.encodeNil()
                    }
                }
            }
        }
        try c.encode(Out(key: v.key, params: v.params.mapValues { Out.P(p: $0) }))
    }
}

public enum BridgeDisplayMessage {
    private struct Sig { let name: String; let kind: Character; let optional: Bool; let group: String? }
    private static func parse(_ s: String) -> [Sig] {
        s.split(separator: ",").map { raw in
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            var name = parts[0]; let optional = name.hasSuffix("?"); if optional { name.removeLast() }
            let spec = parts.count > 1 ? parts[1] : "t"
            let group = spec.hasPrefix("e/") ? String(spec.dropFirst(2)) : nil
            return Sig(name: name, kind: spec.first ?? "t", optional: optional, group: group)
        }
    }

    private static let maxTextBytes = 200, maxSummaryBytes = 600, maxCount = 1_000_000, maxLines = 8
    private static func id(_ suffix: String) -> String { "bridge.msg." + suffix }
    /// 目录里没有该 id（或为空）时返回 nil：用于判断可选尾句是否存在。
    private static func catalog(_ id: String) -> String? { let v = KitL10n.string(id, default: ""); return v.isEmpty || v == id ? nil : v }

    private static func textValue(_ p: DisplayMessage.Param?, limit: Int = maxTextBytes) -> String? {
        switch p {
        case .text(let s): s.utf8.count <= limit && !s.contains(where: \.isNewline) ? s : nil
        case .placeholder(let k): catalog(id("placeholder." + k))
        default: nil
        }
    }
    private static func countValue(_ p: DisplayMessage.Param?) -> Int? {
        if case .count(let n) = p, (0...maxCount).contains(n) { return n }
        return nil
    }
    private static func enumValue(_ p: DisplayMessage.Param?, group: String) -> String? {
        guard case .text(let tok) = p, tok.utf8.count <= 64 else { return nil }
        return catalog(id("enum.\(group).\(tok)"))
    }

    /// 模板只扫描一次：`{name}` 取参数的字面值插入，插入内容不再被解析（参数里的花括号、占位词、emoji 都是普通文字）。
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""; var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let close = template[i...].firstIndex(of: "}"), let v = values[String(template[template.index(after: i)..<close])] {
                out += v; i = template.index(after: close)
            } else { out.append(template[i]); i = template.index(after: i) }
        }
        return out
    }

    /// 当前显示语言下的文案；nil = 回退原 text。
    public static func text(_ m: DisplayMessage) -> String? {
        guard let sig = signatures[m.key] else { return nil }
        let specs = parse(sig)
        guard Set(m.params.keys).isSubset(of: Set(specs.map(\.name))) else { return nil } // 签名外参数：不信任整条
        if customKeys.contains(m.key) { return custom(m) }
        var values: [String: String] = [:]; var present: Set<String> = []
        for s in specs {
            let p = m.params[s.name]
            if p == nil { if s.optional { continue }; return nil }
            switch s.kind {
            case "t": guard let v = textValue(p, limit: s.name == "summary" ? maxSummaryBytes : maxTextBytes) else { return nil }; values[s.name] = v
            case "n": guard let n = countValue(p) else { return nil }; values[s.name] = KitL10n.number(n)
            case "e":
                if s.group == "pausedNote" { guard case .text("1")? = p else { return nil }; values[s.name] = "1" }
                else { guard let v = enumValue(p, group: s.group ?? "") else { return nil }; values[s.name] = v }
            default: return nil
            }
            present.insert(s.name)
        }
        guard let base = catalog(id(m.key)) else { return nil }
        var out = fill(base, values)
        for s in specs where s.optional {
            if present.contains(s.name) { if let t = catalog(id("\(m.key).\(s.name)")) { out += fill(t, values) } }
            else if let t = catalog(id("\(m.key).else.\(s.name)")) { out += fill(t, values) }
        }
        if let t = catalog(id("\(m.key).always")) { out += fill(t, values) }
        return out
    }

    private static func custom(_ m: DisplayMessage) -> String? {
        func part(_ n: String, _ v: [String: String] = [:]) -> String? { catalog(id("\(m.key).\(n)")).map { fill($0, v) } }
        switch m.key {
        case "routing.candidates":
            guard let target = textValue(m.params["target"]), case .lines(let rows)? = m.params["lines"], !rows.isEmpty, rows.count <= maxLines,
                  let head = part("head", ["target": target]), let foot = part("foot") else { return nil }
            var lines: [String] = []
            for (i, r) in rows.enumerated() {
                guard r.count == 2, let k = textValue(r["kind"]), let a = textValue(r["agent"]) else { return nil }
                lines.append("\(i + 1). \(k) / \(a)")
            }
            return ([head] + lines + [foot]).joined(separator: "\n")
        case "inbox.switched":
            // Bridge 的 3×3 尾注组合：reverified/reverifiedPaused 是 1 标志，swapped 带可选计数；reverifiedPaused 必须伴随 reverified。
            guard let target = textValue(m.params["id"]), let rev = countValue(m.params["rev"]), var out = part("base", ["id": target, "rev": KitL10n.number(rev)]) else { return nil }
            func flag(_ n: String) -> Bool? { guard let p = m.params[n] else { return false }; if case .count(1) = p { return true }; return nil }
            guard let re = flag("reverified"), let rp = flag("reverifiedPaused"), !(rp && !re) else { return nil }
            if re { out += part(rp ? "reverified.paused" : "reverified") ?? "" }
            if m.params["swapped"] != nil {
                guard let name = textValue(m.params["swapped"]) else { return nil }
                if m.params["swappedPaused"] != nil {
                    guard let n = countValue(m.params["swappedPaused"]) else { return nil }
                    out += part("swapped.paused", ["swapped": name, "swappedPaused": KitL10n.number(n)]) ?? ""
                } else { out += part("swapped", ["swapped": name]) ?? "" }
            } else if m.params["swappedPaused"] != nil { return nil }
            return out
        case "watch.activity":
            guard let group = textValue(m.params["group"]), case .lines(let rows)? = m.params["lines"], !rows.isEmpty, rows.count <= 12,
                  let head = part("head", ["group": mdLiteral(group)]), let foot = part("foot") else { return nil }
            var out = [head]
            for r in rows {
                guard let role = enumToken(r["role"], ["owner", "worker", "advisor"]), let ev = enumToken(r["event"], ["appeared", "disappeared", "left_group", "identity_changed", "new_completion", "state_changed"]),
                      let name = textValue(r["name"]), let roleText = part("role." + role) else { return nil }
                var allowed: Set<String> = ["role", "name", "event"]
                var evText: String
                if ev == "state_changed" {
                    allowed.formUnion(["from", "to"])
                    guard let f = enumToken(r["from"], ["working", "ready", "blocked", "unknown"]), let t = enumToken(r["to"], ["working", "ready", "blocked", "unknown"]),
                          let fs = part("state." + f), let ts = part("state." + t), let e = part("event.state_changed", ["from": fs, "to": ts]) else { return nil }
                    evText = e
                } else { guard let e = part("event." + ev) else { return nil }; evText = e }
                guard Set(r.keys).isSubset(of: allowed) else { return nil }
                guard let line = part("line", ["role": roleText, "name": mdLiteral(name), "event": evText]) else { return nil }
                out.append(line)
            }
            return (out + [foot]).joined(separator: "\n")
        default: return nil
        }
    }

    private static func enumToken(_ p: DisplayMessage.Param?, _ allowed: [String]) -> String? {
        if case .text(let t)? = p, allowed.contains(t) { return t }
        return nil
    }
    /// 关注通知的 Markdown 正文里，名称按字面显示：转义 Markdown 控制字符（与 Bridge 的 MdLiteral 一致，只作用于显示）。
    static func mdLiteral(_ s: String) -> String {
        var out = ""; for ch in s { if "\\`*_{}[]()#+-.!|>~<".contains(ch) { out.append("\\") }; out.append(ch) }
        return out
    }
}

extension HistoryItem {
    /// 英文等非中文显示语言下，这条状态的语义化文案；中文（原文即 canonical）、无元数据或不合规时为 nil——调用方回退既有的原文展示。
    public var localizedDisplayMessage: String? {
        guard let m = displayMessage?.value, !KitL10n.isChinese else { return nil }
        return BridgeDisplayMessage.text(m)
    }
}
