import SwiftUI
import Charts

/// 测试接缝（#30）：把柱图的 ChartProxy 坐标交给测试（真实 Chart 的 position / value 映射）。生产不设置。
/// 两端的柱图在 chartOverlay 里调用 attach(proxy)；测试通过 position / key 读取真实坐标，不靠数据层的 bar(at:) / bar(key:)。
public final class ChartProbe {
    public private(set) var position: ((String) -> CGFloat?)?
    public private(set) var key: ((CGFloat) -> String?)?
    public init() {}
    public func attach(_ proxy: ChartProxy) {
        position = { proxy.position(forX: $0) }
        key = { proxy.value(atX: $0, as: String.self) }
    }
}
