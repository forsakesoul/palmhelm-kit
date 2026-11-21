import Foundation

/// 事件流自愈的纯规则（#85，A1-059）：退避、路径变化是否需要立即重连。无副作用，便于单测。
public enum ReconnectPolicy {
    public static let backoffBase: TimeInterval = 1
    public static let backoffCap: TimeInterval = 30
    /// 退避的抖动幅度：每次等待取 ±20% 之内的值（jitter 为 0...1，由调用方提供随机数）。
    public static let jitterSpread: TimeInterval = 0.2

    /// 第 attempt 次连续失败后的等待（attempt 从 1 起）：1s 起翻倍，上限 30s，带抖动。
    public static func delay(attempt: Int, jitter: Double) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let base = min(backoffCap, backoffBase * pow(2, exponent))
        let clamped = min(max(jitter, 0), 1)
        let factor = 1 - jitterSpread + 2 * jitterSpread * clamped
        return min(backoffCap, base * factor)
    }

    /// 网络路径的摘要（只含会影响选路与可达性的几个布尔值）。
    public struct PathSignature: Equatable, Sendable {
        public var satisfied: Bool
        public var wifi: Bool
        public var cellular: Bool
        public var vpn: Bool

        public init(satisfied: Bool, wifi: Bool, cellular: Bool, vpn: Bool) {
            self.satisfied = satisfied
            self.wifi = wifi
            self.cellular = cellular
            self.vpn = vpn
        }

        /// 当前只走蜂窝（没有 Wi‑Fi）：局域网地址大概率不可达，候选应后置。
        public var cellularOnly: Bool { cellular && !wifi }
    }

    /// 新路径可用，且刚从不可用恢复、或接口类型 / VPN 状态相对上一次采样变化时，应取消挂住的尝试并立即重连。首次采样与路径不可用时不触发。
    public static func pathChangeNeedsReconnect(old: PathSignature?, new: PathSignature) -> Bool {
        guard let old, new.satisfied else { return false } // 路径不可用时不抢先重连：等它恢复（那时才有可连的路径）
        if !old.satisfied { return true }
        return old.wifi != new.wifi || old.cellular != new.cellular || old.vpn != new.vpn
    }
}
