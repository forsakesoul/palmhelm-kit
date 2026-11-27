import Foundation

// #155 h29b（D10）：实时活动远程更新的传输类型。接口权威是 Bridge `docs/ops/local-api.md` 的 /v1/devices/self/live-activity。
// Kit 只负责编码、本地校验与状态码归类；ContentState 由 App 编码好后原样嵌入，Kit 不认识它的类型，也不重新编码 Date。

/// 待办的 wire 种类：审批（含提问、计划）与任务。
public enum LiveActivityItemKind: String, Codable, Sendable, Hashable {
    case approval, task
}

/// 一个待办引用（wire 的 `{kind, key}`）：审批为原始 approvalId，任务为 `ApiCommand.key`。
public struct LiveActivityRef: Codable, Sendable, Hashable {
    public var kind: LiveActivityItemKind
    public var key: String

    public init(kind: LiveActivityItemKind, key: String) {
        self.kind = kind
        self.key = key
    }
}

/// 登记 / 更新（PUT）。`stateJSON` 是 App 已编码的 ContentState（须为 JSON 对象），原样嵌入请求体。
public struct LiveActivityPut: Sendable, Equatable {
    public var activityId: String
    public var token: String
    public var environment: String
    public var rev: Int64
    public var ifSlot: String
    public var stateJSON: Data
    public var items: [LiveActivityRef]
    public var rowRefs: [LiveActivityRef]

    public init(activityId: String, token: String, environment: String, rev: Int64, ifSlot: String,
                stateJSON: Data, items: [LiveActivityRef], rowRefs: [LiveActivityRef]) {
        self.activityId = activityId
        self.token = token
        self.environment = environment
        self.rev = rev
        self.ifSlot = ifSlot
        self.stateJSON = stateJSON
        self.items = items
        self.rowRefs = rowRefs
    }
}

/// 关闭（DELETE）：activityId、token、environment 都须与当前登记一致，rev 不小于当前值。
public struct LiveActivityDelete: Sendable, Equatable {
    public var activityId: String
    public var token: String
    public var environment: String
    public var rev: Int64
    public var ifSlot: String

    public init(activityId: String, token: String, environment: String, rev: Int64, ifSlot: String) {
        self.activityId = activityId
        self.token = token
        self.environment = environment
        self.rev = rev
        self.ifSlot = ifSlot
    }
}

/// 三个方法的统一结果。App 只依据这几类做决定，不读原始状态码。
public enum LiveActivityOutcome: Sendable, Equatable {
    /// 成功；slotVer 是执行后的新版本（GET 为当前版本）。
    case ok(slotVer: String)
    /// `409 slot_conflict`：附当前 slotVer。
    case slotConflict(slotVer: String)
    /// 404：旧 Bridge，或未配置 APNs 发送器；App 退回本地更新。
    case unsupported
    /// 其它 4xx（含 413、不带 slotVer 的 409）：明确拒绝。
    case rejected(status: Int)
    /// 503、5xx、超时、网络：暂时失败，可退避重试。
    case transient
}

/// 发送前的本地校验失败（与 Bridge 的限制一致，不发出请求）。
public enum LiveActivityRequestError: Error, Sendable, Equatable {
    case invalid(String)
}

public enum LiveActivityWire {
    public static let maxItems = 100
    public static let maxKeyBytes = 128
    public static let maxRequestBytes = 16 * 1024
    public static let tokenLengths = 16...200

    /// 校验并生成 PUT 请求体：固定字段用 sortedKeys 编码，`state` 原样拼在末尾。
    public static func putBody(_ p: LiveActivityPut) throws -> Data {
        try validate(activityId: p.activityId, token: p.token, environment: p.environment, rev: p.rev, ifSlot: p.ifSlot)
        guard !p.items.isEmpty else { throw LiveActivityRequestError.invalid("items 为空") }
        guard let state = try? JSONSerialization.jsonObject(with: p.stateJSON) as? [String: Any],
              let rows = state["rows"] as? [Any] else {
            throw LiveActivityRequestError.invalid("state 须为带 rows 的 JSON 对象")
        }
        try validateRefs(items: p.items, rowRefs: p.rowRefs, rowCount: rows.count)
        struct Fields: Encodable {
            var activityId: String, token: String, environment: String, rev: Int64, ifSlot: String
            var items: [LiveActivityRef], rowRefs: [LiveActivityRef]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let fields = try encoder.encode(Fields(activityId: p.activityId, token: p.token, environment: p.environment,
                                               rev: p.rev, ifSlot: p.ifSlot, items: p.items, rowRefs: p.rowRefs))
        // fields 是以 } 结尾的对象：去掉结尾的 }，接上 state（原样字节）。
        var body = Data(fields.dropLast())
        body.append(Data(",\"state\":".utf8))
        body.append(p.stateJSON)
        body.append(Data("}".utf8))
        guard body.count <= maxRequestBytes else { throw LiveActivityRequestError.invalid("请求超过 16 KiB") }
        return body
    }

    public static func deleteBody(_ d: LiveActivityDelete) throws -> Data {
        try validate(activityId: d.activityId, token: d.token, environment: d.environment, rev: d.rev, ifSlot: d.ifSlot)
        struct Body: Encodable { var activityId: String, token: String, environment: String, rev: Int64, ifSlot: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Body(activityId: d.activityId, token: d.token, environment: d.environment, rev: d.rev, ifSlot: d.ifSlot))
    }

    static func validate(activityId: String, token: String, environment: String, rev: Int64, ifSlot: String) throws {
        guard !activityId.isEmpty, activityId.utf8.count <= maxKeyBytes else { throw LiveActivityRequestError.invalid("activityId") }
        guard ["development", "production"].contains(environment) else { throw LiveActivityRequestError.invalid("environment") }
        guard rev >= 1 else { throw LiveActivityRequestError.invalid("rev") }
        guard !ifSlot.isEmpty else { throw LiveActivityRequestError.invalid("ifSlot") }
        // 与 Bridge 一致：ASCII 十六进制、偶数位、16–200 位（大小写不敏感）。
        let isHex = token.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }
        guard tokenLengths.contains(token.utf8.count), token.utf8.count % 2 == 0, isHex else { throw LiveActivityRequestError.invalid("token") }
    }

    static func validateRefs(items: [LiveActivityRef], rowRefs: [LiveActivityRef], rowCount: Int) throws {
        guard items.count <= maxItems else { throw LiveActivityRequestError.invalid("items 超过 100 项") }
        guard Set(items).count == items.count else { throw LiveActivityRequestError.invalid("items 重复") }
        guard items.allSatisfy({ $0.key.utf8.count <= maxKeyBytes && !$0.key.isEmpty }) else { throw LiveActivityRequestError.invalid("key") }
        guard rowRefs.count == rowCount else { throw LiveActivityRequestError.invalid("rowRefs 与 rows 长度不同") }
        guard Set(rowRefs).count == rowRefs.count else { throw LiveActivityRequestError.invalid("rowRefs 重复") }
        let itemSet = Set(items)
        guard rowRefs.allSatisfy({ itemSet.contains($0) }) else { throw LiveActivityRequestError.invalid("rowRefs 不属于 items") }
    }
}
