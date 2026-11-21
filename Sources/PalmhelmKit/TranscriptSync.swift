import Foundation

// #88 S2：激活会话同步的纯规则（两端共用）：条件读取的应答解析、激活代次门禁（A→B→A 的迟到结果丢弃）、
// 读取准入与采纳（所有读取入口共用）、长消息折叠、按条续读的展开状态（单飞、实例代次、应答身份校验）。
// 网络与界面由各端负责。

/// 长消息折叠的行状态（设计 12 第 3 节）：两端共用。折叠时只显示前几行；展开后可按段继续加载后文。
public struct TranscriptRowFolding {
    public var folded: Bool
    public var expansion: TranscriptExpansion?
    public var expand: () -> Void
    public var collapse: () -> Void
    public var loadMore: () -> Void
    /// 展开要进阅读页（iOS，超过一页或被截断）；false 时就地展开。Mac 一直就地展开，保持默认。
    public var opensReader: Bool = false

    public init(folded: Bool, expansion: TranscriptExpansion?, expand: @escaping () -> Void, collapse: @escaping () -> Void, loadMore: @escaping () -> Void) {
        self.folded = folded; self.expansion = expansion; self.expand = expand; self.collapse = collapse; self.loadMore = loadMore
    }
}

/// 按条续读一段的应答（`GET /v1/targets/{id}/transcript/items/{itemId}`）。不可用时 status 不是 "ok"，其余字段可能缺失。
public struct TranscriptItemSegment: Codable, Sendable, Equatable {
    public var status: String
    public var sessionEpoch: String?
    public var itemId: String?
    public var text: String?
    public var hasMore: Bool?
    /// 还有后续时的下一段令牌；只在 hasMore 为真时给出。
    public var continuation: String?
    public var reason: String?
    /// 本段 text 内的生成原子范围（相对本段 text 的 UTF-16）。
    public var displaySpans: LossyDisplaySpans?

    public init(status: String, sessionEpoch: String? = nil, itemId: String? = nil, text: String? = nil, hasMore: Bool? = nil, continuation: String? = nil, reason: String? = nil, displaySpans: LossyDisplaySpans? = nil) {
        self.status = status; self.sessionEpoch = sessionEpoch; self.itemId = itemId; self.text = text; self.hasMore = hasMore; self.continuation = continuation; self.reason = reason; self.displaySpans = displaySpans
    }

    public var isAvailable: Bool { status == "ok" && text != nil }
}

/// 条件读取的结果：新页（带 ETag）或“未变”（304，无正文）。304 只能对已采纳的同一页使用。
public enum TranscriptFetch: Sendable, Equatable {
    case page(TranscriptPage, etag: String?)
    case notModified

    /// 按 HTTP 状态与正文解析。304 为未变；2xx 解码整页；其余状态是错误（含 410，由调用方按续读规则处理）。
    public static func parse(status: Int, etag: String?, data: Data) throws -> TranscriptFetch {
        if status == 304 { return .notModified }
        guard (200..<300).contains(status) else { throw BridgeError.http(status: status) }
        do {
            return .page(try JSONDecoder().decode(TranscriptPage.self, from: data), etag: etag)
        } catch {
            throw BridgeError.decoding
        }
    }
}

/// 激活代次门禁：每次激活（包括 A→B→A、失焦后恢复）都得到新的令牌；只有发起时的令牌仍是当前令牌的结果才被采纳。
public struct TranscriptActivation: Sendable, Equatable {
    public struct Token: Sendable, Equatable {
        public let generation: Int
        public let targetId: String
    }

    public private(set) var current: Token?
    private var generation = 0

    public init() {}

    /// 激活（或切换到）某个目标：返回新令牌，之前的令牌全部失效。
    public mutating func activate(_ targetId: String) -> Token {
        generation += 1
        let token = Token(generation: generation, targetId: targetId)
        current = token
        return token
    }

    /// 停止（失焦、进入后台、离开线程）：当前令牌失效，之后的迟到结果一律丢弃。
    public mutating func deactivate() {
        generation += 1
        current = nil
    }

    public func accepts(_ token: Token) -> Bool { current == token }
}

/// 线程里“骨架是否盖住内容”的显示规则（iOS / Mac 共用）。纯函数：只收事实，不持有状态、不发网，也不授权任何读取。
/// 视觉上可保留“最近确认过的线程”的内容（失焦 / 重新聚焦后新激活尚未确认）与能否发网/采纳是两件事；后者仍只由 TranscriptReadGate 决定。
public enum TranscriptPresentation {
    /// settled：当前激活存在、属于这个目标、且已被确认（按完整 Token 相等，不只比 targetId）。
    public static func isSettled(targetId: String, current: TranscriptActivation.Token?, confirmed: TranscriptActivation.Token?) -> Bool {
        guard let current, current.targetId == targetId else { return false }
        return confirmed == current
    }

