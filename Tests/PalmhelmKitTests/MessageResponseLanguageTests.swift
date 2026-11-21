import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct MessageResponseLanguageTests {
    @Test func onlyReportCommandsInEnglishAskForEnglish() {
        #expect(MessageResponseLanguage.requested(forWire: "任务", resource: "en") == .en)
        #expect(MessageResponseLanguage.requested(forWire: " 面板 ", resource: "en") == .en)
        #expect(MessageResponseLanguage.requested(forWire: "任务", resource: "zh-Hans") == nil)
        for wire in ["查找 编译失败", "关注 app", "取消关注 app", "关注列表", "查找  a b"] { #expect(MessageResponseLanguage.requested(forWire: wire, resource: "en") == .en, "\(wire)") }
        for wire in ["关注", "关注 a b", "取消关注", "关注列表 x", "查找", "重置占用 app", "切换到 app", "派给 a：任务", "写一个任务", "tasks", ""] {
            #expect(MessageResponseLanguage.requested(forWire: wire, resource: "en") == nil, "\(wire)")
        }
    }

    @Test func fixedSourceKeepsTheFirstRequestLanguage() {
        #expect(ResponseLanguageSource.fixed(nil).resolve(forWire: "任务") == nil)
        #expect(ResponseLanguageSource.fixed(.en).resolve(forWire: "任务") == .en)
        let cur = KitL10n.$locale.withValue(Locale(identifier: "en")) { ResponseLanguageSource.current.resolve(forWire: "面板") }
        #expect(cur == .en)
    }

    @Test func bodyOmitsTheFieldUnlessSet() throws {
        func json(_ b: SendMessageBody) throws -> String { String(decoding: try JSONEncoder().encode(b), as: UTF8.self) }
        let zh = try json(SendMessageBody(clientMsgId: "id", text: "任务", mode: nil))
        #expect(!zh.contains("responseLanguage"))
        let en = try json(SendMessageBody(clientMsgId: "id", text: "任务", mode: nil, responseLanguage: "en"))
        #expect(en.contains("\"responseLanguage\":\"en\""))
    }
}

@Suite struct ReportLanguageCapabilityTests {
    @Test func capabilityIsReadFromBridgeMeta() throws {
        let m = try JSONDecoder().decode(BridgeMeta.self, from: Data(#"{"messageResponseLanguages":["zh","en","xx"]}"#.utf8))
        #expect(m.supportsReportLanguage(.en) && m.supportsReportLanguage(.zh))
        #expect(!(try JSONDecoder().decode(BridgeMeta.self, from: Data("{}".utf8))).supportsReportLanguage(.en))
    }
}
