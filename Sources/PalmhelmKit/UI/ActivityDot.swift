import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// 目标的运行中状态（两端共用的视觉语义）：离线 > 等你 > 工作中 > 空闲。
public enum ActivityKind: Equatable, Sendable {
    case working, idle, waiting, offline
}

public enum ThreadActivity {
    /// 从 Bridge 投影的在线与状态、待答数推出视觉语义。`online == false`（或既无状态又不在线）即离线；
    /// 有待答（或状态为 blocked）算等你；只有 working 才算工作中。
    public static func activity(online: Bool?, status: AgentStatus?, pending: Int) -> ActivityKind {
        if online == false || (status == nil && online != true) { return .offline }
        if pending > 0 || status == .blocked { return .waiting }
        if status == .working { return .working }
        return .idle
    }

    /// 已工作时长的人话（秒）：不足 1 分钟 → 「刚开始」；不足 1 小时 → 「N 分钟」；否则「N 小时」或「N 小时 M 分」。
    /// 只用于粗粒度展示（列表每 30 秒刷新），不是秒级计时。
    public static func elapsedLabel(seconds: Int) -> String {
        let m = max(0, seconds) / 60
        if m < 1 { return KitL10n.string("刚开始") }
        if m < 60 { return KitL10n.format("%lld 分钟", m) }
        let h = m / 60, rem = m % 60
        return rem == 0 ? KitL10n.format("%lld 小时", h) : KitL10n.format("%lld 小时 %lld 分", h, rem)
    }

    /// 「工作中 · 2 分钟」形式的状态行（时长从 Session 记下的开始时刻算起）。
    public static func workingLine(seconds: Int) -> String { "\(AgentStatus.working.label) · \(elapsedLabel(seconds: seconds))" }

    /// 唯一的状态文案映射：列表副标题、对话 chip、底部提示都由 ActivityKind 推导，不再各自从 AgentStatus 生成。
    /// since 只对 working 生效；done/unknown 已在 activity() 里归为 idle。
    public static func describe(kind: ActivityKind, since: Date?, now: Date) -> String {
        switch kind {
        case .offline: return KitL10n.string("离线")
        case .waiting: return AgentStatus.blocked.label
        case .working:
            guard let since else { return AgentStatus.working.label }
            return workingLine(seconds: Int(now.timeIntervalSince(since)))
        case .idle: return AgentStatus.idle.label
        }
    }
}

#if canImport(SwiftUI)
/// 状态小点：工作中为呼吸的强调色点（减少动态效果时改为静态双环），空闲为 ok 色、等你为 warn 色、离线为灰色空心。
/// 颜色由调用方注入（两端传 PalmhelmTheme）；默认系统色，Kit 本身不持有主题。只表达状态，文字由 describe() 给出。
public struct ActivityDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let kind: ActivityKind
    let size: CGFloat
    let accent: Color
    let ok: Color
    let warn: Color

    public init(kind: ActivityKind, size: CGFloat = 8, accent: Color = .accentColor, ok: Color = .green, warn: Color = .orange) {
        self.kind = kind
        self.size = size
        self.accent = accent
        self.ok = ok
        self.warn = warn
    }

    public var body: some View {
        Group {
            switch kind {
            case .working:
                if reduce {
                    ZStack {
                        Circle().strokeBorder(accent, lineWidth: 1.5)
                        Circle().fill(accent).frame(width: size * 0.5, height: size * 0.5)
                    }
                } else {
                    // 呼吸交给图层动画（BreathingDot）：SwiftUI 的 repeatForever 会让宿主视图每帧求值（O1-337）。
                    BreathingDot(color: accent, size: size, breathing: true)
                }
            case .idle:
                Circle().fill(ok)
            case .waiting:
                Circle().fill(warn)
            case .offline:
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(ThreadActivity.describe(kind: kind, since: nil, now: Date()))
    }
}
#endif
