import Foundation

/// 会话记录线程的固定文案（两端一致；设计稿 T2a_Thread / T2a_States）。
public enum TranscriptCopy {
    public static var loadOlder: String { KitL10n.string("上滑加载更早的 20 条") }
    public static var loadingOlder: String { KitL10n.string("正在加载更早的记录…") }
    public static var typedInTerminal: String { KitL10n.string("在终端输入") }
    public static var unavailableTitle: String { KitL10n.string("读不到这个 agent 的会话记录") }
    public static var unavailableBody: String { KitL10n.string("只显示经 Palmhelm / 飞书发的消息与回执。可能是 agent 版本的记录格式变了，或这个窗格没有会话文件。") }
    public static var failedTitle: String { KitL10n.string("暂时读不到会话记录") }
    /// 超过上限的单条消息（gap 的 reason 为 oversized_record）：未显示，不展示内容（W2-137）。
    public static var oversizedGap: String { KitL10n.string("这条消息过大，未显示") }

    /// gap 行的文案：超大记录用专门的说明，其余 gap 沿用服务端给出的文本。
    public static func gapText(_ item: TranscriptItem) -> String {
        if item.reason == "oversized_record" { return oversizedGap }
        if let m = item.displayMessage?.value, !KitL10n.isChinese, let s = BridgeDisplayMessage.text(m) { return s }
        return item.text
    }
    public static var ownerMismatchTitle: String { KitL10n.string("会话记录与这个窗格不匹配") }
    public static var ownerMismatchBody: String { KitL10n.string("Herdr 记录的会话属于另一个目录，为避免显示其他项目的对话已隐藏。在这个窗格重启 agent 后通常会恢复。") }

    /// 不可用卡片的标题与说明（#99 S2）：Bridge 给出的固定原因各有一条说明与建议；缺失与未知值沿用通用文案。
    /// 不在此表中的原因（如仅用于统计的 format_unrecognized）不会出现在应答里，因此也沿用通用文案。
    public static func unavailableCopy(reason: String?) -> (title: String, body: String) {
        guard let reason, let copy = reasonCopy[reason] else { return (unavailableTitle, unavailableBody) }
        return copy
    }

    private static var reasonCopy: [String: (title: String, body: String)] { [
        "owner_mismatch": (ownerMismatchTitle, ownerMismatchBody),
        "no_session": (KitL10n.string("这个窗格还没有会话记录"), KitL10n.string("agent 还没有产生可读的会话文件。在窗格里发一条消息后再看。")),
        "provider_unsupported": (KitL10n.string("这种 agent 暂不支持读取会话记录"), KitL10n.string("当前版本没有这类 agent 的读取规则。升级 Palmhelm 后再看。")),
        "session_id_unrecognized": (KitL10n.string("会话标识与预期不符"), KitL10n.string("Herdr 报告的会话标识格式已变化，无法定位文件。升级 Palmhelm；或在窗格重启 agent 后再试。")),
        "file_missing": (KitL10n.string("没找到这个窗格的会话文件"), KitL10n.string("会话文件可能被移动，或 agent 尚未写入。确认 agent 仍在运行；必要时重启 agent。")),
        "locate_budget_exceeded": (KitL10n.string("查找会话文件超时"), KitL10n.string("目录较多，查找在时限内没有完成。稍后重试。")),
        "no_window_cwd": (KitL10n.string("这个窗格还没有报告目录"), KitL10n.string("Herdr 还没有识别窗格的工作目录，无法核对会话。稍等片刻后下拉刷新。")),
        "start_cwd_missing": (KitL10n.string("会话文件开头缺少目录信息"), KitL10n.string("无法确认会话属于这个窗格，已隐藏。agent 版本可能已变化；升级 Palmhelm 后再看。")),
        "unproven_start": (KitL10n.string("无法确认会话属于这个窗格"), KitL10n.string("为避免显示其他项目的对话，已隐藏。在窗格重启 agent 后再试。")),
        "file_unreadable": (KitL10n.string("无法读取会话文件"), KitL10n.string("文件权限或位置异常。检查该 agent 的会话目录权限后重试。")),
        "io_error": (KitL10n.string("读取会话文件失败"), KitL10n.string("本次读取出错。稍后下拉刷新。")),
        "file_changed": (KitL10n.string("会话文件刚被更新"), KitL10n.string("读取已丢弃，避免混入旧内容。下拉刷新。")),
        "identity_changed": (KitL10n.string("窗格刚切换了 agent"), KitL10n.string("读取已丢弃。下拉刷新。")),
        "identity_unverified": (KitL10n.string("暂时无法核对这个窗格的 agent"), KitL10n.string("Herdr 响应慢或不一致。稍后重试。")),
        "agent_absent": (KitL10n.string("这个窗格的 agent 已不在线"), KitL10n.string("窗格可能已关闭或 agent 已退出。回到列表确认窗格状态。")),
        "leaf_unresolved": (KitL10n.string("无法判定这段会话的最新位置"), KitL10n.string("记录格式可能已变化，为避免显示错误内容已隐藏。升级 Palmhelm；反馈后补规则。")),
        "budget_exceeded": (KitL10n.string("会话文件较大，本次读取超时"), KitL10n.string("读取在时限内没有完成。稍后重试。")),
    ] }

    /// 翻到顶：“已到本次会话开头 · 今天 10:42”（无时间时只有前半句）。
    public static func startMarker(firstT: Int?, now: Date = Date()) -> String {
        guard let firstT else { return KitL10n.string("已到本次会话开头") }
        return KitL10n.string("已到本次会话开头 · ") + time(firstT, now: now)
    }

    /// 用户消息下方的唯一一行：「经 Palmhelm · 状态 · 时间」（状态来自 OutgoingStatus，两端同一文案）；其余为终端直接输入。
    /// `command`：与回执 eventKey 精确相等的本机权威指令（没有或不相等 = 未关联，done 显示「结果未知」）。
    /// `resolvedStatus`：父级已按 tracker 解析的状态文案（优先于本函数自行求值）；`showsStatus` 为假时省略状态（同一状态已由旁边的排队卡表达，不重复）。
    public static func sourceLine(_ item: TranscriptItem, agentWorking: Bool = false, command: ApiCommand? = nil, resolvedStatus: String? = nil, showsStatus: Bool = true,
                                  now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
        var parts: [String] = []
        if let r = item.receipt {
            parts.append(r.origin == InboundOrigin.feishu.rawValue ? KitL10n.string("经飞书") : KitL10n.string("经 Palmhelm"))
            let linked = r.eventKey != nil && command?.key == r.eventKey ? command : nil
            // 父级已解析的状态 / 省略请求只在 command 与回执 eventKey 精确相等时才采用；否则忽略，沿原中性求值（共同 Interface 自己守住关联，不靠调用方）。
            let exact = linked != nil
            if showsStatus || !exact {
                parts.append((exact ? resolvedStatus : nil) ?? OutgoingStatus.label(OutgoingStatus.phase(.fromReceipt(r, agentWorking: agentWorking, command: linked)), locale: locale))
            }
        } else {
            parts.append(typedInTerminal)
        }
        if let t = item.t { parts.append(time(t, now: now)) }
        return parts.joined(separator: " · ")
    }

    /// 同一天只给时刻，否则带日期。
    public static func time(_ ms: Int, now: Date = Date()) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let sameDay = Calendar.current.isDate(d, inSameDayAs: now)
        return sameDay ? KitL10n.string("今天 ") + KitL10n.formatted(d, time: .shortened) : KitL10n.formatted(d, date: .abbreviated, time: .shortened)
    }
}
