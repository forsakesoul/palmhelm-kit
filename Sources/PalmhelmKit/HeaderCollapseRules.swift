import Foundation

// 会话页头部随滚动收起（#60）：两端共用，只判定，不碰界面。
// 向内容末尾（偏移增大）滚动收起，向开头滚动展开；到顶恒展开。
// 真机 120Hz 下，收起 / 展开动画会连续约 24 帧改变滚动几何，偏移修正会被误当成手势，所以判定用时间门控；
// 手指位移按累计判定：收起需要 60pt，展开需要反向 24pt（或到顶）；切换后要再反向累计满阈值才会切回（迟滞）。
// 手势开始后前 150ms 与布局变化或头部自身切换后的静默期内，偏移只同步参考点，不判定。

public enum HeaderCollapseRules {
    /// 收起所需的向末尾方向累计位移（偏灵敏会在刚开始滚动时就收起）。
    public static let collapseThreshold: CGFloat = 60
    /// 展开所需的向开头方向累计位移（到顶恒展开，不受此约束）。
    public static let expandThreshold: CGFloat = 24
    /// 手势开始后的判定起始延迟（秒）：前 150ms 只同步参考点。
    public static let gestureLeadSeconds: Double = 0.15
    /// 布局变化（或头部自身切换）后的静默期（秒）。
    public static let settleSeconds: Double = 0.3
    /// 不分方向模式（anyDirectionIdle）：本次滚动真正结束（idle）后开始恢复显示的延迟（秒）。
    public static let restoreDelaySeconds: Double = 1.0

    /// 单步判定（无时间门控，供纯规则使用）：delta 为上一判定到现在的偏移变化。
    public static func next(previousOffset: CGFloat, newOffset: CGFloat, atTop: Bool, collapsed: Bool) -> Bool {
        if atTop { return false }
        let delta = newOffset - previousOffset
        if delta > 0 { return delta >= collapseThreshold ? true : collapsed }
        if delta <= -expandThreshold { return false }
        return collapsed
    }
}

/// 滚动相位（不依赖任何 UI 框架）：平台各自把自己的相位映射到这里。
public enum HeaderCollapsePhase: Sendable, Equatable { case idle, tracking, interacting, decelerating, animating }

/// 收起行为：directional 是原有的方向规则（默认，行为不变）；anyDirectionIdle 是新的显式 opt-in——
/// 不分方向，门控后净位移达 60pt 收起，本次滚动真正结束（idle）后 1 秒恢复，顶 / 真底 / 读屏等由调用者强制显示。
public enum HeaderCollapseBehavior: Sendable, Equatable {
    case directional, anyDirectionIdle
    /// 方向进度（显式 opt-in）：向末尾（偏移增大）滚动按行程 H 逐点隐藏，向开头滚动立即逐点恢复，idle 保持当前进度，无计时、无阈值。
    case directionalProgress
}

/// 头部收起状态（两端共用的纯状态）。只有用户手势、且不在静默期内，才参与判定；其余只重置参考点。
/// 用户位移按有符号量累计：中间夹着的非用户帧（重排修正）不会丢掉已经发生的手指位移。
/// `now` 为单调时钟（秒，例如 ProcessInfo.systemUptime）。
public struct HeaderCollapseState: Sendable, Equatable {
    public private(set) var collapsed = false
    private var anchor: CGFloat?
    private var accumulated: CGFloat = 0
    private var settleUntil: Double = -.infinity
    private var gestureStart: Double = -.infinity

    public let behavior: HeaderCollapseBehavior
    // —— 以下仅 anyDirectionIdle 使用（directional 下恒为初值）——
    /// 唯一的恢复时刻与其票据：票据在每次取消 / 重新安排时递增，迟到的到期回调凭旧票据无效。Kit 不创建 Task、不读时钟，平台只据此安排一个可取消的等待。
    public private(set) var deadline: Double?
    public private(set) var token = 0
    private var phase = HeaderCollapsePhase.idle
    private var net: CGFloat = 0
    /// 当前用户手势是否有效：进入 interacting 得到，idle / tracking / animating / reset 失去；decelerating 沿用。
    private var eligible = false
    public var restoreDelay = HeaderCollapseRules.restoreDelaySeconds
    /// 仅 directionalProgress：已隐藏的距离（0…chromeExtent）与行程。
    private var hiddenDistance: CGFloat = 0
    private var extent: CGFloat = 0

