import Foundation

/// 输入区上方的一行提示：说明“这次发送会怎样”（#101，设计 12 第 2 节）。
/// 判定只看发送方式与待答数，不新造规则；文案与阈值只在这里。
public enum ThreadSendHint: Equatable, Sendable {
    /// 直达、agent 工作中且原生插话可用：直接插入当前回合。
    case directInsert
    /// 会排队到本轮结束后发送；ahead 为前面还有几条。
    case queued(ahead: Int)
    /// 有待答（审批或提问），在「等待」页处理。
    case pendingAnswers(Int)
}

public enum ThreadSendHintRules {
    /// 提示由实际发送用的 mode 派生（与主按钮 submit(mode:) 同一个值，见 SendTimingRules.primaryMode）：
    /// .steer → 直接插入；.queue → 排队（queuedAhead 只数真正仍在排队的条目）；其它 mode 不提示。
    /// 没有发送方式提示时，若有待答则显示待答；都没有则不显示。不在这里另写条件。
    public static func hint(mode: SendMode?, queuedAhead: Int, pendingAnswers: Int) -> ThreadSendHint? {
        switch mode {
        case .steer?: return .directInsert
        case .queue?: return .queued(ahead: max(0, queuedAhead))
        default: return pendingAnswers > 0 ? .pendingAnswers(pendingAnswers) : nil
        }
    }

    /// 前面还有几条真正仍在排队（待发送）的消息：只数 state == queued，且不计已结束的原因（撤回、并入、过期、直达插话的终态）。
    /// 不复用 SendTimingRules.isQueuedFamily：那是状态行的展示族，包含已经结束的记录。
    public static func queuedAhead(_ commands: [ApiCommand]) -> Int {
        let ended: Set<String> = ["withdrawn", "merged", "native_delivered", "queue_expired", "queue_expired_uncertain", "native_send_now_requested", "native_send_now_skipped"]
        return commands.filter { $0.state == CommandState.queued.rawValue && !ended.contains($0.reason ?? "") }.count
    }

    public static func text(_ hint: ThreadSendHint, agentName: String) -> String {
        switch hint {
        case .directInsert:
            return KitL10n.format("↳ 直接插入当前回合 · %@ 正在工作", agentName)
        case .queued(let ahead):
            return ahead > 0 ? KitL10n.format("⏱ 排到本轮结束后发送 · 前面还有 %lld 条", ahead) : KitL10n.string("⏱ 排到本轮结束后发送")
        case .pendingAnswers(let n):
            return KitL10n.format("有 %lld 条待答，在「等待」页处理", n)
        }
    }
}
