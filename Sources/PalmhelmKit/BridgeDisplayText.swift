import Foundation

/// Bridge 在安全投影时标出的“生成原子”（链接/图片降级、隐藏占位、本地命令前缀等）。语义 key 固定，未知 key 的范围整条忽略。
public enum DisplayAtom: String, CaseIterable, Sendable {
    case link, image, hidden, path
    case localCommand = "local_command", localStdout = "local_stdout", localStderr = "local_stderr", empty
    /// final 回复的来源头（含换行，位于 Bridge 生成外层的最前）；回复正文不在范围内、逐字保留。
    case sourceTranscript = "source_transcript", sourceScreenUnverified = "source_screen_unverified"
    /// final 回复里 Bridge 生成的固定状态句与片段（契约 v1.1）：安全过滤的 head/tail 之间是规则名，原样保留。
    case finalNoText = "final_no_text", finalIdleNoCapture = "final_idle_no_capture"
    case finalFilteredHead = "final_filtered_head", finalFilteredTail = "final_filtered_tail"
    case finalGroupDone = "final_group_done", finalMemberRevoked = "final_member_revoked", finalMemberHead = "final_member_head"

    /// Bridge 写进 wire text 的中文原文，同时是 Kit catalog 的 key。范围内的原文必须逐字等于它，
    /// 否则说明范围与正文不同步（或用户字面写了同句），回退原文而不是替换。
    public var canonical: String {
        switch self {
        case .link: "（链接）"
        case .image: "（图片）"
        case .hidden: "（内容已隐藏）"
        case .path: "‹路径›"
        case .localCommand: "终端本地命令："
        case .localStdout: "终端本地输出"
        case .localStderr: "终端本地错误输出"
        case .empty: "（无内容）"
        case .sourceTranscript: "（会话记录）\n"
        case .sourceScreenUnverified: "（屏幕摘要，来源未验证）\n"
        case .finalNoText: "完成（无文字回复）"
        case .finalIdleNoCapture: "已回到空闲，但未能从屏幕截取回复，请到终端查看。"
        case .finalFilteredHead: "⚠️ **已完成，内容未自动回传**\n\n安全过滤命中：`"
        case .finalFilteredTail: "`。请到终端查看完整回复。"
        case .finalGroupDone: "✅ **已完成**\n\n群聊默认只发状态，回复内容未发到群里；请私聊查看。"
        case .finalMemberRevoked: "成员问答｜该次授权已撤销，回复未回传。"
        case .finalMemberHead: "成员问答｜只读模式由目标提供｜提问者 "
        }
    }
    /// 当前显示语言下的文字。
    public var shown: String {
        if canonical.hasSuffix("\n") { return KitL10n.string(String(canonical.dropLast())) + "\n" }
        return KitL10n.string(canonical)
    }
}

/// wire 上的 `displaySpans[i]`：相对该条 wire text 的 UTF-16 半开区间。
public struct DisplaySpan: Codable, Sendable, Equatable {
    public let startUTF16: Int
    public let endUTF16: Int
    public let key: String
    public init(startUTF16: Int, endUTF16: Int, key: String) { self.startUTF16 = startUTF16; self.endUTF16 = endUTF16; self.key = key }
}

/// `displaySpans` 的宽松解码：整个数组或其中任何一项畸形时只丢弃那一部分，绝不让整条记录/整页解码失败。
public struct LossyDisplaySpans: Codable, Sendable, Equatable {
    public let spans: [DisplaySpan]
    public init(_ spans: [DisplaySpan]) { self.spans = spans }
    public init(from decoder: Decoder) throws {
        struct Slot: Decodable { let span: DisplaySpan?; init(from d: Decoder) throws { span = try? DisplaySpan(from: d) } }
        let slots = (try? decoder.singleValueContainer().decode([Slot].self)) ?? []
        spans = slots.compactMap(\.span)
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(spans) }
}

/// 原文 ↔ 显示文的 UTF-16 偏移映射（搜索高亮、阅读页定位复用）。只有被替换的范围会改变偏移；落在原子内部的偏移按边缘吸附到原子两端。
public struct DisplayOffsetMap: Sendable, Equatable {
    public enum Edge: Sendable { case start, end }
    struct Piece: Sendable, Equatable { var raw: Range<Int>; var shown: Range<Int> }
    let pieces: [Piece]
    public static let identity = DisplayOffsetMap(pieces: [])

