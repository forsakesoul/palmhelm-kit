import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// 会话搜索的两端共用规则：查询守卫、错误与定位文案、目标的本地筛选、按 UTF-16 区间的高亮（契约见 docs/ops/local-api.md §8d）。
/// 只做纯计算；网络与状态留给各端 Session。
public enum SearchText {
    public static var busy: String { KitL10n.string("上一次搜索还在进行，稍后再试") }
    public static var moved: String { KitL10n.string("这条记录已移动，请重新搜索") }
    public static var partial: String { KitL10n.string("只搜了部分记录，再搜一次会接着往下找") }
    public static var failed: String { KitL10n.string("搜索失败，请稍后再试") }
    public static var openFailed: String { KitL10n.string("打开这条记录失败，请稍后再试") }
    /// 同一线程的会话记录请求已占满两个槽：定位不发请求，提示稍后再试。
    public static var locateBusy: String { KitL10n.string("记录还在加载，稍后再试") }

    /// Bridge 对 q 的长度要求（去首尾空白后的 UTF-16 单位数）。Mac 按钮与 Return、iPhone 提交共用这一守卫。
    public static let queryUnits = 2...128

    /// 去首尾空白后的查询；长度不合法返回 nil（调用方不发请求）。
    public static func normalizedQuery(_ raw: String) -> String? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return queryUnits.contains(q.utf16.count) ? q : nil
    }

    /// 搜索请求失败的人话：409 是同设备上一次搜索未结束；其余统一为通用失败。
    public static func failure(_ error: Error) -> String {
        if let e = error as? BridgeError, e == .http(status: 409) { return busy }
        return failed
    }

    /// 记录里的命中（本地、不分大小写）：每个不重叠出现处的 UTF-16 `[起始, 长度]`；空查询无结果。
    public static func localRanges(in text: String, query: String) -> [[Int]] {
        guard !query.isEmpty else { return [] }
        var out: [[Int]] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: query, options: .caseInsensitive, range: from..<text.endIndex) {
            out.append([text.utf16.distance(from: text.startIndex, to: r.lowerBound), text[r].utf16.count])
            from = r.upperBound
        }
        return out
    }
}

#if canImport(SwiftUI)
extension SearchText {
    /// 命中的高亮底色：浅色与深色背景下都可读。
    public static let highlightColor = Color.yellow.opacity(0.35)

    /// 片段高亮：`ranges` 为 Bridge 给的 UTF-16 `[起始, 长度]`。越界、空长、落在代理对中间、或与前一段重叠的区间忽略，不崩。
    public static func highlighted(snippet: String, ranges: [[Int]]) -> AttributedString {
        var out = AttributedString()
        var cursor = snippet.startIndex
        for span in validSpans(in: snippet, ranges: ranges) where span.lowerBound >= cursor {
            out += AttributedString(snippet[cursor..<span.lowerBound])
            var hit = AttributedString(snippet[span])
            hit.backgroundColor = highlightColor
            hit.inlinePresentationIntent = .stronglyEmphasized
            out += hit
            cursor = span.upperBound
        }
        out += AttributedString(snippet[cursor...])
        return out
    }