    /// 已连接、尚未 settled，且“最近一次确认的就是这个线程并且已有 .ok 内容”不成立时显示骨架；断线一律不显示（保留原断线说明）。
    /// confirmed 只在确认时被替换、不随停用清空，所以它的 targetId 就是最近一次确认的线程；A→B→A 回到 A 时最近确认是 B，仍先骨架。
    public static func showsSkeleton(targetId: String, connected: Bool, current: TranscriptActivation.Token?, confirmed: TranscriptActivation.Token?, status: TranscriptThread.Status?) -> Bool {
        connected && !isSettled(targetId: targetId, current: current, confirmed: confirmed) && !(confirmed?.targetId == targetId && status == .ok)
    }
}

/// 所有内容读取（最新页、更早页、条件读取）共用的准入与采纳规则（#88 S4 修复 R1、R2）。
/// 只在前台可见的当前线程发起内容读取；后台、失焦或非当前线程只标记 dirty，前台再补拉一次。
/// 应答只在连接未换、激活仍是发起时的、线程快照未失效时采纳；旧连接的结果不写入新连接的状态。
public enum TranscriptReadGate {
    public struct Ticket: Sendable, Equatable {
        public let connection: Int
        public let activation: TranscriptActivation.Token
        public let targetId: String
        public let snapshot: Int
        /// 发起时可用的 If-None-Match（只在线程仍持有这一页、且请求形状相同时给出）。
        public let etag: String?
        /// 发起时的后补声明（规范化后）；采纳时据此核对，不取采纳时刻的新状态。
        public let receipt: TranscriptReceiptRequest?
    }

    public enum Decision: Sendable, Equatable {
        case start(Ticket)
        /// 当前不能读（后台、非当前线程、同线程已有最新页在途、同设备同目标在途已满）：调用方标记 dirty。
        case deferred
    }

    public static func decide(targetId: String, connection: Int, activation: TranscriptActivation, thread: TranscriptThread?, receipt: TranscriptReceiptRequest? = nil) -> Decision {
        guard let current = activation.current, current.targetId == targetId else { return .deferred }
        if let thread, thread.latestInFlight || !thread.canStartRequest { return .deferred }
        return .start(Ticket(connection: connection, activation: current, targetId: targetId, snapshot: thread?.snapshot ?? 0, etag: thread?.validator(for: receipt), receipt: receipt))
    }

    /// 应答能否采纳：连接未换、激活仍是发起时的、线程快照未失效。
    public static func accepts(_ ticket: Ticket, connection: Int, activation: TranscriptActivation, snapshot: Int?) -> Bool {
        ticket.connection == connection && activation.accepts(ticket.activation) && snapshot == ticket.snapshot
    }
}

/// 不可用应答的分类：临时原因（未确认身份、预算、读取失败、代次变化中）保留已核验内容并标记陈旧；
/// 其余原因（包括没有原因）按会话已变处理，清空旧内容（与此前行为一致）。
public enum TranscriptUnavailability {
    static let transient: Set<String> = [
        "identity_unverified", "budget_exceeded", "io_error", "file_changed", "locate_budget_exceeded", "agent_absent",
    ]

    public static func clearsContent(reason: String?) -> Bool {
        guard let reason else { return true }
        return !transient.contains(reason)
    }
}

/// 激活会话的读取节拍（约 1 秒，设计 08 第 3 节）：同一时刻至多一个在途请求；请求慢时跳过错过的节拍（不补偿）；失败按 2 的幂次退避，上限 8 秒。
public struct TranscriptReadCadence: Sendable, Equatable {
    public static let interval: TimeInterval = 1.0
    public static let maxBackoff: TimeInterval = 8.0

    public private(set) var inFlight = false
    public private(set) var nextAllowedAt: Date?
    public private(set) var failures = 0

    public init() {}

    /// 节拍到了且没有在途请求时开始一次读取，返回 true。
    public mutating func begin(now: Date) -> Bool {
        guard !inFlight else { return false }
        if let nextAllowedAt, now < nextAllowedAt { return false }
        inFlight = true
        return true
    }

