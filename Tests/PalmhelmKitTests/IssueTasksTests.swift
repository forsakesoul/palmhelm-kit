import Foundation
import Testing
@testable import PalmhelmKit

// #21 S2：DTO 解码（与 Bridge 的 JSON 形状一致）、请求形状、固定文案与可用性规则。
@Suite struct IssueTasksTests {
    static let optionsJSON = #"""
    {"createSupported":true,"dispatchEnabled":true,
     "github":{"available":false,"reason":"github_unavailable","createSupported":false},
     "sources":[{"sourceId":"0123456789abcdef","repo":"octo/handoff"}],
     "targets":[{"targetId":"target:a","label":"app · design","destinationVersion":"abc","reason":null},
                {"targetId":"target:b","label":"app · execute","destinationVersion":null,"reason":"owner_only"}],
     "maxPromptUnits":8000}
    """#

    @Test func optionsDecodeWithNullableReasonsAndVersions() throws {
        let o = try JSONDecoder().decode(IssueTaskOptions.self, from: Data(Self.optionsJSON.utf8))
        #expect(o.createSupported && o.dispatchEnabled)
        #expect(o.github.available == false && o.github.reason == "github_unavailable" && o.github.createSupported == false)
        #expect(o.sources == [IssueTaskSource(sourceId: "0123456789abcdef", repo: "octo/handoff")])
        #expect(o.targets[0].usable && !o.targets[1].usable)
        #expect(o.targets[1].reason == "owner_only")
        #expect(o.maxPromptUnits == 8000)
    }

    @Test func manualAvailabilityIgnoresGitHub() throws {
        let o = try JSONDecoder().decode(IssueTaskOptions.self, from: Data(Self.optionsJSON.utf8))
        #expect(IssueTaskRules.manualAvailable(o), "gh 不可用时手工需求仍可用")
        #expect(!IssueTaskRules.githubAvailable(o), "GitHub 来源单独灰掉")
        let closed = try JSONDecoder().decode(IssueTaskOptions.self, from: Data(Self.optionsJSON.replacingOccurrences(of: "\"createSupported\":true", with: "\"createSupported\":false").utf8))
        #expect(!IssueTaskRules.manualAvailable(closed), "派发关闭时手工需求不可用")
    }

    @Test func listDetailPreviewAndCreatedDecode() throws {
        let page = try JSONDecoder().decode(IssueTaskListPage.self, from: Data(#"{"items":[{"number":21,"title":"需求","state":"closed","updatedAt":"2026-11-01T08:00:00Z","url":"https://github.com/o/r/issues/21"}],"page":1}"#.utf8))
        #expect(page.items.first?.isClosed == true)
        let detail = try JSONDecoder().decode(IssueTaskDetail.self, from: Data(#"{"number":21,"title":"t","state":"open","updatedAt":"u","url":"https://github.com/o/r/issues/21","body":"b","sourceVersion":"v"}"#.utf8))
        #expect(detail.sourceVersion == "v" && !detail.isClosed)
        let pv = try JSONDecoder().decode(IssueTaskPreview.self, from: Data(#"{"text":"[任务] x","textDigest":"d","destinationVersion":"dv","sourceVersion":null}"#.utf8))
        #expect(pv.sourceVersion == nil && pv.textDigest == "d")
        let created = try JSONDecoder().decode(IssueTaskCreated.self, from: Data(#"{"accepted":true,"eventKey":"api:x:y"}"#.utf8))
        #expect(created.accepted && created.eventKey == "api:x:y")
    }

    @Test func githubRequestCarriesOnlyItsOwnFields() throws {
        let req = IssueTaskRequest(targetId: "target:a", destinationVersion: "dv", source: .github(sourceId: "0123456789abcdef", number: 21, version: "sv"),
                                   instructions: "补充", ackClosed: false)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any]
        let source = obj?["source"] as? [String: Any]
        #expect(source?["kind"] as? String == "github" && source?["number"] as? Int == 21 && source?["version"] as? String == "sv")
        #expect(source?["title"] == nil && source?["description"] == nil, "GitHub 来源不带手工字段")
        #expect(obj?["clientMsgId"] == nil && obj?["textDigest"] == nil, "预览不带确认字段")
    }

    @Test func manualCreateRequestCarriesDigestAndOptionalReference() throws {
        let req = IssueTaskRequest(targetId: "target:a", destinationVersion: "dv", source: .manual(title: "手工", description: "说明", referenceUrl: nil),
                                   instructions: "", ackClosed: false, clientMsgId: "00000000-0000-4000-8000-00000000000a", textDigest: "d1")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any]
        let source = obj?["source"] as? [String: Any]
        #expect(source?["kind"] as? String == "manual" && source?["referenceUrl"] == nil, "没有参考链接时不带该键")
        #expect(obj?["textDigest"] as? String == "d1" && obj?["clientMsgId"] as? String == "00000000-0000-4000-8000-00000000000a")
    }

    @Test func errorCopyIsFixedPerCodeAndNeverEchoesServerText() {
        #expect(IssueTaskRules.errorCopy(IssueTaskError.http(status: 409, code: "preview_changed")).contains("重新预览"))
        #expect(IssueTaskRules.errorCopy(IssueTaskError.http(status: 409, code: "closed_unacknowledged")).contains("已关闭"))
        #expect(IssueTaskRules.errorCopy(IssueTaskError.http(status: 409, code: "something_new")) == "派发失败，消息没有发出。")
        #expect(IssueTaskRules.errorCopy(IssueTaskError.http(status: 500, code: nil)) == "派发失败，消息没有发出。")
        #expect(IssueTaskRules.errorCopy(IssueTaskError.unsupported).contains("升级 Bridge"), "旧 Bridge 降级为不支持")
        #expect(IssueTaskRules.errorCopy(IssueTaskError.http(status: 413, code: "prompt_too_large")).contains("不会自动截断"))
    }

    @Test func githubUnavailableCopyPointsToTerminalOnly() {
        let copy = IssueTaskRules.githubUnavailableCopy(reason: "github_unavailable")
        #expect(copy.contains("gh auth login") && copy.contains("手工需求仍可用"))
        #expect(!copy.contains("安装"), "不替用户安装或登录")
    }

    @Test func referenceURLMustBeCanonicalIssueLink() {
        #expect(IssueTaskRules.validReferenceURL("https://github.com/o/r/issues/1"))
        #expect(IssueTaskRules.validReferenceURL("https://github.com/o-x/r.y/issues/123456789"))
        for bad in ["http://github.com/o/r/issues/1", "https://evil.example/o/r/issues/1", "https://github.com/o/r/pull/1",
                    "https://github.com/o/r/issues/1?x=1", "https://github.com/o/r/issues/1#c", "https://u@github.com/o/r/issues/1",
                    "https://github.com/o/r/issues/0", "https://github.com/o/r/issues/01", "https://github.com/o/r/issues/1/", "https://github.com/o/r/issues/1234567890"] {
            #expect(!IssueTaskRules.validReferenceURL(bad), "accepted \(bad)")
        }
    }

    @Test func manualFieldsAreRequiredAndTitleIsBounded() {
        #expect(IssueTaskRules.manualValid(title: "标题", description: "描述"))
        #expect(!IssueTaskRules.manualValid(title: "   ", description: "描述"))
        #expect(!IssueTaskRules.manualValid(title: "标题", description: " "))
        #expect(!IssueTaskRules.manualValid(title: String(repeating: "a", count: 201), description: "描述"))
        #expect(IssueTaskRules.units("a😀") == 3, "UTF-16 码元口径与服务端一致")
    }

    @Test func targetReasonsHaveFixedCopy() {
        #expect(IssueTaskRules.targetReasonCopy("owner_only") == "交接会话不接收派发")
        #expect(IssueTaskRules.targetReasonCopy(nil) == "暂不可派发")
    }

    private static let issue = IssueTaskDetail(number: 21, title: "需求", state: "open", updatedAt: "u", url: "https://github.com/o/r/issues/21", body: "b", sourceVersion: "sv")
    private static let preview = IssueTaskPreview(text: "[任务] 需求", textDigest: "digest-1", destinationVersion: "dv", sourceVersion: "sv")

    private func githubDraft(closed: Bool = false, ack: Bool = false) -> IssueTaskDraft {
        var d = IssueTaskDraft()
        d.targetId = "target:a"; d.destinationVersion = "dv"; d.sourceId = "0123456789abcdef"
        d.issue = IssueTaskDetail(number: 21, title: "需求", state: closed ? "closed" : "open", updatedAt: "u", url: "https://github.com/o/r/issues/21", body: "b", sourceVersion: "sv")
        d.ackClosed = ack
        return d
    }

    @Test func closedIssueNeedsAcknowledgementBeforePreview() {
        #expect(githubDraft().readyForPreview)
        #expect(!githubDraft(closed: true).readyForPreview, "已关闭的 Issue 必须先确认")
        #expect(githubDraft(closed: true, ack: true).readyForPreview)
    }

    @Test func editingAnyContentFieldInvalidatesThePreview() {
        var d = githubDraft()
        d.setPreview(Self.preview)
        #expect(d.createRequest(clientMsgId: "00000000-0000-4000-8000-00000000000a") != nil)
        d.instructions = "改动"
        #expect(d.createRequest(clientMsgId: "00000000-0000-4000-8000-00000000000a") == nil, "预览后改动必须重新预览")
    }

    @Test func confirmCarriesThePreviewDigestAndVersion() throws {
        var d = githubDraft()
        d.setPreview(Self.preview)
        let req = try #require(d.createRequest(clientMsgId: "00000000-0000-4000-8000-00000000000a"))
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        #expect(obj["textDigest"] as? String == "digest-1")
        let source = obj["source"] as? [String: Any]
        #expect(source?["version"] as? String == "sv" && source?["number"] as? Int == 21)
    }

    @Test func manualDraftRejectsBadReferenceAndMissingFields() {
        var d = IssueTaskDraft()
        d.source = .manual; d.targetId = "target:a"; d.destinationVersion = "dv"
        d.title = "标题"; d.description = "说明"
        #expect(d.readyForPreview)
        d.referenceUrl = "https://evil.example/x"
        #expect(!d.readyForPreview, "参考链接不合法时不能预览")
        d.referenceUrl = "https://github.com/o/r/issues/3"
        #expect(d.readyForPreview)
        d.description = " "
        #expect(!d.readyForPreview)
    }

    @Test func unavailableGitHubDefaultsToManualSource() throws {
        let unavailable = try JSONDecoder().decode(IssueTaskOptions.self, from: Data(Self.optionsJSON.utf8))
        #expect(IssueTaskRules.defaultSource(unavailable) == .manual, "gh 不可用时 GitHub 分段禁用，默认落在手工需求")
        let available = try JSONDecoder().decode(IssueTaskOptions.self, from: Data(Self.optionsJSON.replacingOccurrences(of: "\"available\":false", with: "\"available\":true").replacingOccurrences(of: "\"createSupported\":false}", with: "\"createSupported\":true}").utf8))
        #expect(IssueTaskRules.defaultSource(available) == .github)
    }

    // MARK: 模板语言（Bridge 0.3.11 能力协商）

    private func options(_ languages: String?) throws -> IssueTaskOptions {
        let json = languages.map { Self.optionsJSON.replacingOccurrences(of: "\"maxPromptUnits\":8000", with: "\"maxPromptUnits\":8000,\"templateLanguages\":\($0)") } ?? Self.optionsJSON
        return try JSONDecoder().decode(IssueTaskOptions.self, from: Data(json.utf8))
    }
    private func keys(_ r: IssueTaskRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
    }

    @Test func capabilityIsOptionalAndTolerant() throws {
        #expect(try options(nil).templateLanguages == nil, "旧 Bridge 没有能力字段")
        #expect(try options(#"["zh","en"]"#).templateLanguages == ["zh", "en"])
        #expect(try options(#"["zh","en","fr"]"#).templateLanguages == ["zh", "en", "fr"], "未知成员不影响解码")
    }

    @Test func requestEncodesLanguageOnlyWhenSet() throws {
        let base = IssueTaskRequest(targetId: "t", destinationVersion: "v", source: .manual(title: "x", description: "y", referenceUrl: nil), instructions: "", ackClosed: false)
        #expect(try keys(base)["templateLanguage"] == nil, "旧调用的字段集合不变")
        let en = IssueTaskRequest(targetId: "t", destinationVersion: "v", source: .manual(title: "x", description: "y", referenceUrl: nil), instructions: "", ackClosed: false, templateLanguage: .en)
        #expect(try keys(en)["templateLanguage"] as? String == "en")
    }

    @Test func decisionFollowsResourceLanguageAndCapability() throws {
        let new = try options(#"["zh","en"]"#), old = try options(nil)
        #expect(IssueTaskRules.templateDecision(options: new, resource: "en") == .send(.en))
        #expect(IssueTaskRules.templateDecision(options: new, resource: "zh-Hans") == .send(.zh))
        #expect(IssueTaskRules.templateDecision(options: old, resource: "zh-Hans") == .send(nil), "旧 Bridge + 中文：不带新字段")
        #expect(IssueTaskRules.templateDecision(options: old, resource: "en") == .needsNewerBridge, "旧 Bridge + 英文：不静默降级")
        #expect(IssueTaskRules.templateDecision(options: nil, resource: "en") == .needsNewerBridge)
    }

    @Test func upgradeHintIsBilingual() {
        KitL10n.$locale.withValue(Locale(identifier: "en")) { #expect(IssueTaskRules.templateUpgradeCopy == "English task templates require Bridge 0.3.11 or later.") }
        KitL10n.$locale.withValue(Locale(identifier: "zh-Hans")) { #expect(IssueTaskRules.templateUpgradeCopy == "英文任务模板需要 Bridge 0.3.11 或更新版本。") }
    }

    @Test func previewAndConfirmShareTheLanguageAndChangeInvalidatesPreview() throws {
        let new = try options(#"["zh","en"]"#)
        var d = githubDraft()
        let c1 = d.syncTemplateLanguage(options: new, resource: "en")
        #expect(c1)
        #expect(try keys(#require(d.previewRequest()))["templateLanguage"] as? String == "en")
        d.setPreview(Self.preview)
        #expect(try keys(#require(d.createRequest(clientMsgId: "u")))["templateLanguage"] as? String == "en", "确认与预览同语言")
        let r = d.revision
        let c2 = d.syncTemplateLanguage(options: new, resource: "en")
        #expect(!c2, "未变化不作废预览")
        #expect(d.preview != nil && d.revision == r)
        let c3 = d.syncTemplateLanguage(options: new, resource: "zh-Hans")
        #expect(c3)
        #expect(d.preview == nil && d.createRequest(clientMsgId: "u") == nil && d.revision == r + 1, "语言变化作废预览与在途结果")
        #expect(try keys(#require(d.previewRequest()))["templateLanguage"] as? String == "zh")
    }

    @Test func oldBridgeEnglishNeverProducesARequest() throws {
        let old = try options(nil)
        var d = githubDraft()
        let c4 = d.syncTemplateLanguage(options: old, resource: "en")
        #expect(c4)
        #expect(d.templateNeedsNewerBridge && !d.readyForPreview && d.previewRequest() == nil, "零请求")
        let c5 = d.syncTemplateLanguage(options: old, resource: "zh-Hans")
        #expect(c5)
        #expect(!d.templateNeedsNewerBridge)
        #expect(try keys(#require(d.previewRequest()))["templateLanguage"] == nil, "旧 Bridge + 中文不编码新字段")
    }

    // MARK: 语言切换 × 预览 / pending / 重投（共同 seam，不经 UI）

    @Test func languageChangeInvalidatesInFlightPreviewAndLateResponse() throws {
        let new = try options(#"["zh","en"]"#)
        var d = githubDraft()
        _ = d.syncTemplateLanguage(options: new, resource: "en")
        let started = IssueTaskScope(epoch: 1, draft: d.revision)
        d.setPreview(Self.preview)
        _ = d.syncTemplateLanguage(options: new, resource: "zh-Hans")
        #expect(d.preview == nil, "旧预览作废")
        let late: Result<IssueTaskPreview, Error> = .success(Self.preview)
        if case .discarded = IssueTaskFlow.resolve(late, started: started, current: IssueTaskScope(epoch: 1, draft: d.revision)) {} else { Issue.record("迟到应答必须丢弃") }
        #expect(!d.acceptPreview(Self.preview, startedAt: started.draft) && d.preview == nil, "迟到预览不能重新启用")
    }

    @Test func pendingSubmissionKeepsLanguageAndReplaysVerbatimWithoutExtraRequests() async throws {
        let new = try options(#"["zh","en"]"#)
        var d = githubDraft()
        _ = d.syncTemplateLanguage(options: new, resource: "en")
        d.setPreview(Self.preview)
        let req = try #require(d.createRequest(clientMsgId: "00000000-0000-4000-8000-00000000000a"))
        let pending = IssueTaskPendingSubmission(request: req, summary: "[Task] x", targetId: "target:a")
        let box = IssueTaskFlowTests.RecordingTransport.Box()
        let revision = d.revision
        // 未知提交悬而未决时界面语言变为中文：不同步、不作废、不发请求。
        let changed = d.syncTemplateLanguage(options: new, resource: "zh-Hans", pending: true)
        #expect(!changed && d.revision == revision && d.templateLanguage == .en && d.preview != nil)
        #expect(box.received.isEmpty, "同步语言本身零请求")
        _ = await IssueTaskFlow.createOnce(IssueTaskFlowTests.RecordingTransport(box: box), pending.request)
        let sent = try #require(box.received.first)
        #expect(box.received.count == 1 && sent == req)
        #expect(sent.templateLanguage == .en && sent.clientMsgId == req.clientMsgId && sent.textDigest == "digest-1", "原语言、原 UUID、原 digest")
    }

    @Test func switchingIsAllowedAgainOnceNoSubmissionIsPending() throws {
        let new = try options(#"["zh","en"]"#)
        var d = githubDraft()
        _ = d.syncTemplateLanguage(options: new, resource: "en")
        d.setPreview(Self.preview)
        let changed = d.syncTemplateLanguage(options: new, resource: "zh-Hans", pending: false)
        #expect(changed && d.preview == nil && d.templateLanguage == .zh, "无 pending 才切换并要求重新预览")
        #expect(try keys(#require(d.previewRequest()))["templateLanguage"] as? String == "zh")
    }
}
