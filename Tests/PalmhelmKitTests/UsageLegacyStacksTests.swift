import Testing
import Foundation
@testable import PalmhelmKit

// O1-359 R1：旧口径堆叠的真实 seam（Mac Legacy 图只消费它）：服务端 other 永远归其他；同名「其他」不重复；
// 超过三个模型逐桶守恒；明细保留全部模型；kinds 切换一致。
@Suite struct UsageLegacyStacksTests {
    private func tok(_ v: Int) -> UsageTokens { UsageTokens(input: v) }
    private func bucket(_ t: Int, _ models: [String: Int]) -> UsageBucket {
        UsageBucket(t: t, date: nil, byModel: models.mapValues(tok))
    }
    private var all: Set<TokenKind> { Set(TokenKind.allCases) }
    private func perBucketTotals(_ stacks: [UsageLegacyStacks.Stack]) -> [Int: Int] {
        Dictionary(grouping: stacks, by: \.t).mapValues { $0.reduce(0) { $0 + $1.tokens } }
    }

    @Test func serverOtherAggregateNeverTakesANamedSlot() {
        let b = [bucket(1, ["other": 1000, "a": 100, "b": 80, "c": 50, "d": 5])]
        let plan = UsageLegacyStacks.plan(b, kinds: all)
        #expect(plan.named == ["a", "b", "c"], "服务端 other 不进前三")
        let stacks = UsageLegacyStacks.stacks(b, plan: plan, kinds: all)
        let aggregate = stacks.filter { $0.index == UsageLegacyStacks.aggregateIndex }.reduce(0) { $0 + $1.tokens }
        #expect(aggregate == 1005, "other 与尾部模型都进其他灰")
        #expect(perBucketTotals(stacks) == [1: 1235], "逐桶守恒")
    }

    @Test func displayNamedOtherIsARealModelNotTheAggregate() {
        // 模型名恰为「其他」：它是真实模型，必须按身份计入具名位置，不能与聚合混为一段
        let b = [bucket(1, ["其他": 100, "a": 90, "b": 80, "c": 70, "d": 10])]
        let plan = UsageLegacyStacks.plan(b, kinds: all)
        #expect(plan.named == ["其他", "a", "b"])
        let stacks = UsageLegacyStacks.stacks(b, plan: plan, kinds: all)
        #expect(stacks.first { $0.index == 0 }?.tokens == 100, "同名的「其他」模型占自己的具名位置")
        #expect(stacks.first { $0.index == UsageLegacyStacks.aggregateIndex }?.tokens == 80, "尾部 c、d 合为聚合（70 + 10）")
        #expect(perBucketTotals(stacks) == [1: 350], "同名不重复计数")
    }

    @Test func realOtherModelBelowTheTopThreeGoesToAggregate() {
        let b = [bucket(1, ["a": 90, "b": 80, "c": 70, "其他": 5, "d": 10])]
        let plan = UsageLegacyStacks.plan(b, kinds: all)
        let stacks = UsageLegacyStacks.stacks(b, plan: plan, kinds: all)
        #expect(stacks.first { $0.index == UsageLegacyStacks.aggregateIndex }?.tokens == 15)
        #expect(perBucketTotals(stacks) == [1: 255])
    }

    @Test func manyBucketsAndManyModelsStayConserved() {
        let names = (1...8).map { "m\($0)" }
        let b = (0..<5).map { i in bucket(i, Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, (i + 1) * ($0 + 3)) })) }
        let plan = UsageLegacyStacks.plan(b, kinds: all)
        let stacks = UsageLegacyStacks.stacks(b, plan: plan, kinds: all)
        for (i, bk) in b.enumerated() {
            let want = bk.byModel.values.reduce(0) { $0 + $1.total(all) }
            #expect(perBucketTotals(stacks)[i] == want, "桶 \(i) 守恒")
        }
        #expect(plan.named.count == 3 && plan.hasAggregate)
    }

    @Test func modelDetailKeepsEveryModel() {
        let b = [bucket(1, ["other": 1000, "a": 100, "b": 80, "c": 50, "d": 5, "其他": 3])]
        let plan = UsageLegacyStacks.plan(b, kinds: all)
        let detail = UsageLegacyStacks.modelTotals(b, plan: plan, kinds: all)
        #expect(Set(detail.map(\.model)) == ["other", "a", "b", "c", "d", "其他"], "明细不因图表合并而丢失")
        #expect(detail.first?.model == "other" && detail.first?.isAggregateKey == true)
        #expect(detail.first { $0.model == "d" }?.index == UsageLegacyStacks.aggregateIndex)
        #expect(detail.first { $0.model == "a" }?.index == 0)
    }

    @Test func switchingKindsChangesTotalsAndStaysConserved() {
        let b = [UsageBucket(t: 1, date: nil, byModel: [
            "a": UsageTokens(input: 10, output: 5), "b": UsageTokens(input: 3, cacheRead: 40), "c": UsageTokens(input: 1),
            "d": UsageTokens(input: 2), "other": UsageTokens(input: 9),
        ])]
        for kinds: Set<TokenKind> in [[.input], [.input, .output], all] {
            let plan = UsageLegacyStacks.plan(b, kinds: kinds)
            let stacks = UsageLegacyStacks.stacks(b, plan: plan, kinds: kinds)
            #expect(perBucketTotals(stacks)[1] == b[0].byModel.values.reduce(0) { $0 + $1.total(kinds) }, "\(kinds) 守恒")
        }
    }

    @Test func emptyAndZeroBucketsProduceNoStacks() {
        let b = [bucket(1, [:]), bucket(2, ["a": 0])]
        let plan = UsageLegacyStacks.plan(b, kinds: all)
        #expect(plan.named.isEmpty && !plan.hasAggregate)
        #expect(UsageLegacyStacks.stacks(b, plan: plan, kinds: all).isEmpty)
    }

    @Test func textureTilesAreDistinctPerKind() {
        for k in [UsageSeriesTexture.Kind.diagonal, .dots, .stripes] {
            #expect(UsageSeriesTexture.tile(k, hex: 0x245AC7, size: 8) != nil, "\(k) 瓦片可生成")
        }
        #expect(UsageSeriesTexture.kind(0) == .solid && UsageSeriesTexture.kind(1) == .diagonal && UsageSeriesTexture.kind(2) == .dots && UsageSeriesTexture.kind(3) == .stripes && UsageSeriesTexture.kind(nil) == .stripes)
    }
}