    /// 读取结束：成功回到常规节拍；失败按退避延后下一次。
    public mutating func finish(now: Date, success: Bool) {
        inFlight = false
        if success {
            failures = 0
            nextAllowedAt = now.addingTimeInterval(Self.interval)
        } else {
            failures += 1
            let backoff = min(Self.interval * pow(2, Double(min(failures, 6))), Self.maxBackoff)
            nextAllowedAt = now.addingTimeInterval(backoff)
        }
    }

    /// 停止（失焦、后台、离开线程）：清掉在途标记与节拍。迟到的结果由 TranscriptActivation / TranscriptReadGate 丢弃。
    public mutating func cancel() {
        inFlight = false
        nextAllowedAt = nil
        failures = 0
    }
}

/// 长消息折叠（设计 12 第 3 节）：已完成的助手回复超过 8 行或 400 字时折叠；用户消息与正在写的回复不折叠。
/// 折叠状态只在下次进入会话时重置，不随滚出屏幕而变化（简化裁决，见 design/12）。
public enum TranscriptFolding {
    public static let foldLines = 8
    public static let foldCharacters = 400

    /// 是否默认折叠。isLatestStreaming 为真（最新且正在写入）时不折叠。
    /// `includeUser`（显式 opt-in，D1）：用户消息按同一预算折叠；默认 false，助手规则与 Mac 的行为不变。
    public static func isFoldable(_ item: TranscriptItem, isLatestStreaming: Bool, includeUser: Bool = false) -> Bool {
        guard item.role == "assistant" || (includeUser && item.role == "user"), !isLatestStreaming else { return false }
        return exceedsFoldBudget(item.text)
    }

    /// 超过 8 行或 400 字。有界判断：最多看 401 个字符，再在这至多 400 字里数换行，不遍历整篇。
    /// 行按 "\n" 切分（"\r\n" 里的 "\n" 也算一个换行），与旧的 components(separatedBy:) 一致。
    static func exceedsFoldBudget(_ text: String) -> Bool {
        let limit = text.index(text.startIndex, offsetBy: foldCharacters + 1, limitedBy: text.endIndex)
        if limit != nil { return true }
        var newlines = 0
        for byte in text.utf8 where byte == 0x0A {
            newlines += 1
            if newlines >= foldLines { return true }
        }
        return false
    }

    /// 就地展开的上限：约一屏（用户反馈 1200 字一屏放不下）。
    public static let inlineCharacters = 600
    public static let inlineLines = 12

    /// 全文已在本地且不超过约一屏（字数、源行数）：展开在对话里就地进行，不进阅读页。
    /// 有界扫描：最多看 601 个字符，不调用分页解析。
    public static func expandsInline(_ item: TranscriptItem) -> Bool {
        guard !item.truncated else { return false }
        let text = item.text
        if text.index(text.startIndex, offsetBy: inlineCharacters + 1, limitedBy: text.endIndex) != nil { return false }
        var newlines = 0
        for byte in text.utf8 where byte == 0x0A {
            newlines += 1
            if newlines >= inlineLines { return false }
        }
        return true
    }

    /// 折叠时显示的前几行，且不超过 foldCharacters 字：无换行的长段落也要截住。
    /// 显示行数由视图的 lineLimit 收口（按换行后的显示行计）。
    public static func previewText(_ text: String) -> String {
        // 前 8 行 = 第 8 个 "\n" 之前的部分；再截到 400 字。只扫描至多 400 字，不拆整篇。
        let limit = text.index(text.startIndex, offsetBy: foldCharacters, limitedBy: text.endIndex) ?? text.endIndex
        var end = limit
        var newlines = 0
        let bytes = text.utf8
        var i = bytes.startIndex
        while i < limit {
            if bytes[i] == 0x0A {
                newlines += 1
                if newlines == foldLines { end = i; break }
            }
            bytes.formIndex(after: &i)
        }
        return String(text[..<end].prefix(foldCharacters))
    }

    /// 「约 N 字」：十位取整，少于 100 字时给出准确数字。
    public static func characterLabel(_ text: String) -> String {
        let n = text.count
        return n < 100 ? KitL10n.format("%lld 字", n) : KitL10n.format("约 %lld 字", (n + 5) / 10 * 10)
    }

    /// 服务端截断的条目只收到了前缀：字数明确写成“已加载”的范围，不暗示这是全文（D1）。
    public static func characterLabel(_ text: String, truncated: Bool) -> String {
        guard truncated else { return characterLabel(text) }
        let n = text.count
        return n < 100 ? KitL10n.format("已加载 %lld 字", n) : KitL10n.format("已加载约 %lld 字", (n + 5) / 10 * 10)
    }

}

