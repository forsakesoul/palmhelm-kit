import Testing
import Foundation
@testable import PalmhelmKit

@Suite struct ApprovalTests {
    private let json = #"{"id":"0123456789abcdef","status":"pending","targetLabel":"候选：demo","attribution":"candidate","toolName":"Bash","summary":"git status","truncated":false,"createdT":1760000000000,"expiresT":1760000600000}"#

    @Test func approvalEventDecodes() throws {
        guard case .approval(let a) = BridgeEventDecoder.decode(SSEFrame(id: nil, event: "approval", data: json)) else { Issue.record("not approval"); return }
        #expect(a.id == "0123456789abcdef" && a.attribution == ApprovalAttribution.candidate.rawValue)
    }

    @Test func pendingLooksOnlyAtExpiresT() throws {
        let a = try JSONDecoder().decode(ApprovalView.self, from: Data(json.utf8))
        #expect(a.isPending(now: Date(timeIntervalSince1970: 1760000599.999)))
        #expect(!a.isPending(now: Date(timeIntervalSince1970: 1760000600)))
        var d = a; d.status = ApprovalStatus.denied.rawValue
        #expect(!d.isPending(now: Date(timeIntervalSince1970: 1760000000)))
    }

    @Test func stateCarriesApprovals() throws {
        let s = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"none","targets":[],"history":{"highWater":0,"items":[]},"pendingApprovals":1,"approvals":[\#(json)]}"#.utf8))
        #expect(s.pendingApprovals == 1 && s.approvals?.count == 1)
    }
}

@Suite struct ApprovalOptionsTests {
    @Test func optionsDecodeAndFallback() throws {
        let withOptions = #"{"id":"a1","status":"pending","targetLabel":"demo","toolName":"Bash","summary":"ls","truncated":false,"createdT":1,"expiresT":2,"options":[{"id":"allow_once","kind":"allow_once","label":"允许一次","enabled":true},{"id":"rule1","kind":"allow_rule","label":"允许并记住规则","detail":"Bash(curl:*)","enabled":false,"disabledReason":"本期只允许一次"},{"id":"deny","kind":"deny","label":"拒绝","enabled":true}],"messageSupported":true}"#
        let a = try JSONDecoder().decode(ApprovalView.self, from: Data(withOptions.utf8))
        #expect(a.displayOptions.count == 3 && a.displayOptions[1].kind == .allowRule && a.displayOptions[1].enabled == false && a.messageSupported == true)
        let old = #"{"id":"a2","status":"pending","targetLabel":"demo","toolName":"Bash","summary":"ls","truncated":false,"createdT":1,"expiresT":2}"#
        let b = try JSONDecoder().decode(ApprovalView.self, from: Data(old.utf8))
        #expect(b.options == nil && b.displayOptions.map(\.kind) == [.allowOnce, .deny] && b.messageSupported == nil)
        let r = try JSONDecoder().decode(DecisionResponse.self, from: Data(#"{"status":"denied","message":"Palmhelm 拒绝","messageProjected":true}"#.utf8))
        #expect(r.messageProjected == true)
    }
}


@Suite struct ApprovalMessageTests {
    @Test func lengthCountsUTF16Units() {
        let ascii499 = String(repeating: "a", count: 499)
        #expect(!ApprovalMessage.isTooLong(ascii499 + "x")) // 恰好 500
        #expect(ApprovalMessage.isTooLong(ascii499 + "xy")) // 501
        #expect(ApprovalMessage.isTooLong(ascii499 + "😀")) // 499 + 2 单位 = 501
    }
}

@Suite struct ApprovalProviderTests {
    private func view(_ extra: String = "") -> ApprovalView {
        try! JSONDecoder().decode(ApprovalView.self, from: Data(#"{"id":"0123456789abcdef","status":"pending","targetLabel":"未登记目标","attribution":"unregistered","toolName":"Bash","summary":"ls","truncated":false,"createdT":1,"expiresT":2\#(extra)}"#.utf8))
    }
    @Test func codexShowsLabelOldBridgeAndUnknownProviderDoNot() {
        let codex = view(#","provider":"codex""#)
        #expect(codex.provider == "codex")
        #expect(ApprovalText.providerLabel(codex) == "Codex")
        #expect(ApprovalText.identityLine(codex, base: "来源未匹配") == "Codex · 来源未匹配")
        let old = view()
        #expect(old.provider == nil && ApprovalText.providerLabel(old) == nil, "旧 Bridge 没有字段：不显示标签")
        #expect(ApprovalText.identityLine(old, base: "来源未匹配") == "来源未匹配")
        let unknown = view(#","provider":"someone-else""#)
        #expect(ApprovalText.providerLabel(unknown) == nil, "未知 provider 不替它贴标签")
    }
    @Test func providerSurvivesRoundTripAndIdRewrite() throws {
        var a = view(#","provider":"codex""#)
        a.id = "m1:" + a.id // 多机场景下的前缀改写不丢字段
        let back = try JSONDecoder().decode(ApprovalView.self, from: JSONEncoder().encode(a))
        #expect(back.provider == "codex")
    }
}
