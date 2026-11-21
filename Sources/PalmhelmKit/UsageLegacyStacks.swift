import Foundation

/// 旧口径（旧版 Bridge / 估价版本不支持）的堆叠数据（O1-359）：Mac 的 Legacy 图只消费这里的纯数据。
/// 身份用系列序号（0…2 为具名模型，3 为其他），不用显示名：显示名可以与任何模型重名（含中文「其他」），不能作身份。
/// 服务端的 `other` 聚合键永远归入其他，不占具名位置；每个桶的总量与所选 kinds 的全部 token 守恒。
public enum UsageLegacyStacks {
    public static let namedLimit = 3
    public static let aggregateIndex = 3

    /// 具名模型的排序：按所选 kinds 的总量从大到小，平局按名称（与 UsageChartData 同口径）。
    public struct Plan: Equatable, Sendable {
        public let named: [String]
        /// 有任何进入其他的数据（超出前三的模型，或服务端的 other 聚合）。
        public let hasAggregate: Bool
    }

    /// 一根柱的一段：桶起点、系列序号（0…2 具名，3 其他）、token 数。
    public struct Stack: Equatable, Sendable, Identifiable {
        public let t: Int
        public let index: Int
        public let tokens: Int
        public var id: String { "\(t)-\(index)" }
    }

    /// 完整明细的一行（所有模型，不因图表合并而丢失）。index 为具名序号；聚合键与超出前三的模型为 aggregateIndex。
    public struct ModelTotal: Equatable, Sendable, Identifiable {
        public let model: String
        public let total: Int
        public let index: Int
        public let isAggregateKey: Bool
        public var id: String { model }
    }

    public static func plan(_ buckets: [UsageBucket], kinds: Set<TokenKind>) -> Plan {
        var totals: [String: Int] = [:]
        for b in buckets { for (m, t) in b.byModel where m != UsageChartData.otherKey { totals[m, default: 0] += t.total(kinds) } }
        let ranked = totals.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let named = Array(ranked.prefix(namedLimit))
        let aggregateKeyHasTokens = buckets.contains { ($0.byModel[UsageChartData.otherKey]?.total(kinds) ?? 0) > 0 }
        return Plan(named: named, hasAggregate: ranked.count > named.count || aggregateKeyHasTokens)
    }

    /// 逐桶的堆叠段（只含 tokens > 0 的段）。各桶的段之和等于该桶所有模型的 token 之和。
    public static func stacks(_ buckets: [UsageBucket], plan: Plan, kinds: Set<TokenKind>) -> [Stack] {
        buckets.flatMap { b -> [Stack] in
            var sums = [Int](repeating: 0, count: namedLimit + 1)
            for (m, t) in b.byModel {
                let v = t.total(kinds)
                if m != UsageChartData.otherKey, let i = plan.named.firstIndex(of: m) { sums[i] += v } else { sums[aggregateIndex] += v }
            }
            return sums.enumerated().compactMap { i, v in v > 0 ? Stack(t: b.t, index: i, tokens: v) : nil }
        }
    }

    /// 所有模型的明细（不合并），按总量从大到小，平局按名称。
    public static func modelTotals(_ buckets: [UsageBucket], plan: Plan, kinds: Set<TokenKind>) -> [ModelTotal] {
        var totals: [String: Int] = [:]
        for b in buckets { for (m, t) in b.byModel { totals[m, default: 0] += t.total(kinds) } }
        return totals.filter { $0.value > 0 }
            .map { m, v -> ModelTotal in
                let idx = m == UsageChartData.otherKey ? aggregateIndex : (plan.named.firstIndex(of: m) ?? aggregateIndex)
                return ModelTotal(model: m, total: v, index: idx, isAggregateKey: m == UsageChartData.otherKey)
            }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.model < $1.model }
    }
}
