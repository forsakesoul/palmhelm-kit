import XCTest
@testable import PalmhelmKit

final class QuestionTests: XCTestCase {
    private let detailJSON = #"""
    {"approval":{"view":{"id":"a1","status":"pending","targetLabel":"p","toolName":"AskUserQuestion","summary":"2 个问题","truncated":false,"createdT":1,"expiresT":9999999999999,"kind":"question","questionCount":2},
     "body":{"questions":[
       {"header":"修法","question":"用哪种？","multiSelect":false,"options":[{"label":"改起点","description":"d","preview":"code","selectable":true},{"label":"‹已隐藏›","description":"","selectable":false}]},
       {"header":"范围","question":"补哪些？","multiSelect":true,"options":[{"label":"规则","description":"","selectable":true},{"label":"原因","description":"","selectable":true}]}]}}}
    """#

    func testDetailDecodesAndKindIsQuestion() throws {
        let d = try JSONDecoder().decode(ApprovalDetailResponse.self, from: Data(detailJSON.utf8)).approval
        XCTAssertEqual(d.view.pendingKind, .question)
        XCTAssertEqual(d.body?.questions?.count, 2)
        XCTAssertEqual(d.body?.questions?[0].options[1].selectable, false)
        let old = #"{"id":"x","status":"pending","targetLabel":"p","toolName":"Bash","summary":"ls","truncated":false,"createdT":1,"expiresT":2}"#
        XCTAssertEqual(try JSONDecoder().decode(ApprovalView.self, from: Data(old.utf8)).pendingKind, .approval, "旧 Bridge 没有 kind 按审批")
    }

    func testDraftRulesAndEncoding() throws {
        let qs = try JSONDecoder().decode(ApprovalDetailResponse.self, from: Data(detailJSON.utf8)).approval.body!.questions!
        var d = QuestionDraft(qs)
        XCTAssertNil(d.answers, "未答完不能提交")
        d.toggle(question: 0, option: 1)
        XCTAssertTrue(d.selected[0].isEmpty, "不可选的选项点了没用")
        d.toggle(question: 0, option: 0); d.toggle(question: 0, option: 0)
        XCTAssertEqual(d.selected[0], [0], "单选再点仍是一项")
        d.toggle(question: 1, option: 1); d.toggle(question: 1, option: 0)
        XCTAssertEqual(d.selected[1], [0, 1])
        d.setText(question: 1, "都要")
        XCTAssertTrue(d.selected[1].isEmpty, "写了自由文本就清掉选项")
        let data = try JSONEncoder().encode(d.answers!)
        let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertEqual(arr[0]["option"] as? [Int], [0])
        XCTAssertEqual(arr[1]["text"] as? String, "都要")
        XCTAssertNil(arr[1]["option"])
        d.setText(question: 1, String(repeating: "长", count: 501))
        XCTAssertNil(d.answers, "超过上限不提交")
    }
}
