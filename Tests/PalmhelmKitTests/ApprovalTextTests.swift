import Testing
import Foundation
@testable import PalmhelmKit

/// 审批选项的展示：wire 不变，按当前语言查表；固定文案只在完整匹配已知常量时本地化。
@Suite struct ApprovalTextTests {
    private static let zh = Locale(identifier: "zh-Hans")
    private static let en = Locale(identifier: "en")
    private func opt(_ kind: ApprovalOption.Kind, label: String = "服务端原文", detail: String? = nil, enabled: Bool = true, reason: String? = nil) -> ApprovalOption {
        ApprovalOption(id: "o", kind: kind, label: label, detail: detail, enabled: enabled, disabledReason: reason)
    }
    private func en<T>(_ f: () -> T) -> T { KitL10n.$locale.withValue(Self.en, operation: f) }
    private func zh<T>(_ f: () -> T) -> T { KitL10n.$locale.withValue(Self.zh, operation: f) }

    private let json = #"{"id":"a1","status":"pending","targetLabel":"demo","toolName":"Bash","summary":"ls","truncated":false,"createdT":1,"expiresT":2,"options":[{"id":"allow_once","kind":"allow_once","label":"允许一次","enabled":true},{"id":"r","kind":"allow_rule","label":"允许并记住规则","detail":"允许规则：Bash（curl:*）","enabled":false,"disabledReason":"本期只允许一次，不记住规则"},{"id":"x","kind":"future_kind","label":"新动作","detail":"原样","enabled":true},{"id":"deny","kind":"deny","label":"拒绝","enabled":true}]}"#

    @Test func labelsFollowKindAndLanguageWithoutRefetch() throws {
        let a = try JSONDecoder().decode(ApprovalView.self, from: Data(json.utf8))
        let kinds = a.displayOptions
        #expect(zh { kinds.map(ApprovalText.optionLabel) } == ["允许一次", "允许并记住规则", "新动作", "拒绝"])
        #expect(en { kinds.map(ApprovalText.optionLabel) } == ["Allow once", "Allow and remember rule", "新动作", "Deny"], "未知 kind 保留服务端 Label")
    }

