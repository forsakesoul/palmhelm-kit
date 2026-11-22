import Foundation
import Testing
@testable import PalmhelmKit

// 打字效果片 2（A1-002 §6.A）：源范围、新块分类、排期、一次准备。
@Suite(.serialized) struct MarkdownBlockRevealTests {
    private func slice(_ text: String, _ r: Range<Int>) -> String {
        let u = Array(text.utf8)
        return String(decoding: u[r], as: UTF8.self)
    }
    private func ranges(_ text: String) -> [Range<Int>] { MarkdownBlock.parseRanged(text).map(\.utf8Range) }
    private func reveal(prefix: Int, start: Double = 1, window: Double = 0.25, gen: Int = 1, style: MarkdownBlockReveal.Style = .brief) -> MarkdownBlockReveal {
        MarkdownBlockReveal(generation: gen, prefixUTF8Count: prefix, startUptime: start, deadlineUptime: start + window, style: style)!
    }
    private func schedule(_ old: String, _ new: String, window: Double = 0.25, style: MarkdownBlockReveal.Style = .brief) -> MarkdownBlockSchedule? {
        MarkdownBlockSchedule(ranges: MarkdownBlock.parseRanged(new).map { Optional($0.utf8Range) }, utf8Count: new.utf8.count,
                              reveal: reveal(prefix: old.utf8.count, window: window, style: style))
    }

    // MARK: 源范围
    @Test func rangesCoverEveryBlockSyntaxAndRepeatedBlocksStayDistinct() {
        let t = "段一\n\n## 标题\n- a\n- b\n\n```swift\nlet x\n```\n| h |\n|---|\n| 1 |\n> q\n\n段一"
        let blocks = MarkdownBlock.parseRanged(t)
        #expect(blocks.map(\.block) == MarkdownBlock.parse(t)) // 块投影与旧 parse 逐项相等
        let covered = blocks.map { slice(t, $0.utf8Range) }
        #expect(covered == ["段一\n", "## 标题\n", "- a\n- b\n", "```swift\nlet x\n```\n", "| h |\n|---|\n| 1 |\n", "> q\n", "段一"])
        #expect(blocks[0].utf8Range != blocks[6].utf8Range) // 重复同文块靠位置区分，不靠字符串查找
    }

    @Test func crlfUnclosedFenceAndMultibyteOffsets() {
        #expect(ranges("a\r\nb") == [0..<4])
        #expect(ranges("前\n```\nraw\n还没闭合").map { slice("前\n```\nraw\n还没闭合", $0) } == ["前\n", "```\nraw\n还没闭合"])
        let t = "👨‍👩‍👧‍👦 e\u{301}\n\n段落"
        #expect(ranges(t).map { slice(t, $0) } == ["👨‍👩‍👧‍👦 e\u{301}\n", "段落"])
        #expect(ranges("") == [])
        #expect(ranges("\n\n") == [])
    }

