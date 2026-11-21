import Foundation

/// 地址扫描游标（O1-349 R3）：只决定下一轮先试哪些候选，不改写 preferred（展示与其他操作仍用 preferred，只有成功才登记）。
/// 一个周期内每个候选只按一次顺序（preferred 先）；预算用尽时未试的候选留给下一轮；周期试完后从头再来。
/// 地址表变化时重新排序。刷新与成员监视共用这一逻辑。
public struct EndpointScan: Sendable {
    private var queue: [Int]?
    private var snapshot: [BridgeEndpoint] = []
    private var cellularOnly = false

    public init() {}

    /// 本轮的尝试顺序（下标）：沿用上一轮未试的候选；地址表变化或周期已试完时重新排序。
    public mutating func plan(endpoints: [BridgeEndpoint], preferred: Int, cellularOnly: Bool = false) -> [Int] {
        if queue == nil || snapshot != endpoints || queue?.isEmpty == true || self.cellularOnly != cellularOnly {
            queue = EndpointRotation.order(endpoints, preferred: preferred, cellularOnly: cellularOnly)
            snapshot = endpoints
            self.cellularOnly = cellularOnly
        }
        return queue ?? []
    }

    /// 记录一次尝试：成功结束本周期；失败则该候选本周期已试过、从待试队列移除。
    public mutating func record(_ index: Int, succeeded: Bool) {
        guard queue != nil else { return }
        if succeeded { queue = nil; return }
        queue?.removeAll { $0 == index }
    }

    /// 结束当前周期（成功登记或业务错误终止）：下一次从 preferred 重建顺序，已恢复的地址不会被旧队列排除（O1-350 R5 / R6）。
    public mutating func reset() { queue = nil }

    /// 本周期的每个候选都已试过且都失败。
    public var cycleExhausted: Bool { queue?.isEmpty == true }

    /// 本周期还没试的候选数。
    public var untried: Int { queue?.count ?? 0 }
}
