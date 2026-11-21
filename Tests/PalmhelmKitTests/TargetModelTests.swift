import XCTest
@testable import PalmhelmKit

final class TargetModelTests: XCTestCase {
    private func decode(_ json: String) throws -> TargetSummary {
        try JSONDecoder().decode(TargetSummary.self, from: Data(json.utf8))
    }

    func testDecodesModelWhenPresent() throws {
        let t = try decode(#"{"projectName":"p","id":"t1","model":{"id":"claude-opus-5-5","basis":"last_used"}}"#)
        XCTAssertEqual(t.model, TargetModel(id: "claude-opus-5-5", basis: "last_used"))
        XCTAssertEqual(ModelText.line(t), "最近使用：claude-opus-5-5")
    }

    func testOldBridgeWithoutModelDecodesAsNil() throws {
        let t = try decode(#"{"projectName":"p","id":"t1"}"#)
        XCTAssertNil(t.model)
        XCTAssertNil(ModelText.line(t))
    }

    func testLastConfiguredLabelsAsConfigured() {
        XCTAssertEqual(ModelText.line(TargetModel(id: "gpt-6.1-sol", basis: "last_configured")), "最近配置：gpt-6.1-sol")
    }

    func testUnknownBasisIsNotShownAndDoesNotBreakDecoding() throws {
        let t = try decode(#"{"projectName":"p","id":"t1","model":{"id":"x","basis":"guessed"}}"#)
        XCTAssertEqual(t.projectName, "p", "未知 basis 不能让整条目标解码失败")
        XCTAssertNil(ModelText.line(t))
        XCTAssertNil(ModelText.label(basis: "guessed"))
    }

    func testEmptyIdIsNotShown() {
        XCTAssertNil(ModelText.line(TargetModel(id: "", basis: "last_used")))
    }

    func testEncodingKeepsWireShape() throws {
        let t = TargetSummary(projectName: "p", targetId: "t1", model: TargetModel(id: "m1", basis: "last_used"))
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any]
        XCTAssertEqual((obj?["model"] as? [String: String])?["basis"], "last_used")
    }

    func testThreadLineSaysNotProvidedAndMarksOfflineAsLastRecorded() {
        let t = TargetSummary(projectName: "p", targetId: "t1", model: TargetModel(id: "claude-opus-5-5", basis: "last_used"))
        XCTAssertEqual(ModelText.thread(t, offline: false), "最近使用：claude-opus-5-5")
        XCTAssertEqual(ModelText.thread(t, offline: true), "上次记录 · 最近使用：claude-opus-5-5")
        XCTAssertEqual(ModelText.thread(TargetSummary(projectName: "p"), offline: false), "模型未提供")
        XCTAssertEqual(ModelText.thread(nil, offline: true), "模型未提供")
    }

    func testListShortFormIsBareIdAndOmittedWhenNotShowable() {
        XCTAssertEqual(ModelText.short(TargetSummary(projectName: "p", model: TargetModel(id: "m1", basis: "last_configured"))), "m1")
        XCTAssertNil(ModelText.short(TargetSummary(projectName: "p", model: TargetModel(id: "m1", basis: "guessed"))))
        XCTAssertNil(ModelText.short(TargetSummary(projectName: "p")))
    }

    func testListFormsMarkOfflineForBothBasesAndStayNilWithoutModel() {
        let used = TargetSummary(projectName: "p", model: TargetModel(id: "m1", basis: "last_used"))
        let configured = TargetSummary(projectName: "p", model: TargetModel(id: "m2", basis: "last_configured"))
        XCTAssertEqual(ModelText.short(used, offline: true), "上次记录 m1")
        XCTAssertEqual(ModelText.line(used, offline: true), "上次记录 · 最近使用：m1")
        XCTAssertEqual(ModelText.short(configured, offline: false), "m2")
        XCTAssertEqual(ModelText.line(configured, offline: true), "上次记录 · 最近配置：m2")
        XCTAssertNil(ModelText.short(TargetSummary(projectName: "p"), offline: true))
        XCTAssertNil(ModelText.line(TargetSummary(projectName: "p"), offline: true))
    }
}

extension TargetModelTests {
    func testEffortIsIncludedInThreadListHelpAndSpokenForms() throws {
        for basis in ["last_used", "last_configured"] {
            let t = try decode(#"{"projectName":"p","model":{"id":"model-1","basis":"\#(basis)","effort":"max"}}"#)
            let label = basis == "last_used" ? "最近使用" : "最近配置"
            XCTAssertEqual(ModelText.thread(t, offline: false), "\(label)：model-1 · max")
            XCTAssertEqual(ModelText.line(t, offline: true), "上次记录 · \(label)：model-1 · max")
            XCTAssertEqual(ModelText.short(t), "model-1 · max")
            XCTAssertEqual(ModelText.short(t, offline: true), "上次记录 model-1 · max")
            XCTAssertEqual(ModelText.accessibility(t, offline: true), "上次记录 · \(label)：model-1，思考等级 max")
        }
    }

    func testBadOptionalEffortDoesNotBreakModelOrState() throws {
        for effort in ["null", "4", "{}", "[]", #""unexpected""#, #""/private/value""#, #""HIGH""#] {
            let t = try decode(#"{"projectName":"p","model":{"id":"m1","basis":"last_used","effort":\#(effort)}}"#)
            XCTAssertEqual(ModelText.line(t), "最近使用：m1")
            XCTAssertEqual(ModelText.short(t), "m1")
            XCTAssertEqual(ModelText.accessibility(t), "最近使用：m1")
        }
        XCTAssertNil(ModelText.accessibility(nil))
        XCTAssertNil(ModelText.accessibility(TargetSummary(projectName: "p", model: TargetModel(id: "m1", basis: "unknown", effort: "high"))))
    }

    func testKnownEffortsAreKeptDistinctAndEncodingAddsOnlyOptionalField() throws {
        for effort in ["off", "none", "minimal", "low", "medium", "high", "xhigh", "max"] {
            let m = TargetModel(id: "m1", basis: "last_used", effort: effort)
            XCTAssertEqual(ModelText.line(m), "最近使用：m1 · \(effort)")
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: String]
            XCTAssertEqual(wire, ["id": "m1", "basis": "last_used", "effort": effort])
        }
    }
}