    /// 富文本里的命中（不分大小写）加底色，只改样式。在渲染后的可见字符上找，Markdown 语法字符不参与匹配；query 为空不改动。
    public static func marking(_ a: AttributedString, query: String?) -> AttributedString {
        guard let q = query, !q.isEmpty else { return a }
        var out = a
        let plain = String(a.characters)
        var from = plain.startIndex
        while let r = plain.range(of: q, options: .caseInsensitive, range: from..<plain.endIndex) {
            let lo = out.index(out.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: r.lowerBound))
            let hi = out.index(lo, offsetByCharacters: plain.distance(from: r.lowerBound, to: r.upperBound))
            out[lo..<hi].backgroundColor = highlightColor
            from = r.upperBound
        }
        return out
    }

    /// 阅读页：按全文显示流里的命中区间（Character 偏移）给这一段文字加底色。区间与本段 [offset, offset+count) 相交的部分才标，
    /// 因此跨页 / 跨片的命中在每一片上各自标出自己的那一部分。
    public static func marking(_ a: AttributedString, offset: Int, matches: [Range<Int>]) -> AttributedString {
        guard !matches.isEmpty else { return a }
        let count = a.characters.count
        var out = a
        for m in matches where m.upperBound > offset && m.lowerBound < offset + count {
            let lo = max(m.lowerBound, offset) - offset, hi = min(m.upperBound, offset + count) - offset
            let l = out.index(out.startIndex, offsetByCharacters: lo)
            let h = out.index(l, offsetByCharacters: hi - lo)
            out[l..<h].backgroundColor = highlightColor
        }
        return out
    }

    /// 阅读页纯文本页：同一套命中区间标到一段字符串上。
    public static func marking(_ s: String, offset: Int, matches: [Range<Int>]) -> AttributedString {
        marking(AttributedString(s), offset: offset, matches: matches)
    }

    /// 记录正文（纯文本）里的本地命中高亮：与 `highlighted(snippet:ranges:)` 同样的样式。
    public static func highlightedText(_ text: String, query: String) -> AttributedString {
        highlighted(snippet: text, ranges: localRanges(in: text, query: query))
    }

    /// 搜索结果片段：命中范围（相对 canonical snippet）映射到显示文本；切开生成原子的命中不标。
    public static func highlighted(hit: SearchHit) -> AttributedString {
        let shown = hit.snippetDisplayed
        guard shown.map != .identity else { return highlighted(snippet: hit.snippet, ranges: hit.ranges) }
        let mapped: [[Int]] = hit.ranges.compactMap { r in
            guard r.count == 2, r[0] >= 0, r[1] > 0 else { return nil }
            let rr = r[0]..<(r[0] + r[1])
            guard !shown.map.splitsAtom(rawRange: rr) else { return nil }
            let lo = shown.map.shown(forRaw: rr.lowerBound, edge: .start), hi = shown.map.shown(forRaw: rr.upperBound, edge: .end)
            return hi > lo ? [lo, hi - lo] : nil
        }
        return highlighted(snippet: shown.text, ranges: mapped)
    }

    /// 记录正文（纯文本）按原文命中映射到显示文本后高亮；映射失败的命中不标。
    public static func highlightedText(raw: String, shown: DisplayedText, query: String) -> AttributedString {
        highlighted(snippet: shown.text, ranges: shown.map == .identity ? localRanges(in: shown.text, query: query) : mappedRanges(raw: raw, shown: shown, query: query))
    }

    private static func validSpans(in s: String, ranges: [[Int]]) -> [Range<String.Index>] {
        let u = s.utf16
        var spans: [Range<String.Index>] = []
        for r in ranges where r.count == 2 {
            let start = r[0], len = r[1]
            guard start >= 0, len > 0, start <= u.count, len <= u.count - start else { continue }
            let lo = u.index(u.startIndex, offsetBy: start), hi = u.index(lo, offsetBy: len)
            guard let a = lo.samePosition(in: s), let b = hi.samePosition(in: s) else { continue }
            spans.append(a..<b)
        }
        return spans.sorted { $0.lowerBound < $1.lowerBound }
    }
}
#endif

/// 搜索命中的定位（两端共用，Session 只负责调用与网络）：pageBefore 缺省表示最新页，否则取命中所在页进入定位视图。
public enum SearchLocate {
    /// 取命中页失败：410（游标失效）给“已移动”，其它错误给“打开失败”。
    public static func failure(_ error: Error) -> String {
        if let e = error as? BridgeError, e == .http(status: 410) { return SearchText.moved }
        return SearchText.openFailed
    }

    /// 把命中所在页并入为定位视图；页里没有 itemId（追加过多、已移动）时返回文案，线程不变。
    public static func apply(page: TranscriptPage, hit: SearchHit, to thread: inout TranscriptThread) -> String? {
        thread.applyLocated(page, itemId: hit.itemId) ? nil : SearchText.moved
    }