    @Test func missingOptionsStillFallBack() throws {
        let old = try JSONDecoder().decode(ApprovalView.self, from: Data(#"{"id":"a2","status":"pending","targetLabel":"d","toolName":"Bash","summary":"ls","truncated":false,"createdT":1,"expiresT":2}"#.utf8))
        #expect(en { old.displayOptions.map(ApprovalText.optionLabel) } == ["Allow once", "Deny"])
        #expect(zh { old.displayOptions.map(ApprovalText.optionLabel) } == ["允许一次", "拒绝"])
    }

    @Test func unknownKindDecodesRoundTripsAndNeverBecomesAnAction() throws {
        let a = try JSONDecoder().decode(ApprovalView.self, from: Data(json.utf8))
        let u = try #require(a.displayOptions.first { $0.id == "x" })
        #expect(u.kind == .unknown("future_kind") && u.kind.rawValue == "future_kind" && u.enabled)
        #expect(!a.displayOptions.contains { $0.kind == .allowOnce && $0.id == "x" } && !a.displayOptions.contains { $0.kind == .deny && $0.id == "x" })
        #expect(a.displayOptions.filter { $0.kind == .allowOnce }.count == 1 && a.displayOptions.filter { $0.kind == .deny }.count == 1, "未知项不遮蔽已知两项")
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(u)) as? [String: Any]
        #expect(back?["kind"] as? String == "future_kind", "编码回原字符串")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ApprovalOption.self, from: Data(#"{"id":"o","kind":5,"label":"x","enabled":true}"#.utf8)) }
        #expect(ApprovalOption.Kind(rawValue: "allow_once") == .allowOnce)
    }

    @Test func fixedStringsLocalizeOnlyOnExactKnownValues() {
        let rule = opt(.allowRule, label: "允许并记住规则", detail: "允许规则：Bash（curl:*）", enabled: false, reason: "本期只允许一次，不记住规则")
        #expect(en { ApprovalText.optionDetail(rule) } == "Allow rule: Bash（curl:*）", "只换前缀，工具与内容逐字保留")
        #expect(zh { ApprovalText.optionDetail(rule) } == "允许规则：Bash（curl:*）")
        #expect(en { ApprovalText.optionDisabledReason(rule) } == "Only one-time approval is supported. Rules will not be remembered.")
        #expect(zh { ApprovalText.optionDisabledReason(rule) } == "本期只允许一次，不记住规则")
        #expect(en { ApprovalText.optionDetail(opt(.allowRule, detail: "agent 建议了一条本期不支持展示的规则")) } == "The agent suggested a rule that cannot be displayed in this version.")
        #expect(en { ApprovalText.optionDetail(opt(.allowRule, detail: "另有 3 条 agent 建议未展示")) } == "3 more agent suggestions are not shown.")
        #expect(zh { ApprovalText.optionDetail(opt(.allowRule, detail: "另有 3 条 agent 建议未展示")) } == "另有 3 条 agent 建议未展示")
    }

    @Test func unknownMalformedAndOtherContextsAreUntouched() {
        for d in ["另有 0 条 agent 建议未展示", "另有 03 条 agent 建议未展示", "另有 x 条 agent 建议未展示", "另有  条 agent 建议未展示", "另有 -1 条 agent 建议未展示",
                  "另有 3 条 agent 建议未展示。", "前缀 另有 3 条 agent 建议未展示", "agent 建议了一条本期不支持展示的规则。"] {
            #expect(en { ApprovalText.optionDetail(opt(.allowRule, detail: d)) } == d, "\(d)")
        }
        #expect(en { ApprovalText.optionDisabledReason(opt(.allowRule, enabled: false, reason: "新的原因")) } == "新的原因", "新 Bridge 的其他原因原样")
        #expect(en { ApprovalText.optionDisabledReason(opt(.allowRule, enabled: false, reason: "本期只允许一次，不记住规则。")) } == "本期只允许一次，不记住规则。")
        // 其他 kind / 未知 kind 的 detail、reason 不按上下文外的规则替换
        #expect(en { ApprovalText.optionDetail(opt(.unknown("k"), detail: "agent 建议了一条本期不支持展示的规则")) } == "agent 建议了一条本期不支持展示的规则")
        #expect(en { ApprovalText.optionDetail(opt(.deny, detail: "允许规则：x")) } == "允许规则：x")
        #expect(en { ApprovalText.optionDisabledReason(opt(.unknown("k"), reason: "本期只允许一次，不记住规则")) } == "本期只允许一次，不记住规则")
        #expect(en { ApprovalText.optionDetail(opt(.allowRule, detail: nil)) } == nil)
    }

    @Test func reviseHintAndPlanPlaceholderOnlyExactMatch() {
        let hint = "同一计划已连续打回多次，agent 可能停止修改；可到 Mac 上处理"
        #expect(en { ApprovalText.reviseHint(hint) } == "This plan has been sent back several times. The agent may stop revising it; you can handle it on your Mac.")
        #expect(zh { ApprovalText.reviseHint(hint) } == hint)
        #expect(en { ApprovalText.reviseHint("别的提示") } == "别的提示" && en { ApprovalText.reviseHint(nil) } == nil)
        #expect(en { ApprovalText.planText("此请求未附计划正文，请回终端核对") } == "No plan text was included. Check the terminal before deciding.")
        #expect(zh { ApprovalText.planText("此请求未附计划正文，请回终端核对") } == "此请求未附计划正文，请回终端核对")
        let plan = "## 计划\n1. 此请求未附计划正文，请回终端核对"
        #expect(en { ApprovalText.planText(plan) } == plan, "真实计划正文逐字保留")
    }

    @Test func displayLanguageNeverChangesTheStoredOptionOrItsEncoding() throws {
        let a = try JSONDecoder().decode(ApprovalView.self, from: Data(json.utf8))
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let before = try enc.encode(a.options)
        _ = en { a.displayOptions.map(ApprovalText.optionLabel) }
        #expect(try enc.encode(a.options) == before && a.options?[0].label == "允许一次")
    }
}

/// R1：卡片实际消费的分类集合（两端同一个函数），不是 Kind 等式。
@Suite struct ApprovalPresentationTests {
    private let json = #"{"id":"a1","status":"pending","targetLabel":"d","toolName":"Bash","summary":"ls","truncated":false,"createdT":1,"expiresT":2,"options":[{"id":"allow_once","kind":"allow_once","label":"允许一次","enabled":true},{"id":"r","kind":"allow_rule","label":"x","detail":"允许规则：Bash","enabled":false,"disabledReason":"本期只允许一次，不记住规则"},{"id":"x","kind":"future_kind","label":"新动作","detail":"未来说明","enabled":true,"disabledReason":"未来原因"},{"id":"deny","kind":"deny","label":"拒绝","enabled":true}]}"#