    public init(behavior: HeaderCollapseBehavior = .directional) { self.behavior = behavior }

    /// 不分方向模式下的“已收起”（与 collapsed 同一个值，名字更贴合）；方向进度模式下为 progress == 1。
    public var hidden: Bool { behavior == .directionalProgress ? progress >= 1 : collapsed }

    /// 方向进度（0 完全显示 … 1 完全隐藏）；其它模式恒为 0 / 1（随 collapsed）。
    public var progress: CGFloat {
        guard behavior == .directionalProgress else { return collapsed ? 1 : 0 }
        return extent > 0 ? min(1, max(0, hiddenDistance / extent)) : 0
    }

    /// 测量入口：把实测的头部高度 H 同步进规则（方向进度模式）。H 变化 / 首次测量都从显示重新开始；
    /// 不等下一次几何回调，所以 `visibleExtent` 读到的立即是新 H。
    public mutating func setChromeExtent(_ h: CGFloat) {
        guard behavior == .directionalProgress else { return }
        extent = h.isFinite && h > 0 ? h : 0
        hiddenDistance = 0
        collapsed = false
        anchor = nil
    }

    /// 仍遮挡顶部的高度（H × (1 − progress)），供可见区域计算消费。
    public var visibleExtent: CGFloat { behavior == .directionalProgress ? max(0, extent - hiddenDistance) : 0 }

    /// 手势开始（手指按下 / 相位进入 interacting）：前 150ms 不判定。
    public mutating func gestureBegan(at now: Double) {
        gestureStart = now
        accumulated = 0
    }

    /// 布局（内容高度 / 视口 / 内边距）变化：从现在起静默一段时间。
    public mutating func layoutChanged(at now: Double) {
        settleUntil = max(settleUntil, now + HeaderCollapseRules.settleSeconds)
    }

    /// 滚动偏移变化。`userGesture` 为 false，或在静默期 / 手势起始延迟内，只重置参考点；否则累计位移后判定。
    public mutating func scrolled(to offset: CGFloat, userGesture: Bool, at now: Double = 0) {
        let user = userGesture && now >= settleUntil && now >= gestureStart + HeaderCollapseRules.gestureLeadSeconds
        guard user, let anchor else {
            self.anchor = offset
            return
        }
        accumulated += offset - anchor
        self.anchor = offset
        let before = collapsed
        if offset <= 0 {
            collapsed = false
            accumulated = 0
        } else if accumulated >= HeaderCollapseRules.collapseThreshold {
            collapsed = true
            accumulated = 0
        } else if accumulated <= -HeaderCollapseRules.expandThreshold {
            collapsed = false
            accumulated = 0
        }
        if collapsed != before { settleUntil = max(settleUntil, now + HeaderCollapseRules.settleSeconds) }
    }

    /// 换线程、切到终端页、选择清空后：展开并丢掉参考点、累计量与各类时间窗，下一次测量只定参考点。
    public mutating func reset() {
        collapsed = false
        anchor = nil
        accumulated = 0
        settleUntil = -.infinity
        gestureStart = -.infinity
        hiddenDistance = 0
        guard behavior != .directional else { return }
        // 不分方向 / 方向进度模式：旧票据作废、时刻清空、相位与资格重置（保留 restoreDelay）
        net = 0
        deadline = nil
        token += 1
        phase = .idle
        eligible = false
    }
}

// MARK: 不分方向 + idle 恢复（anyDirectionIdle）
// 阶段变化、几何变化（含强制显示）、当前 deadline、到期复核；`now` 一律由调用者显式传入（单调时钟，秒）。
extension HeaderCollapseState {
    private mutating func cancelRestore() {
        if deadline != nil { deadline = nil }
        token += 1
    }

