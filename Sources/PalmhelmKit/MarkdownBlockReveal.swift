import Foundation

// 打字效果片 2 的纯规则（A1-002）：哪些块是“全新块”、各自的淡入排期。无 SwiftUI；时刻由调用方注入。
// 只描述呈现：不接受正文、回调或 Session，不改变数据到达时机。

/// 一次到达的块淡入请求。`prefixUTF8Count` 是本次到达之前已接纳的完整源文前缀字节数（不是屏幕显露字数）。
public struct MarkdownBlockReveal: Equatable, Sendable {
    /// 口径：`.brief` 为旧默认（0.0.1 的既有行为）；`.arrival` 供“新回复到达即逐步显现”使用。只有这两个值，不是自由配置。
    public enum Style: Equatable, Sendable {
        case brief
        case arrival

        /// 总窗口上限：不因后续批次延长。
        public var maxWindow: Double { self == .brief ? 0.250 : 0.800 }
        public var blockDuration: Double { self == .brief ? 0.120 : 0.360 }
        public var maxStep: Double { self == .brief ? 0.024 : 0.060 }
    }

    /// `.brief` 的旧静态常量，取值不变。
    public static let maxWindow = Style.brief.maxWindow
    public static let blockDuration = Style.brief.blockDuration
    public static let maxStep = Style.brief.maxStep
    public static let maxNewBlocks = 16
    /// 剩余时间不足一帧（1/24 s）直接全文。
    public static let minWindow = 1.0 / 24.0

    public let generation: Int
    public let prefixUTF8Count: Int
    public let startUptime: Double
    public let deadlineUptime: Double
    public let style: Style

    public init?(generation: Int, prefixUTF8Count: Int, startUptime: Double, deadlineUptime: Double, style: Style = .brief) {
        guard generation >= 0, prefixUTF8Count >= 0, startUptime.isFinite, deadlineUptime.isFinite, startUptime >= 0,
              deadlineUptime > startUptime, deadlineUptime - startUptime <= style.maxWindow + 1e-9 else { return nil }
        self.generation = generation; self.prefixUTF8Count = prefixUTF8Count
        self.startUptime = startUptime; self.deadlineUptime = deadlineUptime; self.style = style
    }
}

/// 新块与排期：块 i 的 delay / duration（秒，相对请求开始）。
public struct MarkdownBlockSchedule: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        public let index: Int
        public let delay: Double
        public let duration: Double
    }
    public let slots: [Slot]

    /// nil = 直显：任一范围缺失 / 不合法（整条不信任，全文直显）、没有新块、剩余窗口不足一帧；
    /// `.brief` 下新块多于 16 个也直显。`.arrival` 下只淡入源顺序的前 16 个新块，其余直显，但仍校验全部范围。
    /// 全新块 = 范围非空且起点不早于 prefixUTF8Count；与前缀相交的块（即使末尾增长很多）已被看过，不重淡入。
    public init?(ranges: [Range<Int>?], utf8Count: Int, reveal: MarkdownBlockReveal) {
        var previousEnd = 0
        var fresh: [Int] = []
        for (i, r) in ranges.enumerated() {
            guard let r, r.lowerBound >= previousEnd, r.upperBound <= utf8Count else { return nil } // 缺失 / 乱序 / 重叠 / 越界
            previousEnd = r.upperBound
            if !r.isEmpty, r.lowerBound >= reveal.prefixUTF8Count { fresh.append(i) }
        }
        if fresh.count > MarkdownBlockReveal.maxNewBlocks {
            guard reveal.style == .arrival else { return nil }
            fresh = Array(fresh.prefix(MarkdownBlockReveal.maxNewBlocks))
        }
        let n = fresh.count
        let window = reveal.deadlineUptime - reveal.startUptime
        guard n >= 1, window >= MarkdownBlockReveal.minWindow else { return nil }
        let duration = min(reveal.style.blockDuration, window)
        let step = n == 1 ? 0 : min(reveal.style.maxStep, max(0, window - duration) / Double(n - 1))
        slots = fresh.enumerated().map { Slot(index: $1, delay: Double($0) * step, duration: duration) }
    }

    public func slot(for index: Int) -> Slot? { slots.first { $0.index == index } }
}

#if DEBUG
/// DEBUG 探针：块淡入实际绘制过的中间 opacity 样本数（宿主据此证明跑了绘制过程，不是只调了纯函数）。Release 不存在。
public enum MarkdownBlockRevealProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var samples = 0
    static func recordIntermediate() { lock.lock(); samples += 1; lock.unlock() }
    public static var intermediateSamples: Int { lock.lock(); defer { lock.unlock() }; return samples }
}
#endif
