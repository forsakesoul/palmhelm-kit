import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct ApprovalDisplayTests {
    private func en<T>(_ b: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "en"), operation: b) }

    @Test func detailDecodesSpansAndDisplaysEnglishWithoutTouchingTheOriginal() throws {
        let json = #"""
        {"approval":{"view":{"id":"a1","status":"pending","targetLabel":"t","toolName":"Bash","summary":"curl （链接） 路径 ‹路径›","truncated":false,"createdT":1,"expiresT":2,
          "summaryDisplaySpans":[{"startUTF16":5,"endUTF16":9,"key":"link"},{"startUTF16":13,"endUTF16":17,"key":"path"}]},
         "body":{"plan":"（内容已隐藏）","planDisplaySpans":[{"startUTF16":0,"endUTF16":7,"key":"hidden"}],
           "questions":[{"header":"h","question":"选（图片）？","questionDisplaySpans":[{"startUTF16":1,"endUTF16":5,"key":"image"}],"multiSelect":false,
             "options":[{"label":"（链接）","description":"d","selectable":true,"labelDisplaySpans":[{"startUTF16":0,"endUTF16":4,"key":"link"}]}]}],
           "change":{"path":"‹路径›","kind":"edit","hunks":[],"more":0,"truncated":false,"pathDisplaySpans":[{"startUTF16":0,"endUTF16":4,"key":"path"}]}}}}
        """#
        let d = try JSONDecoder().decode(ApprovalDetailResponse.self, from: Data(json.utf8)).approval
        #expect(en { d.view.summaryDisplayed } == "curl (link) 路径 ‹path›")
        #expect(d.view.summary == "curl （链接） 路径 ‹路径›")
        let q = try #require(d.body?.questions?.first)
        #expect(en { q.questionDisplayed } == "选(image)？")
        #expect(en { q.options[0].labelDisplayed } == "(link)")
        #expect(en { d.body?.planDisplayed } == "(content hidden)")
        #expect(en { d.body?.change?.pathDisplayed } == "‹path›")
        // 原字段（digest/动作依据）不变
        #expect(q.question == "选（图片）？")
    }

    @Test func missingSpansAndUserLiteralsStayVerbatim() throws {
        let v = try JSONDecoder().decode(ApprovalView.self, from: Data(#"{"id":"a","status":"pending","targetLabel":"t","toolName":"Bash","summary":"用户写（链接）","truncated":false,"createdT":1,"expiresT":2}"#.utf8))
        #expect(en { v.summaryDisplayed } == "用户写（链接）")
        let missing = ApprovalBody(plan: "此请求未附计划正文，请回终端核对")
        #expect(en { missing.planDisplayed == ApprovalText.planText("此请求未附计划正文，请回终端核对") })
    }
}

@Suite struct IssuePlaceholderTests {
    private func en<T>(_ b: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "en"), operation: b) }
    @Test func sensitivePlaceholdersAreLocalizedAndRealValuesKept() throws {
        let t = try JSONDecoder().decode(IssueTaskTarget.self, from: Data(#"{"targetId":"t","label":"（名称已隐藏）","labelPlaceholder":"sensitive","destinationVersion":"v"}"#.utf8))
        #expect(en { t.displayLabel } == "(hidden)")
        let d = try JSONDecoder().decode(IssueTaskDetail.self, from: Data(#"{"number":1,"title":"（内容已隐藏）","titlePlaceholder":"sensitive","state":"open","updatedAt":"x","url":"u","body":"真实正文","sourceVersion":"s"}"#.utf8))
        #expect(en { d.displayTitle } == "(hidden)")
        #expect(d.displayBody == "真实正文")
        #expect(d.title == "（内容已隐藏）") // 原值仍在，不当作可派发内容
        let plain = try JSONDecoder().decode(IssueTaskListItem.self, from: Data(#"{"number":2,"title":"（内容已隐藏）","state":"open","updatedAt":"x","url":"u"}"#.utf8))
        #expect(en { plain.displayTitle } == "（内容已隐藏）") // 用户字面同句不换
    }
}


@Suite struct FixedSummaryTests {
    private func en<T>(_ b: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "en"), operation: b) }
    private func view(_ kind: String, _ summary: String, count: Int? = nil) throws -> ApprovalView {
        let c = count.map { ",\"questionCount\":\($0)" } ?? ""
        return try JSONDecoder().decode(ApprovalView.self, from: Data(#"{"id":"a","status":"pending","targetLabel":"t","toolName":"x","summary":"\#(summary)","truncated":false,"createdT":1,"expiresT":2,"kind":"\#(kind)"\#(c)}"#.utf8))
    }
    @Test func questionAndPlanSummariesLocalizeBySemantics() throws {
        #expect(en { (try! view("question", "提问（3 题）", count: 3)).summaryDisplayed } == "Question (3)")
        #expect(en { (try! view("plan", "计划（可打回，不能经钩子批准）")).summaryDisplayed } == "Plan (can be sent back; cannot be approved through the hook)")
    }
    @Test func customOrMismatchedSummariesAreUntouched() throws {
        #expect(en { (try! view("question", "提问（3 题）", count: 2)).summaryDisplayed } == "提问（3 题）")   // 题数对不上：不是 Bridge 生成
        #expect(en { (try! view("approval", "提问（3 题）", count: 3)).summaryDisplayed } == "提问（3 题）")   // 种类不符
        #expect(en { (try! view("approval", "运行 ls")).summaryDisplayed } == "运行 ls")
    }
}

@Suite struct ContextSpansTests {
    private func en<T>(_ b: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "en"), operation: b) }
    @Test func previewHunksCauseAndSnippetUseTheirOwnSpans() throws {
        let opt = try JSONDecoder().decode(ProjectedOption.self, from: Data(#"{"label":"l","description":"d","preview":"见（链接）","selectable":true,"previewDisplaySpans":[{"startUTF16":1,"endUTF16":5,"key":"link"}]}"#.utf8))
        #expect(en { opt.previewDisplayed } == "见(link)")
        let h = try JSONDecoder().decode(ApprovalHunk.self, from: Data(#"{"old":"‹路径›","new":"（内容已隐藏）","oldDisplaySpans":[{"startUTF16":0,"endUTF16":4,"key":"path"}],"newDisplaySpans":[{"startUTF16":0,"endUTF16":7,"key":"hidden"}]}"#.utf8))
        #expect(en { h.oldDisplayed } == "‹path›" && en { h.newDisplayed } == "(content hidden)")
        let cause = try JSONDecoder().decode(ApprovalCause.self, from: Data(#"{"status":"ok","prompt":{"text":"（图片）","origin":"terminal","textDisplaySpans":[{"startUTF16":0,"endUTF16":4,"key":"image"}]},"note":{"text":"x（链接）","truncated":false,"textDisplaySpans":[{"startUTF16":1,"endUTF16":5,"key":"link"}]}}"#.utf8))
        #expect(en { cause.prompt?.textDisplayed } == "(image)" && en { cause.note?.textDisplayed } == "x(link)")
        // 无字段：原样
        #expect(en { (try! JSONDecoder().decode(ApprovalHunk.self, from: Data(#"{"new":"（链接）"}"#.utf8))).newDisplayed } == "（链接）")
    }

    @Test func snippetHighlightMapsAroundAtomsAndDropsSplitHits() throws {
        let hit = try JSONDecoder().decode(SearchHit.self, from: Data(#"{"targetId":"t","itemId":"i","sessionEpoch":"e","role":"assistant","snippet":"…（链接）target","ranges":[[5,6]],"snippetDisplaySpans":[{"startUTF16":1,"endUTF16":5,"key":"link"}]}"#.utf8))
        #expect(en { hit.snippetDisplayed.text } == "…(link)target")
        let shown = en { SearchText.highlighted(hit: hit) }
        let marked = shown.runs.filter { $0.backgroundColor != nil }.map { String(shown[$0.range].characters) }
        #expect(marked == ["target"])
        let split = try JSONDecoder().decode(SearchHit.self, from: Data(#"{"targetId":"t","itemId":"i","sessionEpoch":"e","role":"assistant","snippet":"…（链接）target","ranges":[[2,2]],"snippetDisplaySpans":[{"startUTF16":1,"endUTF16":5,"key":"link"}]}"#.utf8))
        #expect(en { SearchText.highlighted(hit: split) }.runs.allSatisfy { $0.backgroundColor == nil })
    }
}

@Suite struct LocalOutputShapesTests {
    private func en(_ raw: String, _ spans: [DisplaySpan]) -> String { KitL10n.$locale.withValue(Locale(identifier: "en")) { BridgeDisplayText.render(raw, spans: spans).text } }
    @Test func commandStdoutStderrAndEmptyShapes() {
        #expect(en("终端本地命令：ls", [DisplaySpan(startUTF16: 0, endUTF16: 7, key: "local_command")]) == "Local terminal command:ls")
        #expect(en("终端本地输出：hello", [DisplaySpan(startUTF16: 0, endUTF16: 6, key: "local_stdout")]) == "Local terminal output：hello")
        #expect(en("终端本地错误输出：boom", [DisplaySpan(startUTF16: 0, endUTF16: 8, key: "local_stderr")]) == "Local terminal error output：boom")
        #expect(en("终端本地输出（无内容）", [DisplaySpan(startUTF16: 0, endUTF16: 6, key: "local_stdout"), DisplaySpan(startUTF16: 6, endUTF16: 11, key: "empty")]) == "Local terminal output(empty)")
        // 范围把冒号也包进去（旧形状）会被拒绝：冒号不属于标签
        #expect(en("终端本地输出：hello", [DisplaySpan(startUTF16: 0, endUTF16: 7, key: "local_stdout")]) == "终端本地输出：hello")
    }
}