    /// 相位变化：新一次手势（进入 interacting）重启 150ms 起步并清净位移；减速接续不重启；idle 才开始 1 秒计时（重复 idle 不续期）。
    public mutating func phaseChanged(to new: HeaderCollapsePhase, at now: Double) {
        if behavior == .directionalProgress { progressPhaseChanged(to: new); return }
        guard behavior == .anyDirectionIdle else { return }
        let old = phase
        phase = new
        switch new {
        case .idle:
            eligible = false
            guard old != .idle, collapsed else { return }
            token += 1
            deadline = now + restoreDelay
        case .interacting:
            cancelRestore()
            eligible = true
            if old != .interacting { gestureStart = now; net = 0 }
        case .decelerating:
            cancelRestore()
        case .tracking, .animating:
            cancelRestore()
            eligible = false
        }
    }

    /// 几何变化。`user` 为用户拖动 / 惯性；`force` 为到顶、真底、读屏、导航未就绪等必须显示的条件（先于所有门控）；
    /// 强制条件解除不恢复旧的收起。
    /// `chromeExtent` 仅方向进度模式使用：导航行 + 会话栏的自然总高度 H（≤ 0 或非有限时失败开放：显示）。
    public mutating func moved(to offset: CGFloat, user: Bool, layoutChanged: Bool, force: Bool, at now: Double, chromeExtent: CGFloat = 0) {
        if behavior == .directionalProgress { progressMoved(to: offset, user: user, layoutChanged: layoutChanged, force: force, chromeExtent: chromeExtent); return }
        guard behavior == .anyDirectionIdle else { return }
        if layoutChanged { settleUntil = max(settleUntil, now + HeaderCollapseRules.settleSeconds) }
        if force {
            show()
            anchor = offset
            return
        }
        let gated = user && eligible && now >= settleUntil && now >= gestureStart + HeaderCollapseRules.gestureLeadSeconds
        guard gated, let anchor else {
            self.anchor = offset
            return
        }
        net += offset - anchor
        self.anchor = offset
        if !collapsed, abs(net) >= HeaderCollapseRules.collapseThreshold {
            collapsed = true
            net = 0
        }
    }

    /// 到期复核：只有当前票据、仍在 idle 且已到时刻才显示。返回是否发生了显示。
    public mutating func expire(token t: Int, at now: Double) -> Bool {
        guard behavior == .anyDirectionIdle, t == token, let d = deadline, phase == .idle, now >= d else { return false }
        deadline = nil
        token += 1
        net = 0
        anchor = nil
        collapsed = false
        return true
    }

    /// 立即显示并丢掉累计与恢复计时（强制显示条件、上下文变化）。
    public mutating func show() {
        if behavior == .directionalProgress { hiddenDistance = 0; collapsed = false; return }
        guard behavior == .anyDirectionIdle else { return }
        collapsed = false
        net = 0
        cancelRestore()
    }
}

// MARK: 方向进度（directionalProgress）
// p = 已隐藏距离 / H。用户（拖动及其惯性）每帧的有符号位移直接累加到 [0, H]：正向隐藏、反向立即恢复；
// 端点不留“欠账”；idle / 程序化滚动 / 布局修正只同步参考点，不改变进度；没有计时与阈值。
extension HeaderCollapseState {
    fileprivate mutating func progressPhaseChanged(to new: HeaderCollapsePhase) {
        phase = new
        switch new {
        case .interacting: eligible = true
        case .decelerating: break // 只从有效的用户 interacting 继承
        case .idle, .tracking, .animating: eligible = false
        }
    }

    fileprivate mutating func progressMoved(to offset: CGFloat, user: Bool, layoutChanged: Bool, force: Bool, chromeExtent: CGFloat) {
        guard offset.isFinite, chromeExtent.isFinite, chromeExtent > 0 else { // 失败开放
            hiddenDistance = 0; collapsed = false; extent = 0; anchor = nil
            return
        }
        if chromeExtent != extent { // H 变化（字号 / 旋转 / 会话栏内容）：旧基准作废，从显示重新开始
            extent = chromeExtent
            hiddenDistance = 0; collapsed = false
            anchor = offset
            return
        }
        defer { anchor = offset }
        if force { hiddenDistance = 0; collapsed = false; return }
        guard !layoutChanged, user, eligible, let anchor else { return }
        hiddenDistance = min(extent, max(0, hiddenDistance + offset - anchor))
        collapsed = hiddenDistance >= extent
    }
}
