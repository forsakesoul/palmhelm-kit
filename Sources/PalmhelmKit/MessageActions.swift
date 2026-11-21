import Foundation

// 发送时机（#23）：能力提示、排队中的消息操作（立即插入 / 撤回）与固定错误码。
// 只做解码、校验与文案，不碰网络以外的状态；界面（设计稿待定）由 App 层决定怎么用。

/// Bridge 的能力提示：只是提示，不代表授权，也不保证一直成立。
public struct TargetCapabilities: Codable, Sendable, Equatable {
    public var steer: Bool
    public var queueDeadline: Bool?
    /// 原生直达插话（Bridge 与 steer hook 分立）；旧 Bridge 缺字段 = nil，按不支持处理。
    public var nativeSteer: Bool?
    /// 原生直达立即发送（mode=send_now，可能另起一轮）：与 nativeSteer 分立；缺字段 = 隐藏，false = 灰显，true = 可选。
    public var nativeSendNow: Bool?
    public init(steer: Bool, queueDeadline: Bool? = nil, nativeSteer: Bool? = nil, nativeSendNow: Bool? = nil) {
        self.steer = steer; self.queueDeadline = queueDeadline; self.nativeSteer = nativeSteer; self.nativeSendNow = nativeSendNow
    }
}

/// 立即插入是否可能可用。`unknown` 只表示旧 Bridge 没有声明，不能当作「不支持」。
public enum SteerAvailability: Sendable, Equatable {
    case unknown, available, unavailable
}

/// 发送的时机：排队到本轮结束，或立即插入当前回合（需要 Bridge 声明支持）。
public enum SendMode: String, Sendable, Equatable {
    case queue, steer
    case sendNow = "send_now"
}

/// 排队消息操作与发送的固定错误（Bridge 的错误码 → 这里的枚举；未知码保留 HTTP 状态）。
public enum MessageActionError: Error, Sendable, Equatable {
    case steerUnavailable(reason: SteerUnavailableReason?)
    case notWithdrawable(state: String?)
    case notPromotable
    case conflict(state: String?)
    case devicePaused
    case readOnly
    case notFound
    case invalidResponse
    case http(status: Int)
}

extension MessageActionError {
    /// 服务端明确拒绝且没有写入（可以恢复草稿）；无效回复与未知状态码不算，结果未知时不冒称零写入。
    public var isDefinitiveRefusal: Bool {
        switch self {
        case .steerUnavailable, .devicePaused, .readOnly, .notFound, .conflict, .notWithdrawable, .notPromotable: true
        case let .http(status): [400, 401, 403, 404, 409, 422].contains(status)
        case .invalidResponse: false
        }
    }
}

/// 立即插入被拒的原因（Bridge 的 steer_unavailable.reason 固定枚举；未知值视为未声明，只显示中性文案，不回显服务端字符串）。
public enum SteerUnavailableReason: String, Sendable, Equatable, CaseIterable {
    case disabled, noTurn = "no_turn", notHook = "not_hook", hookTarget = "hook_target", unsupportedEngine = "unsupported_engine"
    case notWorking = "not_working", noSequence = "no_sequence", notObserved = "not_observed", noIdentity = "no_identity"
    case identityChanged = "identity_changed", revisionChanged = "revision_changed", notRegistered = "not_registered"
    case notDirect = "not_direct", ownerOnly = "owner_only", targetUnavailable = "target_unavailable", identityConflict = "identity_conflict"
    case memberTarget = "member_target", deviceUnavailable = "device_unavailable", devicePaused = "device_paused"
    case readOnly = "read_only", rejectedReplay = "rejected_replay"
}

public struct PromoteResult: Sendable, Equatable {
    public var eventKey: String
    public var state: String
}

public struct WithdrawResult: Sendable, Equatable {
    public var eventKey: String
}

/// 请求体：可选字段缺省时不出现在 JSON 里，旧的 `{clientMsgId, text}` 保持不变。
struct SendMessageBody: Encodable, Sendable {
    var clientMsgId: String
    var text: String
    var mode: String?
    var queueTTLSeconds: Int? = nil
    var responseLanguage: String? = nil
}

public enum MessageActions {
    /// 非 2xx：只认固定码（小写字母 / 下划线，≤64 字符）；其余保留 HTTP 状态。
    public static func error(status: Int, data: Data) -> MessageActionError {
        struct Body: Decodable { let error: String?; let state: String?; let reason: String? }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let code = body?.error.flatMap(safeToken)
        let state = body?.state.flatMap(safeToken)
        switch (status, code) {
        case (403, "read_only"): return .readOnly
        case (404, "not_found"): return .notFound
        case (409, "steer_unavailable"): return .steerUnavailable(reason: SteerUnavailableReason(rawValue: body?.reason ?? ""))
        case (409, "device_paused"): return .devicePaused
        case (409, "not_promotable"): return .notPromotable
        case (409, "not_withdrawable"): return .notWithdrawable(state: state)
        case (409, "conflict"): return .conflict(state: state)
        default: return .http(status: status)
        }
    }