    @Test func rangesAreOrderedDisjointAndInBoundsForGeneratedDocuments() {
        let pieces = ["", "段", "- 项", "1. 项", "> 引", "# 题", "```", "| a | b |", "|---|---|", "| 1 | 2 |", "  ", "文字\r"]
        var seed = 7
        func next() -> Int { seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff; return seed }
        for _ in 0..<400 {
            let t = (0..<(next() % 9 + 1)).map { _ in pieces[next() % pieces.count] }.joined(separator: "\n")
            let rs = ranges(t)
            var end = 0
            for r in rs { #expect(r.lowerBound >= end && r.upperBound <= t.utf8.count && !r.isEmpty, "\(t.debugDescription)"); end = r.upperBound }
            #expect(MarkdownBlock.parseRanged(t).map(\.block) == MarkdownBlock.parse(t))
        }
    }

    // MARK: 新块分类（只看源范围起点与前缀）
    @Test func prefixBoundariesPickOnlyBlocksStartingAtOrAfterIt() {
        let t = "甲\n\n乙\n\n丙"
        let r = MarkdownBlock.parseRanged(t).map { Optional($0.utf8Range) }
        func fresh(_ prefix: Int) -> [Int]? { MarkdownBlockSchedule(ranges: r, utf8Count: t.utf8.count, reveal: reveal(prefix: prefix))?.slots.map(\.index) }
        #expect(fresh(0) == [0, 1, 2])
        #expect(fresh(r[1]!.lowerBound) == [1, 2])     // 恰好在新块起点
        #expect(fresh(r[1]!.lowerBound + 1) == [2])    // 块内部：该块已被看过
        #expect(fresh(r[2]!.upperBound) == nil)        // 前缀覆盖全部：没有新块 → 直显
    }

    @Test func growthOfSeenBlockNeverReplays() {
        // 同块增长、paragraph→table、未闭合→闭合：旧内容不重新隐藏
        #expect(schedule("段一", "段一继续") == nil)
        #expect(schedule("| a | b |", "| a | b |\n|---|---|\n| 1 | 2 |") == nil)
        #expect(schedule("```\nlet a", "```\nlet a\nlet b\n```") == nil)
        // 初次到来的未闭合代码块整块淡入；其后补正文不重播
        #expect(schedule("段一\n\n", "段一\n\n```\nlet a")?.slots.map(\.index) == [1])
        #expect(schedule("段一\n\n```\nlet a", "段一\n\n```\nlet a\nlet b") == nil)
        // 旧段 + 新标题与新段
        #expect(schedule("段一", "段一\n\n## 标题\n内容")?.slots.map(\.index) == [1, 2])
    }

    @Test func longNewParagraphIsStillOneBlockNotBlockedByCharacterBudgets() {
        let long = String(repeating: "很长的新段落。", count: 300) // >1024 字、>4096 B
        #expect(schedule("段一\n\n", "段一\n\n" + long)?.slots.map(\.index) == [1])
    }

    @Test func invalidOrMissingRangesShowImmediately() {
        let ok: [Range<Int>?] = [0..<2, 2..<4]
        #expect(MarkdownBlockSchedule(ranges: ok, utf8Count: 4, reveal: reveal(prefix: 0)) != nil)
        #expect(MarkdownBlockSchedule(ranges: [0..<2, nil], utf8Count: 4, reveal: reveal(prefix: 0)) == nil)   // 阅读页块没有范围
        #expect(MarkdownBlockSchedule(ranges: [0..<3, 2..<4], utf8Count: 4, reveal: reveal(prefix: 0)) == nil) // 重叠
        #expect(MarkdownBlockSchedule(ranges: [2..<4, 0..<2], utf8Count: 4, reveal: reveal(prefix: 0)) == nil) // 乱序
        #expect(MarkdownBlockSchedule(ranges: [0..<9], utf8Count: 4, reveal: reveal(prefix: 0)) == nil)        // 越界
        #expect(MarkdownBlockSchedule(ranges: [], utf8Count: 0, reveal: reveal(prefix: 0)) == nil)             // N=0
        let reader = PreparedMarkdown(readerBlocks: [.paragraph(ReaderText(AttributedString("x"), offset: 0))], matches: [])
        #expect(MarkdownBlockSchedule(ranges: reader.ranges, utf8Count: 1, reveal: reveal(prefix: 0)) == nil)
    }

    // MARK: 排期
    @Test func blockCountEdgesAndTimings() {
        func rs(_ n: Int) -> [Range<Int>?] { (0..<n).map { Optional($0 * 2..<($0 * 2 + 2)) } }
        func make(_ n: Int, window: Double = 0.25) -> MarkdownBlockSchedule? { MarkdownBlockSchedule(ranges: rs(n), utf8Count: n * 2, reveal: reveal(prefix: 0, window: window)) }
        #expect(make(0) == nil && make(17) == nil)
        let one = make(1)!
        #expect(one.slots == [.init(index: 0, delay: 0, duration: 0.12)])
        let sixteen = make(16)!
        #expect(sixteen.slots.count == 16)
        let last = sixteen.slots.last!
        #expect(last.delay + last.duration <= 0.25 + 1e-9) // 总时长不超窗口
        let two = make(2)!
        #expect(abs(two.slots[1].delay - 0.024) < 1e-9)    // 间隔上限 24ms
        // 窗口缩短：不延长旧 deadline
        let short = make(3, window: 0.10)!
        #expect(short.slots.allSatisfy { abs($0.duration - 0.10) < 1e-9 } && short.slots.allSatisfy { $0.delay == 0 })
        #expect(make(3, window: 1.0 / 24.0 - 0.001) == nil) // 不足一帧 → 全文
        #expect(make(3, window: 1.0 / 24.0) != nil)
    }

    // MARK: arrival 口径（#109）；brief 的全部断言保持不变
    @Test func arrivalAllowsEightHundredMillisecondsAndBriefStillRejectsIt() {
        #expect(MarkdownBlockReveal(generation: 1, prefixUTF8Count: 0, startUptime: 1, deadlineUptime: 1.8, style: .arrival) != nil)
        #expect(MarkdownBlockReveal(generation: 1, prefixUTF8Count: 0, startUptime: 1, deadlineUptime: 1.801, style: .arrival) == nil)
        #expect(MarkdownBlockReveal(generation: 1, prefixUTF8Count: 0, startUptime: 1, deadlineUptime: 1.8) == nil) // 默认仍是 brief
        #expect(MarkdownBlockReveal.Style.brief.maxWindow == MarkdownBlockReveal.maxWindow && MarkdownBlockReveal.maxWindow == 0.250)
        #expect(MarkdownBlockReveal.blockDuration == 0.120 && MarkdownBlockReveal.maxStep == 0.024 && MarkdownBlockReveal.maxNewBlocks == 16)
    }

    @Test func arrivalTimingsAndStep() {
        func rs(_ n: Int) -> [Range<Int>?] { (0..<n).map { Optional($0 * 2..<($0 * 2 + 2)) } }
        func make(_ n: Int, window: Double) -> MarkdownBlockSchedule? {
            MarkdownBlockSchedule(ranges: rs(n), utf8Count: n * 2, reveal: reveal(prefix: 0, window: window, style: .arrival))
        }
        let three = make(3, window: 0.8)!                       // 目标步进 60ms，块 360ms
        #expect(three.slots.map(\.delay).enumerated().allSatisfy { abs($1 - Double($0) * 0.06) < 1e-9 })
        #expect(three.slots.allSatisfy { abs($0.duration - 0.36) < 1e-9 })
        let sixteen = make(16, window: 0.8)!                    // 16 块：窗口内压缩，末块结束不超 800ms
        #expect(sixteen.slots.count == 16)
        let last = sixteen.slots.last!
        #expect(last.delay + last.duration <= 0.8 + 1e-9)
        #expect(sixteen.slots[1].delay < 0.06)                  // 压缩后步进小于目标，不超窗口
        #expect(make(3, window: 1.0 / 24.0 - 0.001) == nil)     // 不足一帧 → 全文
        #expect(make(3, window: 1.0 / 24.0) != nil)
    }

    @Test func arrivalPicksFirstSixteenFreshBlocksButValidatesEveryRange() {
        func rs(_ n: Int) -> [Range<Int>?] { (0..<n).map { Optional($0 * 2..<($0 * 2 + 2)) } }
        let twenty = MarkdownBlockSchedule(ranges: rs(20), utf8Count: 40, reveal: reveal(prefix: 0, window: 0.8, style: .arrival))!
        #expect(twenty.slots.map(\.index) == Array(0..<16))    // 按源顺序前 16 个
        #expect(twenty.slot(for: 16) == nil && twenty.slot(for: 19) == nil) // 其余直显
        #expect(MarkdownBlockSchedule(ranges: rs(17), utf8Count: 34, reveal: reveal(prefix: 0, window: 0.25, style: .brief)) == nil)
        var bad = rs(20); bad[19] = 36..<50                     // 越界尾部：即使前 16 合法也整条直显
        #expect(MarkdownBlockSchedule(ranges: bad, utf8Count: 40, reveal: reveal(prefix: 0, window: 0.8, style: .arrival)) == nil)
        var overlap = rs(18); overlap[17] = 30..<34             // 重叠尾部
        #expect(MarkdownBlockSchedule(ranges: overlap, utf8Count: 36, reveal: reveal(prefix: 0, window: 0.8, style: .arrival)) == nil)
        var missing = rs(18); missing[17] = nil                 // 缺失尾部
        #expect(MarkdownBlockSchedule(ranges: missing, utf8Count: 36, reveal: reveal(prefix: 0, window: 0.8, style: .arrival)) == nil)
    }

    @Test func arrivalKeepsPrefixAndGrowthSemantics() {
        #expect(schedule("段一", "段一继续", style: .arrival) == nil)                                       // 同块增长直显
        #expect(schedule("| a | b |", "| a | b |\n|---|---|\n| 1 | 2 |", style: .arrival) == nil)
        #expect(schedule("段一\n\n```\nlet a", "段一\n\n```\nlet a\nlet b", style: .arrival) == nil)     // 旧块前缀不重播
        #expect(schedule("段一\n\n", "段一\n\n```\nlet a", style: .arrival)?.slots.map(\.index) == [1])
        #expect(schedule("段一", "段一\n\n## 标题\n内容", style: .arrival)?.slots.map(\.index) == [1, 2])
    }

    @Test func arrivalRejectsNonFiniteNegativeAndOverlimitRequests() {
        func make(prefix: Int = 0, start: Double = 1, deadline: Double = 1.8) -> MarkdownBlockReveal? {
            MarkdownBlockReveal(generation: 1, prefixUTF8Count: prefix, startUptime: start, deadlineUptime: deadline, style: .arrival)
        }
        #expect(make(start: .nan) == nil && make(deadline: .infinity) == nil)
        #expect(make(prefix: -1) == nil && make(start: -1, deadline: 0.5) == nil)
        #expect(make(deadline: 1) == nil && make(deadline: 1.801) == nil)
    }

    @Test func revealRequestIsValidated() {
        #expect(MarkdownBlockReveal(generation: 1, prefixUTF8Count: 0, startUptime: 1, deadlineUptime: 1.25) != nil)
        #expect(MarkdownBlockReveal(generation: 1, prefixUTF8Count: 0, startUptime: 1, deadlineUptime: 1.26) == nil)   // 超 250ms
        #expect(MarkdownBlockReveal(generation: 1, prefixUTF8Count: 0, startUptime: 1, deadlineUptime: 1) == nil)
        #expect(MarkdownBlockReveal(generation: 1, prefixUTF8Count: -1, startUptime: 1, deadlineUptime: 1.1) == nil)
        #expect(MarkdownBlockReveal(generation: 1, prefixUTF8Count: 0, startUptime: .nan, deadlineUptime: 1.1) == nil)
        #expect(MarkdownBlockReveal(generation: 1, prefixUTF8Count: 0, startUptime: -1, deadlineUptime: 0.1) == nil)
    }

}

// 诊断计数是进程级全局：与既有准备计数用例同在串行套件里，避免并行互扰。
extension PreparedMarkdownTests {
    @Test func snapshotPreparesOnceAndSharesTheInlineParse() {
        MarkdownDiagnostics.enabled = true; MarkdownDiagnostics.reset()
        defer { MarkdownDiagnostics.enabled = false; MarkdownDiagnostics.reset() }
        let s = MarkdownRenderSnapshot.prepare(text: "普通的一句话。")
        let c = MarkdownDiagnostics.snapshot()
        #expect(c.blockParses == 1 && c.inlineParses == 1)     // 判断“普通段落”与渲染共用这一次，不二次解析
        #expect(s.plainParagraph != nil)
        let table = MarkdownRenderSnapshot.prepare(text: "| a | b |\n|---|---|\n| 1 | 2 |")
        let d = MarkdownDiagnostics.snapshot()
        #expect(d.blockParses == 2 && d.inlineParses == 1 + 4)   // 每个需要的单元格节点各一次，不是整表一次
        #expect(table.plainParagraph == nil)
    }

    @Test func plainParagraphOnlyForOneUnformattedParagraph() {
        func plain(_ t: String) -> Bool { MarkdownRenderSnapshot.prepare(text: t).plainParagraph != nil }
        #expect(plain("普通 text，带标点！") && plain("两行\n还是一段"))
        for rich in ["**粗**", "`行内`", "[链](https://x.y)", "两段\n\n第二段", "- 项", "```\ncode", "# 题", "x &amp; y"] { #expect(!plain(rich), "\(rich)") }
    }

    @Test func snapshotCarriesSameBlocksAndRangesAsTheTextEntry() {
        let t = "段一\n\n## 标题\n内容 **粗**"
        let s = MarkdownRenderSnapshot.prepare(text: t, highlight: nil)
        let direct = PreparedMarkdown(text: t, highlight: nil)
        #expect(s.prepared.blocks.count == direct.blocks.count && s.sourceRanges == direct.ranges)
        #expect(s.text == t && s.highlight == nil)
    }
}