    @Test func unknownIsShownReadOnlyAndNeverAnActionOrARule() throws {
        let a = try JSONDecoder().decode(ApprovalView.self, from: Data(json.utf8))
        let p = ApprovalText.presentation(of: a.displayOptions)
        #expect(p.allow?.id == "allow_once" && p.deny?.id == "deny", "动作集合仍只有已知两项")
        #expect(p.rules.map(\.id) == ["r"], "未知项不混算成记住规则")
        let u = try #require(p.unknown.first)
        #expect(p.unknown.count == 1 && u.id == "x" && u.kind.rawValue == "future_kind" && u.enabled, "enabled=true 也只读")
        for lang in ["zh-Hans", "en"] {
            KitL10n.$locale.withValue(Locale(identifier: lang)) {
                #expect(ApprovalText.optionLabel(u) == "新动作" && ApprovalText.optionDetail(u) == "未来说明" && ApprovalText.optionDisabledReason(u) == "未来原因", "原样显示 \(lang)")
            }
        }
    }

    @Test func fallbackOptionsHaveNothingUnknown() {
        let p = ApprovalText.presentation(of: ApprovalView(id: "a", status: "pending", targetLabel: "d", toolName: "Bash", summary: "ls", createdT: 1, expiresT: 2).displayOptions)
        #expect(p.allow != nil && p.deny != nil && p.rules.isEmpty && p.unknown.isEmpty)
    }
}

/// 真实 BridgeClient 发出的审批决定：显示语言（含翻译后的标签）不进入请求体，同一决定在中/英下逐字节相同。
@Suite(.serialized) struct ApprovalDecisionPayloadTests {
    final class Capture: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var bodies: [(path: String, body: Data)] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let s = request.httpBodyStream {
                s.open(); defer { s.close() }
                var buf = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            }
            Capture.bodies.append((request.url!.path, data))
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"status":"allowed"}"#.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func send(language: String) async throws -> [Data] {
        Capture.bodies = []
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Capture.self]
        let c = BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t", session: URLSession(configuration: cfg))
        let a = ApprovalView(id: "a1", status: "pending", targetLabel: "d", toolName: "Bash", summary: "ls", createdT: 1, expiresT: 2)
        try await KitL10n.$locale.withValue(Locale(identifier: language)) {
            // 先按当前语言取一遍标签（卡片就是这么渲染的），再发决定。
            _ = a.displayOptions.map(ApprovalText.optionLabel)
            _ = try await c.decide(approvalId: a.id, decision: .allowOnce)
            _ = try await c.decide(approvalId: a.id, decision: .deny, message: "换个做法")
            _ = try await c.revise(approvalId: a.id, message: "再想想")
        }
        return Capture.bodies.map(\.body)
    }

    @Test func decisionBodiesAreIdenticalInChineseAndEnglish() async throws {
        let zh = try await send(language: "zh-Hans"), en = try await send(language: "en")
        #expect(zh.count == 3 && zh == en, "决定/id/message 请求体与语言无关")
        let first = try #require(JSONSerialization.jsonObject(with: zh[0]) as? [String: String])
        #expect(first == ["decision": "allow_once"], "动作 payload 只含 wire 值，不含翻译后的标签")
    }
}