    /// 严格校验成功响应：键集合必须恰好等于约定的键，值必须与请求一致。
    /// 成功响应的 mode 必须与请求严格一致；不一致按无效响应处理（不信任服务端换了意图）。
    public static func decodePromote(eventKey: String, mode: SendMode = .steer, status: Int, data: Data) throws -> PromoteResult {
        guard (200..<300).contains(status) else { throw error(status: status, data: data) }
        let object = try exactObject(data, keys: ["eventKey", "mode", "state"])
        guard object["eventKey"] as? String == eventKey, object["mode"] as? String == mode.rawValue,
              let state = object["state"] as? String, state == "queued" else { throw MessageActionError.invalidResponse }
        return PromoteResult(eventKey: eventKey, state: state)
    }

    public static func decodeWithdraw(eventKey: String, status: Int, data: Data) throws -> WithdrawResult {
        guard (200..<300).contains(status) else { throw error(status: status, data: data) }
        let object = try exactObject(data, keys: ["withdrawn", "eventKey"])
        guard object["withdrawn"] as? Bool == true, object["eventKey"] as? String == eventKey else {
            throw MessageActionError.invalidResponse
        }
        return WithdrawResult(eventKey: eventKey)
    }

    public static func decodeSend(status: Int, data: Data) throws -> MessageReceipt {
        guard (200..<300).contains(status) else { throw error(status: status, data: data) }
        let object = try exactObject(data, keys: ["received", "eventKey"])
        guard object["received"] as? Bool == true, object["eventKey"] as? String != nil else {
            throw MessageActionError.invalidResponse
        }
        return try JSONDecoder().decode(MessageReceipt.self, from: data)
    }

    static func exactObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard let any = try? JSONSerialization.jsonObject(with: data), let object = any as? [String: Any],
              Set(object.keys) == keys else { throw MessageActionError.invalidResponse }
        return object
    }

    static func safeToken(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 64, value.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else { return nil }
        return value
    }
}

/// 排队与发送的文案集中在这里（界面只取文字，不自己拼）。「排队」与「补充排队」必须区分；
/// 「已并入当前回合」只表示被收到并入，不说明 agent 已采纳。
public enum SendTimingCopy {
    public static var queuedAfterTurn: String { KitL10n.string("排队中 · 本轮结束后发送") }
    public static var queuedUse: String { KitL10n.string("补充排队中 · 将并入当前回合") }
    /// 原生直达插话的排队：Bridge 只承诺写入工作中终端，并入与否要等权威快照，不能说“将并入”。
    public static var queuedNative: String { KitL10n.string("补充排队中 · 等待写入工作中终端，未验证") }
    /// 并入当前回合的文字（与 OutgoingStatus 的 merged 共用 CommandCopy）。计算属性：语言每次取值。
    public static var steerMerged: String { CommandCopy.text(.merged) }
    public static var steerNoTurn: String { KitL10n.string("没有运行中的回合，未发出") }
    public static var steerDisabled: String { KitL10n.string("补充功能未开启") }
    public static var steerUnavailable: String { KitL10n.string("当前不能立即插入：没有运行中的回合，或补充功能未开启") }
    public static var steerNotHook: String { KitL10n.string("这个目标不是 Claude Code hook 模式，不能立即插入") }
    public static var steerHookTarget: String { KitL10n.string("此目标使用 hook 模式，不能按原生直达立即插入") }
    /// 直达（派给 <agent>）只在 Bridge 声明 nativeSteer 时可立即插入；缺省或旧 Bridge 显示这句。
    /// 短文案：直达禁用项的标题要在常规菜单宽度内完整显示（17pt 下 ≤320pt）。
    public static var directNoSteer: String { KitL10n.string("直达暂不支持") }
    /// 立即发送的完整说法（独立提示用）；菜单短标题仍用 directNoSteer。
    public static var directSendNowUnavailable: String { KitL10n.string("直达立即发送暂不可用") }
    public static var sendNowLabel: String { KitL10n.string("立即发送（可能另起一轮）") }
    public static var sendNowNotDirect: String { KitL10n.string("这条消息不是直达，不能立即发送") }
    /// 独立提示（promote、发送拒绝）用的完整说法；菜单标题仍用 directNoSteer，避免超出宽度。
    public static var directSteerUnavailable: String { KitL10n.string("直达立即插入暂不可用") }
    /// 直达的目标（agent 名）与发起时不一致（改名、换目标）：零请求，消息没有发出。
    public static var directTargetChanged: String { KitL10n.string("直达目标已变化，消息没有发出") }
    public static var steerIdentityChanged: String { KitL10n.string("目标身份已变化，请重新确认后再发") }
    public static var steerNotObserved: String { KitL10n.string("尚未确认 agent 的回合状态，未发出") }
    public static var steerTargetUnavailable: String { KitL10n.string("目标或设备暂不可用，未发出") }
    public static var steerNotWorking: String { KitL10n.string("目标当前不在工作中，未发出") }
    public static var steerNotDirect: String { KitL10n.string("这条消息不是直达，不能立即插入") }
    public static var steerOwnerOnly: String { KitL10n.string("只有 Owner 可以立即插入") }
    public static var steerUnsupportedEngine: String { KitL10n.string("这个 agent 暂不支持立即插入") }
    public static var steerMemberTarget: String { KitL10n.string("成员目标不支持立即插入") }
    /// 同一消息重放时带了不同发送方式：原消息未被改动，本次变更不生效。不说“未发出”（原消息可能已发出）。
    public static var sendModeConflict: String { KitL10n.string("同一消息已有不同发送方式，本次变更未被接受；请查看原消息状态") }
    public static var steerGenericUnavailable: String { KitL10n.string("立即插入暂不可用，未发出") }

