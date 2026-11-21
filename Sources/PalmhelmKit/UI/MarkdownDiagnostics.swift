import Foundation

/// Markdown 准备成本的取证计数（默认关闭，只有排版矩阵测试开启）：只记次数与耗时，不记任何正文。
enum MarkdownDiagnostics {
    struct Snapshot: Equatable {
        var blockParses = 0
        var inlineParses = 0
        var nanos: UInt64 = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts = Snapshot()
    nonisolated(unsafe) static var enabled = false

    static func reset() { lock.lock(); counts = Snapshot(); lock.unlock() }
    static func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return counts }

    /// 计一次块解析 / 行内解析并累计耗时；关闭时只是一次布尔读取。
    @inline(__always) static func measure<T>(block: Bool, _ work: () -> T) -> T {
        guard enabled else { return work() }
        let start = DispatchTime.now().uptimeNanoseconds
        let value = work()
        let spent = DispatchTime.now().uptimeNanoseconds &- start
        lock.lock()
        if block { counts.blockParses += 1 } else { counts.inlineParses += 1 }
        counts.nanos &+= spent
        lock.unlock()
        return value
    }
}
