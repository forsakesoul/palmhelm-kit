import Foundation

// 打字效果片 2 的纯规则（A1-002）：哪些块是“全新块”、各自的淡入排期。无 SwiftUI；时刻由调用方注入。
// 只描述呈现：不接受正文、回调或 Session，不改变数据到达时机。

/// 一次到达的块淡入请求。`prefixUTF8Count` 是本次到达之前已接纳的完整源文前缀字节数（不是屏幕显露字数）。
public struct MarkdownBlockReveal: Equatable, Sendable {
    /// 总窗口上限：不因后续批次延长。
    public static let maxWindow = 0.250
    public static let blockDuration = 0.120
    public static let maxStep = 0.024
    public static let maxNewBlocks = 16
    /// 剩余时间不足一帧（1/24 s）直接全文。
    public static let minWindow = 1.0 / 24.0

    public let generation: Int
    public let prefixUTF8Count: Int
    public let startUptime: Double
    public let deadlineUptime: Double

    public init?(generation: Int, prefixUTF8Count: Int, startUptime: Double, deadlineUptime: Double) {
        guard generation >= 0, prefixUTF8Count >= 0, startUptime.isFinite, deadlineUptime.isFinite, startUptime >= 0,
              deadlineUptime > startUptime, deadlineUptime - startUptime <= Self.maxWindow + 1e-9 else { return nil }
        self.generation = generation; self.prefixUTF8Count = prefixUTF8Count
        self.startUptime = startUptime; self.deadlineUptime = deadlineUptime
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

    /// nil = 直显：任一范围缺失 / 不合法、没有新块、新块多于 16 个、剩余窗口不足一帧。
    /// 全新块 = 范围非空且起点不早于 prefixUTF8Count；与前缀相交的块（即使末尾增长很多）已被看过，不重淡入。
    public init?(ranges: [Range<Int>?], utf8Count: Int, reveal: MarkdownBlockReveal) {
        var previousEnd = 0
        var fresh: [Int] = []
        for (i, r) in ranges.enumerated() {
            guard let r, r.lowerBound >= previousEnd, r.upperBound <= utf8Count else { return nil } // 缺失 / 乱序 / 重叠 / 越界
            previousEnd = r.upperBound
            if !r.isEmpty, r.lowerBound >= reveal.prefixUTF8Count { fresh.append(i) }
        }
        let n = fresh.count
        let window = reveal.deadlineUptime - reveal.startUptime
        guard n >= 1, n <= MarkdownBlockReveal.maxNewBlocks, window >= MarkdownBlockReveal.minWindow else { return nil }
        let duration = min(MarkdownBlockReveal.blockDuration, window)
        let step = n == 1 ? 0 : min(MarkdownBlockReveal.maxStep, max(0, window - duration) / Double(n - 1))
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
