import Foundation

// 账户额度的显示规则（Mac 与 iOS 共用）：只显示已确认的真实窗口；默认选中「已用百分比最高」的有效订阅账户；选择按 provider + accountId 保持。
// 纯函数，不碰网络与存储。

/// 真实窗口白名单：Codex 5 小时 / 7 天；Claude 5 小时 / 7 天 / Fable·7 天。Opus / Sonnet 目前没有独立额度，不显示。
public enum QuotaWindowPolicy {
    /// Claude 的窗口 id 形如 five_hour:primary / seven_day:primary（状态行）或 seven_day:fable（OAuth）。按主 id 判定，不接受 seven_day_opus 等。
    public static func claudeAllowed(_ id: String) -> Bool {
        let base = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
        return base == "five_hour" || base == "seven_day" || id == "seven_day:fable"
    }

    public static func allowed(provider: String, _ w: AccountWindow) -> Bool {
        switch provider {
        case "codex": return w.windowMins == 300 || w.windowMins == 10080
        case "claude": return claudeAllowed(w.id)
        case "qoder": return w.id == "credits" || w.id == "addon"
        case "agy": return w.id == "gemini-5h" || w.id == "gemini-weekly" || w.id == "3p-5h" || w.id == "3p-weekly"
        default: return false
        }
    }

    /// 账户的可显示窗口（白名单内、按出现顺序去重）。
    public static func windows(of a: AccountSnapshot) -> [AccountWindow] {
        var seen = Set<String>()
        return (a.windows ?? []).filter { allowed(provider: a.provider, $0) && seen.insert($0.id).inserted }
    }
}

public enum AccountSelection {
    /// 稳定键：provider + accountId（不因 label 变化或数组重排而变）。
    public static func key(_ a: AccountSnapshot) -> String { a.provider + "|" + a.accountId }

    /// 默认选中：有效订阅读数（ok 且有未重置的可显示窗口）里，已用百分比最高的那个账户；
    /// 重置 / 失败 / 未知 / API（无订阅窗口）不参与；百分比相等按稳定键决胜。
    public static func tightest(_ accounts: [AccountSnapshot], now: Date) -> AccountSnapshot? {
        let candidates: [(AccountSnapshot, Double)] = accounts.compactMap { a in
            guard a.status == "ok" else { return nil }
            let live = QuotaWindowPolicy.windows(of: a).filter { !QuotaCopy.windowExpired($0, now: now) && $0.usedPercent != nil }
            guard let top = live.compactMap(\.usedPercent).max() else { return nil }
            return (a, top)
        }
        return candidates.min { x, y in x.1 != y.1 ? x.1 > y.1 : key(x.0) < key(y.0) }?.0
    }

    /// 实际显示的账户：保存的选择仍在列表里就沿用，否则回到默认（最紧），再不行取第一个。
    public static func resolve(selectedKey: String?, accounts: [AccountSnapshot], now: Date) -> AccountSnapshot? {
        if let k = selectedKey, let a = accounts.first(where: { key($0) == k }) { return a }
        return tightest(accounts, now: now) ?? accounts.first
    }
}