    public func shown(forRaw offset: Int, edge: Edge = .start) -> Int {
        var delta = 0
        for p in pieces {
            if offset >= p.raw.upperBound { delta += p.shown.count - p.raw.count; continue }
            if offset <= p.raw.lowerBound { break }
            return edge == .start ? p.shown.lowerBound : p.shown.upperBound
        }
        return offset + delta
    }
    /// 原文区间的某一端落在被替换的生成原子内部（既不是原子边界也不在原子外）：这样的区间无法无损映射。
    public func splitsAtom(rawRange r: Range<Int>) -> Bool {
        pieces.contains { p in
            (r.lowerBound > p.raw.lowerBound && r.lowerBound < p.raw.upperBound) || (r.upperBound > p.raw.lowerBound && r.upperBound < p.raw.upperBound)
        }
    }

    public func raw(forShown offset: Int, edge: Edge = .start) -> Int {
        var delta = 0
        for p in pieces {
            if offset >= p.shown.upperBound { delta += p.raw.count - p.shown.count; continue }
            if offset <= p.shown.lowerBound { break }
            return edge == .start ? p.raw.lowerBound : p.raw.upperBound
        }
        return offset + delta
    }
}

public struct DisplayedText: Sendable, Equatable {
    public let text: String
    public let map: DisplayOffsetMap
    public init(text: String, map: DisplayOffsetMap) { self.text = text; self.map = map }
}

public enum BridgeDisplayText {
    /// 取出合法范围：已知 key、有序、不重叠、在界内、范围内原文逐字等于该原子的中文原文。违规的单个范围被丢弃，其余不受影响。
    static func accepted(_ spans: [DisplaySpan]?, in units: [UInt16]) -> [(range: Range<Int>, atom: DisplayAtom)] {
        guard let spans, !spans.isEmpty else { return [] }
        var out: [(Range<Int>, DisplayAtom)] = []
        var last = 0
        for s in spans {
            guard let atom = DisplayAtom(rawValue: s.key), s.startUTF16 >= last, s.endUTF16 > s.startUTF16, s.endUTF16 <= units.count else { continue }
            guard Array(units[s.startUTF16..<s.endUTF16]) == Array(atom.canonical.utf16) else { continue }
            out.append((s.startUTF16..<s.endUTF16, atom)); last = s.endUTF16
        }
        return out
    }

    public static func render(_ raw: String, lossy: LossyDisplaySpans?) -> DisplayedText { render(raw, spans: lossy?.spans) }

    /// 只替换生成范围，字面替换（不重新解释 Markdown）。没有可接受范围时原样返回（同一字符串、恒等映射）。
    public static func render(_ raw: String, spans: [DisplaySpan]?) -> DisplayedText {
        let units = Array(raw.utf16)
        let ok = accepted(spans, in: units)
        guard !ok.isEmpty else { return DisplayedText(text: raw, map: .identity) }
        var out: [UInt16] = []; out.reserveCapacity(units.count)
        var pieces: [DisplayOffsetMap.Piece] = []
        var cursor = 0
        for (range, atom) in ok {
            out.append(contentsOf: units[cursor..<range.lowerBound])
            let replacement = Array(atom.shown.utf16)
            let from = out.count
            out.append(contentsOf: replacement)
            pieces.append(.init(raw: range, shown: from..<out.count))
            cursor = range.upperBound
        }
        out.append(contentsOf: units[cursor...])
        return DisplayedText(text: String(decoding: out, as: UTF16.self), map: DisplayOffsetMap(pieces: pieces))
    }
}

extension SearchText {
    /// 原文（canonical）里的命中映射到显示文本：只映射不切开生成原子的命中；切开的不高亮（宁可不标，也不错标）。
    public static func mappedRanges(raw: String, shown: DisplayedText, query: String) -> [[Int]] {
        localRanges(in: raw, query: query).compactMap { r in
            let rr = r[0]..<(r[0] + r[1])
            guard !shown.map.splitsAtom(rawRange: rr) else { return nil }
            let lo = shown.map.shown(forRaw: rr.lowerBound, edge: .start), hi = shown.map.shown(forRaw: rr.upperBound, edge: .end)
            return hi > lo ? [lo, hi - lo] : nil
        }
    }

    /// 交给按查询串匹配的 Markdown 视图用：显示文本里的匹配与原文命中一一对应时可以直接用查询串；
    /// 有被替换的原子使两边对不上（如查询落在原子里、或显示词恰好含查询）时返回 nil——不高亮，而不是错高亮。
    public static func consistentQuery(raw: String, shown: DisplayedText, query: String?) -> String? {
        guard let q = query, !q.isEmpty else { return query }
        if shown.map == .identity { return q }
        let canonical = localRanges(in: raw, query: q).count
        let onShown = localRanges(in: shown.text, query: q).count
        return canonical == mappedRanges(raw: raw, shown: shown, query: q).count && canonical == onShown ? q : nil
    }
}
