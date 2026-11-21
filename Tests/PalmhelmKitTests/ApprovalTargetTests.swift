import XCTest
@testable import PalmhelmKit

final class ApprovalTargetTests: XCTestCase {
    private let targets = [TargetSummary(projectName: "same", targetId: "design"), TargetSummary(projectName: "same", targetId: "execute")]
    private func approval(id: String? = nil, label: String = "same", attribution: String = "exact") -> ApprovalView {
        ApprovalView(id: "a", status: "pending", targetLabel: label, attribution: attribution, toolName: "Bash", summary: "ls", createdT: 0, expiresT: 1000, targetId: id)
    }
    func testExactIDDisambiguatesSameProjectAndMissingIDDoesNotFallThrough() {
        XCTAssertEqual(ApprovalText.target(of: approval(id: "execute"), in: targets)?.id, "execute")
        XCTAssertNil(ApprovalText.target(of: approval(id: "gone"), in: targets))
        XCTAssertNil(ApprovalText.target(of: approval(), in: targets))
    }
    func testLegacyAndCandidateRequireUniqueLabelAndDoNotTrustCandidateID() {
        let unique = Array(targets.prefix(1))
        XCTAssertEqual(ApprovalText.target(of: approval(), in: unique)?.id, "design")
        XCTAssertEqual(ApprovalText.target(of: approval(id: "execute", label: "候选：same", attribution: "candidate"), in: unique)?.id, "design")
        XCTAssertNil(ApprovalText.target(of: approval(label: "other"), in: unique))
    }
    func testOptionalTargetIDDecodesWithoutBreakingOldPayloads() throws {
        let old = #"{"id":"a","status":"pending","targetLabel":"same","attribution":"exact","toolName":"Bash","summary":"ls","truncated":false,"createdT":0,"expiresT":1000}"#
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(ApprovalView.self, from: Data(old.utf8)).targetId)
        let new = old.dropLast() + #","targetId":"execute"}"#
        XCTAssertEqual(try decoder.decode(ApprovalView.self, from: Data(new.utf8)).targetId, "execute")
    }
}