    /// 排队消息的状态文字：排队（本轮结束后发送）与补充排队（已改为立即插入、等待并入）必须区分。
    public static func commandStatus(state: String, reason: String?, lane: String?, direct: Bool = false, queueDeadlineT: Int? = nil,
                                     phase: String? = nil, stop: StopDisposition? = nil, locale: Locale = .autoupdatingCurrent) -> String {
        if reason == "queue_expired" { return CommandCopy.text(.queueExpired, locale: locale) }
        if reason == "queue_expired_uncertain" { return CommandCopy.text(.queueExpiredUncertain, locale: locale) }
        if reason == "withdrawn" { return CommandCopy.text(.withdrawn, locale: locale) }
        if reason == "merged" { return CommandCopy.text(.merged, locale: locale) }
        if reason == "native_delivered" { return OutgoingStatus.label(.nativeDelivered, locale: locale) }
        if reason == "native_send_now_requested" { return OutgoingStatus.label(.nativeSendRequested, locale: locale) }
        if reason == "native_send_now_skipped" { return OutgoingStatus.label(.nativeSendSkipped, locale: locale) }
        if state == CommandState.paused.rawValue {
            // 暂停不是“被拒绝”：有未派发证明才写“未发出”，其余（含缺键）保守为可能已执行。
            guard stop == .notDispatched else { return OutgoingStatus.label(.stoppedUncertain, locale: locale) }
            return OutgoingStatus.label(lane == "use" && direct ? .nativePaused : .stopped, locale: locale)
        }
        if state == CommandState.queued.rawValue {
            let label = lane == "use" ? (direct ? queuedNative : queuedUse) : queuedAfterTurn
            guard let queueDeadlineT else { return label }
            return KitL10n.format("%@ · %@ 前开始，否则不发", label, deadlineDate(queueDeadlineT))
        }
        if state == CommandState.started.rawValue {
            switch phase {
            case "dispatch": return OutgoingStatus.label(.dispatching, locale: locale)
            case "awaiting": return OutgoingStatus.label(.awaiting, locale: locale)
            case "running": return OutgoingStatus.label(.processing, locale: locale)
            default: return OutgoingStatus.label(.delivered, locale: locale)
            }
        }
        return ProgressState(rawValue: state)?.label ?? state
    }

