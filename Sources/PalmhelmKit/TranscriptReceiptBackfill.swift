import Foundation

/// 回执后补关联（A2-000 §1/§3）：已加载的用户项在首次读取时没拿到 receipt，Bridge 证据完整后经首页条件读取补发。
/// 一条补丁：只更新端侧已加载的 user 项；receipt 形状与页内 receipt 相同。
public struct TranscriptReceiptUpdate: Codable, Sendable, Equatable {
    public var itemId: String
    public var receipt: TranscriptReceipt
    public init(itemId: String, receipt: TranscriptReceipt) { self.itemId = itemId; self.receipt = receipt }
}

/// 首页条件读取携带的后补声明：当前原生会话代次 + 仍待关联的本机发送 eventKey（≤20）。
/// 规范化（去重、字节序排序、上限、长度）全在这里，两端不手写 query。形状相同则请求相同，ETag 可复用。
public struct TranscriptReceiptRequest: Sendable, Equatable, Hashable {
    public static let maxKeys = 20
    public static let maxFieldBytes = 256
    public static let maxQueryBytes = 16 * 1024

    public let sessionEpoch: String
    /// 去重并按 UTF-8 字节序排序。
    public let eventKeys: [String]

    /// 无效的 key（空、含控制字符、超 256 字节）被丢弃；超过 20 个时保留传入顺序里最后（最近）的 20 个；规范化后没有 key 或 epoch 无效返回 nil。
    public init?(sessionEpoch: String, eventKeys: [String]) {
        guard Self.valid(sessionEpoch) else { return nil }
        var seen = Set<String>(), kept: [String] = []
        for k in eventKeys.reversed() where Self.valid(k) && seen.insert(k).inserted { kept.append(k) } // 从最近的一端取
        kept = Array(kept.prefix(Self.maxKeys))
        guard !kept.isEmpty else { return nil }
        kept.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        // percent-encoded query 总长上限：超出时丢掉字节序靠后的 key（极端长 key 才会发生）。
        func size(_ ks: [String]) -> Int { Self.encodedBytes("receiptEpoch", sessionEpoch) + ks.reduce(0) { $0 + Self.encodedBytes("receiptEventKey", $1) } }
        while size(kept) > Self.maxQueryBytes, !kept.isEmpty { kept.removeLast() }
        guard !kept.isEmpty else { return nil }
        self.sessionEpoch = sessionEpoch; self.eventKeys = kept
    }

    public var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "receiptEpoch", value: sessionEpoch)] + eventKeys.map { URLQueryItem(name: "receiptEventKey", value: $0) }
    }

    /// 由发送记录选键：同一原生代次内、尚未关联、带 eventKey 的本机发送。
    /// `preferred` 是端侧实际仍保留显示的原生回显的 eventKey（由各端现有的原生回显分类给出，Kit 不复制那套判断）：它们优先占名额，
    /// 其余普通发送按发送顺序补满 20 个；否则一串已终态的普通发送会把仍在显示的原生回显挤出声明、使它永远等不到补丁。
    /// `supplementKeys` 是端侧当前最新窗里服务端补行（command 补行）的 key，按受理序升序：它们没有本机 Sent、不带原 epoch，
    /// 这里不猜原 epoch——声明只表达“我正在读哪一代”，是否属于该代由 Bridge 用 command 的原生身份核验。名额排序：普通发送 → 优先回显 → 补行（最近的最靠后，总上限 20 时最后保留）。
    /// 没有 eventKey、其它会话（代次不同或未绑定）、已关联的都不进来；不读正文。
    public static func select(epoch: String?, linked: Set<String>, sent: [(eventKey: String?, sessionEpoch: String?)], preferred: Set<String> = [], supplementKeys: [String] = []) -> TranscriptReceiptRequest? {
        guard let epoch else { return nil }
        let keys = sent.compactMap { s -> String? in
            guard let k = s.eventKey, s.sessionEpoch == epoch, !linked.contains(k) else { return nil }
            return k
        }
        // init 保留传入顺序里最后的 20 个：优先项放在最后。
        let supplement = supplementKeys.filter { !linked.contains($0) }
        return TranscriptReceiptRequest(sessionEpoch: epoch, eventKeys: keys.filter { !preferred.contains($0) } + keys.filter { preferred.contains($0) } + supplement)
    }

    /// 当前最新窗尾部（ThreadTail.commandRows：期限行 + 补行，已排除已关联 / 他代次 / 回显覆盖）里可请求后补的 key：本目标、origin=api、未关联，按受理序升序。
    /// 只读调用时已算出的尾部行，不另写 queued / unknown / paused 分类。
    public static func supplementKeys(commandRows: [ApiCommand], targetId: String, linked: Set<String>) -> [String] {
        commandRows.filter { $0.targetId == targetId && $0.origin == "api" && !linked.contains($0.key) }
            .sorted { $0.inboxSeq < $1.inboxSeq }.map(\.key)
    }

    private static func valid(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= maxFieldBytes && !s.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
    private static func encodedBytes(_ name: String, _ value: String) -> Int {
        name.utf8.count + 2 + (value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value).utf8.count
    }
}