    /// pageBefore 缺省：最新页里有该条才算定位成功，否则返回文案。
    public static func inLatest(_ hit: SearchHit, _ thread: TranscriptThread) -> String? {
        thread.items.contains { $0.id == hit.itemId } ? nil : SearchText.moved
    }

    /// 一页已成功读到时的判定（pageBefore 缺省时直接用这一页，不等在途请求）：页里有该条返回 nil，否则返回文案。
    public static func inPage(_ hit: SearchHit, _ page: TranscriptPage) -> String? {
        page.items.contains { $0.id == hit.itemId } ? nil : SearchText.moved
    }
}

/// 会话记录与搜索的网络面（Session 的测试替身接缝）：BridgeClient 即是实现。
public protocol SearchTranscriptClient: Sendable {
    func search(q: String, limit: Int) async throws -> SearchResponse
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage
    /// 目标账本历史（#97）：归档线程的只读分页。
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage
    /// 条件读取（#88 S2）与按条续读：默认实现只读整页、没有续读入口（测试桩与旧客户端不需要改）。
    func transcriptConditional(targetId: String, before: String?, limit: Int, ifNoneMatch: String?) async throws -> TranscriptFetch
    /// 首页条件读取携带回执后补声明；默认实现忽略声明（只实现上一个的测试桩与旧客户端不用改）。
    func transcriptConditional(targetId: String, before: String?, limit: Int, ifNoneMatch: String?, receipt: TranscriptReceiptRequest?) async throws -> TranscriptFetch
    func transcriptItem(targetId: String, itemId: String, continuation: String) async throws -> TranscriptItemSegment
}

public extension SearchTranscriptClient {
    func transcriptConditional(targetId: String, before: String?, limit: Int, ifNoneMatch: String?) async throws -> TranscriptFetch {
        .page(try await transcript(targetId: targetId, before: before, limit: limit), etag: nil)
    }
    func transcriptConditional(targetId: String, before: String?, limit: Int, ifNoneMatch: String?, receipt: TranscriptReceiptRequest?) async throws -> TranscriptFetch {
        try await transcriptConditional(targetId: targetId, before: before, limit: limit, ifNoneMatch: ifNoneMatch)
    }
    func transcriptItem(targetId: String, itemId: String, continuation: String) async throws -> TranscriptItemSegment {
        throw BridgeError.http(status: 404)
    }
}

extension BridgeClient: SearchTranscriptClient {}

/// 当前定位：哪个线程、哪条命中、用哪个词高亮。serial 每次打开递增，视图据此重新滚动到命中。
public struct SearchLocation: Equatable, Sendable {
    public var threadId: String
    public var itemId: String
    public var query: String
    public var serial: Int

    public init(threadId: String, itemId: String, query: String, serial: Int) {
        self.threadId = threadId; self.itemId = itemId; self.query = query; self.serial = serial
    }

    /// 新一次打开：serial 在上一次的基础上递增（即使是同一条命中，也要重新滚动；退出定位后 serial 仍不回退）。
    public static func opened(after serial: Int, threadId: String, itemId: String, query: String) -> SearchLocation {
        SearchLocation(threadId: threadId, itemId: itemId, query: query, serial: serial + 1)
    }

    /// 高亮只作用于定位所在的线程。
    public func highlight(for threadId: String) -> String? { threadId == self.threadId ? query : nil }
}

/// 目标列表的本地筛选：只看已经在手机上的目标，不发请求。
public enum TargetFilter {
    /// 不分大小写，agent 名 / 项目名 / 主题 / 工作区 / 标签 / 仓库名 / 分支 任一包含即命中；空白查询匹配全部。
    public static func matches(_ t: TargetSummary, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let fields: [String?] = [t.agentName, t.projectName, t.topic?.text, t.location?.workspace, t.location?.tab, t.repo?.name, t.repo?.branch]
        return fields.contains { $0?.range(of: q, options: .caseInsensitive) != nil }
    }
}