    /// 排队期限的日期时刻（“月日 时分”，用户时区）。期限与排队原因分开显示，缺期限不造日期。
    static func deadlineDate(_ ms: Int) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(KitL10n.displayStyle(Date.FormatStyle().month().day().hour().minute()))
    }
    /// 期限单行：只用于排队中（queued）且服务端给出了 queueDeadlineT。
    public static func deadlineText(_ ms: Int) -> String { KitL10n.format("%@ 前开始，否则不发", deadlineDate(ms)) }

    /// 指令行的状态文字（带阶段与暂停分类）：与 OutgoingStatus 同一语义，两端指令行、卡与记录来源行共用。
    public static func commandStatus(_ c: ApiCommand, locale: Locale = .autoupdatingCurrent) -> String {
        commandStatus(state: c.state, reason: c.reason, lane: c.lane, direct: c.directAgent != nil, queueDeadlineT: c.queueDeadlineT,
                      phase: c.queue?.phase, stop: c.stopDisposition, locale: locale)
    }

    /// 列表里一条消息的状态文字：撤回的行（state=rejected + reason=withdrawn）显示「已撤回，未发出」，而不是「被拒绝」。
    public static func statusText(state: String, reason: String?, locale: Locale = .autoupdatingCurrent) -> String {
        if reason == "queue_expired" { return CommandCopy.text(.queueExpired, locale: locale) }
        if reason == "queue_expired_uncertain" { return CommandCopy.text(.queueExpiredUncertain, locale: locale) }
        if reason == "withdrawn" { return CommandCopy.text(.withdrawn, locale: locale) }
        if reason == "merged" { return CommandCopy.text(.merged, locale: locale) }
        if reason == "native_delivered" { return OutgoingStatus.label(.nativeDelivered, locale: locale) }
        if reason == "native_send_now_requested" { return OutgoingStatus.label(.nativeSendRequested, locale: locale) }
        if reason == "native_send_now_skipped" { return OutgoingStatus.label(.nativeSendSkipped, locale: locale) }
        return ProgressState(rawValue: state)?.label ?? state
    }
    public static var withdrawn: String { CommandCopy.text(.withdrawn) }
    public static var notWithdrawable: String { KitL10n.string("这条消息已开始处理，无法撤回") }
    public static var notPromotable: String { KitL10n.string("这条补充不能改为立即插入") }
    public static var readOnly: String { KitL10n.string("此设备为只读，不能发送或撤回") }
    public static var devicePaused: String { KitL10n.string("设备已暂停接收新消息") }
    public static var invalidResponse: String { KitL10n.string("Bridge 的回复不认识，请升级后重试") }

    /// 冲突：带实际状态（投影值，如 started / finished），不能只说「失败」。
    public static func conflict(state: String?) -> String {
        guard let state, let known = ProgressState(rawValue: state) else { return KitL10n.string("状态已变化，请重新读取") }
        return KitL10n.format("状态已变化：%@", known.label)
    }

    /// 立即发送的拒绝文案：按操作上下文区分（不说「插入」）；未列出的原因沿用插入的固定文案。
    static func sendNowText(for reason: SteerUnavailableReason?) -> String? {
        switch reason {
        case .notDirect: sendNowNotDirect
        case .hookTarget: KitL10n.string("此目标使用 hook 模式，不能按原生直达立即发送")
        case .unsupportedEngine: KitL10n.string("这个 agent 暂不支持立即发送")
        case .ownerOnly: KitL10n.string("只有 Owner 可以立即发送")
        case .notHook: KitL10n.string("这个目标不是 Claude Code hook 模式，不能立即发送")
        case .memberTarget: KitL10n.string("成员目标不支持立即发送")
        case .rejectedReplay: sendModeConflict
        case nil: KitL10n.string("立即发送暂不可用，未发出")
        default: nil
        }
    }

    public static func text(for error: MessageActionError, sendNow: Bool = false) -> String {
        if sendNow, case let .steerUnavailable(reason) = error, let text = sendNowText(for: reason) { return text }
        return insertText(for: error)
    }

    private static func insertText(for error: MessageActionError) -> String {
        switch error {
        case let .steerUnavailable(reason):
            switch reason {
            case .noTurn: steerNoTurn
            case .disabled: steerDisabled
            case .notHook: steerNotHook
            case .devicePaused: devicePaused
            case .readOnly: readOnly
            case .notWorking: steerNotWorking
            case .ownerOnly: steerOwnerOnly
            case .notDirect: steerNotDirect
            case .unsupportedEngine: steerUnsupportedEngine
            case .memberTarget: steerMemberTarget
            case .rejectedReplay: sendModeConflict
            case .noSequence, .notObserved: steerNotObserved
            case .noIdentity, .identityChanged, .revisionChanged, .notRegistered, .identityConflict: steerIdentityChanged
            case .targetUnavailable, .deviceUnavailable: steerTargetUnavailable
            case .hookTarget: steerHookTarget
            case nil: steerGenericUnavailable
            }
        case .notWithdrawable: notWithdrawable
        case .notPromotable: notPromotable
        case let .conflict(state): conflict(state: state)
        case .devicePaused: devicePaused
        case .readOnly: readOnly
        case .notFound: KitL10n.string("这条消息已不存在")
        case .invalidResponse: invalidResponse
        case let .http(status): KitL10n.format("请求失败（%lld）", status)
        }
    }
}