/// 一条长回复的按段展开状态。
/// - 单飞：同一时刻只有一条续读在途（`beginLoad` 对在途或不可续读的条目返回 nil）。
/// - 代次：每个展开实例有自己的 `instance`；收起、重开、会话或版本变化都会替换实例，旧实例的应答无法回到新实例上。
/// - 身份：应答自身的 itemId、sessionEpoch 必须与本展开一致，并且是本次请求的应答（令牌一致）。
public struct TranscriptExpansion: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case appended
        case complete
        /// 应答不属于本展开（实例、令牌、条目或会话不符）：不改变状态。
        case stale
        /// 再追加会超过显示上限：不追加，保留令牌；之后不再加载。
        case limitReached
    }

    /// 本次请求的标识：实例与发出时的令牌。
    public struct Ticket: Sendable, Equatable {
        public let instance: UUID
        public let continuation: String
    }

    /// 已展开文本的上限（字节）：长回复不会无限进入内存。
    public static let maxBytes = 512 * 1024

    public let instance: UUID
    /// 创建顺序（内存超限时淘汰最旧的展开）。
    public let seq: Int
    public private(set) var itemId: String
    public private(set) var sessionEpoch: String
    /// 创建展开时条目的续读令牌：条目版本变化（令牌不同）时整条展开失效。
    public private(set) var origin: String?
    public private(set) var text: String
    /// 已展开文本里的生成原子范围（相对 text 的 UTF-16）：首段来自条目，续读段按追加位置平移后并入。
    public private(set) var spans: [DisplaySpan] = []
    /// 当前显示语言下的已展开文本（只替换 Bridge 标出的生成范围）。
    public var displayed: DisplayedText { BridgeDisplayText.render(text, spans: spans) }
    /// 下一段的令牌；nil 表示已到末尾（或本条不可续读）。
    public private(set) var continuation: String?
    public private(set) var inFlight = false
    /// 服务端对令牌回 reset（410）后置位：正文保留为已显示的部分，需要整条重新读取。
    public private(set) var needsRefetch = false
    /// 追加过一次上限后置位：之后不再加载，界面只显示已展开的部分。
    public private(set) var limitReached = false

    public init(itemId: String, sessionEpoch: String, text: String, continuation: String?, seq: Int = 0, displaySpans: LossyDisplaySpans? = nil) {
        self.spans = displaySpans?.spans ?? []
        self.instance = UUID(); self.seq = seq
        self.itemId = itemId; self.sessionEpoch = sessionEpoch; self.text = text; self.continuation = continuation; self.origin = continuation
    }

    public var isComplete: Bool { continuation == nil && !needsRefetch }
    public var canLoadMore: Bool { continuation != nil && !needsRefetch && !limitReached && !inFlight }
    /// 内存估算：展开正文的字节。
    public var bytes: Int { text.utf8.count }

    /// 条目是否仍是创建本展开时的版本（令牌未变）。版本变化后旧展开应被丢弃。
    public func belongs(to item: TranscriptItem) -> Bool { item.id == itemId && item.continuation == origin }

    /// 开始一次续读：在途或不可续读时返回 nil。
    public mutating func beginLoad() -> Ticket? {
        guard canLoadMore, let token = continuation else { return nil }
        inFlight = true
        return Ticket(instance: instance, continuation: token)
    }

    /// 应答到达：只有同一实例、同一令牌、且应答自身的条目与会话一致时才追加。
    public mutating func complete(_ ticket: Ticket, with segment: TranscriptItemSegment) -> Outcome {
        guard ticket.instance == instance, inFlight, ticket.continuation == continuation else { return .stale }
        inFlight = false
        guard segment.isAvailable, segment.itemId == itemId, segment.sessionEpoch == sessionEpoch, let piece = segment.text else { return .stale }
        guard text.utf8.count + piece.utf8.count <= Self.maxBytes else { limitReached = true; return .limitReached }
        let base = text.utf16.count
        spans += (segment.displaySpans?.spans ?? []).map { DisplaySpan(startUTF16: $0.startUTF16 + base, endUTF16: $0.endUTF16 + base, key: $0.key) }
        text += piece
        continuation = segment.hasMore == true ? segment.continuation : nil
        return continuation == nil ? .complete : .appended
    }

    /// 续读失败：同一实例与令牌才有效。410 标记需要整条重新读取；其它错误保留状态，之后可重试。
    public mutating func fail(_ ticket: Ticket, reset: Bool) {
        guard ticket.instance == instance, inFlight else { return }
        inFlight = false
        if reset { needsRefetch = true; continuation = nil }
    }
}