extension TranscriptThread {
    /// 本次响应里可采纳的补丁（只读分类，不改状态）：快照未变、线程可读且不在换页中、响应代次 = 请求代次 = 线程代次；
    /// 数组 ≤20 且 itemId 唯一，否则整组不采纳；每项：eventKey 属于本次声明、origin=api、目标是已加载的 user 项；
    /// 已有不同 commandKey / eventKey 的项保守不覆盖（冲突）。未知 itemId 不创建行也不记 eventKey。同值不算变化。
    /// 分类基于调用时的已加载内容：applyLatest 在正文刷新之前取这份结论，之后只恢复其中已批准的项。
    func approvedReceiptUpdates(_ page: TranscriptPage, request: TranscriptReceiptRequest?, snapshot requested: Int?) -> [TranscriptReceiptUpdate] {
        guard let request, let updates = page.receiptUpdates, !updates.isEmpty, updates.count <= TranscriptReceiptRequest.maxKeys,
              Set(updates.map(\.itemId)).count == updates.count,
              requested.map({ $0 == snapshot }) ?? true,
              page.isAvailable, status == .ok, !needsReplace,
              page.sessionEpoch == request.sessionEpoch, sessionEpoch == request.sessionEpoch else { return [] }
        let allowed = Set(request.eventKeys)
        let byId = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return updates.filter { u in
            guard let key = u.receipt.eventKey, allowed.contains(key), u.receipt.origin == "api",
                  let i = byId[u.itemId], items[i].role == "user" else { return false }
            if let old = items[i].receipt { return old.commandKey == u.receipt.commandKey && old.eventKey == key && old != u.receipt }
            return true
        }
    }

    /// 把已批准的补丁写进已加载项；`onlyIfEmpty` 用于正文刷新之后恢复（只补被页覆盖成空的项，不动页自带的 receipt）。
    mutating func writeReceipts(_ approved: [TranscriptReceiptUpdate], onlyIfEmpty: Bool = false) -> Int {
        var next = items, changed = 0
        for u in approved {
            guard let i = next.firstIndex(where: { $0.id == u.itemId && $0.role == "user" }) else { continue }
            if onlyIfEmpty { guard next[i].receipt == nil else { continue } } else if next[i].receipt == u.receipt { continue }
            next[i].receipt = u.receipt; changed += 1
        }
        if changed > 0 { items = next }
        return changed
    }

    /// 采纳后补关联（只改已加载项的 receipt 并累积 eventKey）。必须在最新页的原门禁之后调用，且早于页正文的采纳：
    /// 正文因 hasNewer / 定位视图被拒时，合法补丁仍可更新已加载项，窗口与游标不动。返回实际改变的项数（同值为 0，不写入）。
    @discardableResult
    public mutating func applyReceiptUpdates(_ page: TranscriptPage, request: TranscriptReceiptRequest?, snapshot requested: Int? = nil) -> Int {
        writeReceipts(approvedReceiptUpdates(page, request: request, snapshot: requested))
    }

    /// 更早页里已加载的项：Bridge 现已挂上（或更新）receipt 时刷新内存里的元数据；冲突的 commandKey 不覆盖。
    mutating func refreshKnownReceipts(from pageItems: [TranscriptItem]) {
        var index: [String: Int]?
        var next: [TranscriptItem]?
        for p in pageItems {
            guard let r = p.receipt else { continue }
            if index == nil { index = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }) }
            guard let i = index?[p.id], items[i].role == "user" else { continue }
            let cur = (next ?? items)[i].receipt
            if let cur { guard cur.commandKey == r.commandKey, cur.eventKey == nil || cur.eventKey == r.eventKey, cur != r else { continue } }
            if next == nil { next = items }
            next?[i].receipt = r
        }
        if let next { items = next }
    }
}
