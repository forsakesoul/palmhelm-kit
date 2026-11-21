import Testing
import Foundation
@testable import PalmhelmKit

// #98：TargetSummary 的 workspaceId / terminalId 与 SpaceInfo 的 workspaceId 可选解码；旧 Bridge 缺失即 nil。
@Suite struct SpaceIdentityModelTests {
    @Test func newBridgeTargetsDecodeTheIdentifiers() throws {
        let json = #"{"projectName":"alpha","online":true,"id":"alpha","workspaceId":"w1","terminalId":"term-a","location":{"workspace":"工作区一"}}"#
        let t = try JSONDecoder().decode(TargetSummary.self, from: Data(json.utf8))
        #expect(t.workspaceId == "w1" && t.terminalId == "term-a")
        #expect(t.location?.workspace == "工作区一")
    }

    @Test func oldBridgeTargetsDecodeWithoutTheIdentifiers() throws {
        let json = #"{"projectName":"alpha","online":true,"id":"alpha","location":{"workspace":"工作区一"}}"#
        let t = try JSONDecoder().decode(TargetSummary.self, from: Data(json.utf8))
        #expect(t.workspaceId == nil && t.terminalId == nil)
        #expect(t.id == "alpha")
    }

    @Test func spacesDecodeWithAndWithoutWorkspaceId() throws {
        let new = try JSONDecoder().decode(SpaceInfo.self, from: Data(#"{"workspace":"工作区一","agentlessTabCount":2,"workspaceId":"w1"}"#.utf8))
        #expect(new.workspaceId == "w1" && new.agentlessTabCount == 2)
        let old = try JSONDecoder().decode(SpaceInfo.self, from: Data(#"{"workspace":"工作区一","agentlessTabCount":0}"#.utf8))
        #expect(old.workspaceId == nil)
    }

    @Test func encodingOmitsAbsentIdentifiers() throws {
        let t = TargetSummary(projectName: "alpha", targetId: "alpha")
        let json = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
        #expect(!json.contains("workspaceId") && !json.contains("terminalId"))
    }
}
