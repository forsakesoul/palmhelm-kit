import Foundation
import Testing
@testable import PalmhelmKit

// #49：合并账户的只读来源（Bridge 的 sources[]）。旧 Bridge 没有该键时必须照常解码。
@Suite struct QuotaSourcesTests {
    @Test func decodesSourcesAndKeepsOldPayloadsWorking() throws {
        let withSources = #"{"accounts":[{"provider":"codex","accountId":"acct_1","source":"codex_app_server","status":"ok","sources":[{"sourceId":"codex:abcd1234","label":"工作","status":"ok","observedAt":1792400000000},{"sourceId":"codex:beef0001","status":"error"}]}]}"#
        let decoded = try JSONDecoder().decode(AccountsResponse.self, from: Data(withSources.utf8))
        let account = try #require(decoded.accounts.first)
        #expect(account.sources?.count == 2)
        #expect(account.sources?.first?.label == "工作")
        #expect(account.sources?.last?.label == nil)

        let old = try JSONDecoder().decode(AccountsResponse.self, from: Data(#"{"accounts":[{"provider":"codex","accountId":"unidentified","source":"none","status":"error"}]}"#.utf8))
        #expect(old.accounts.first?.sources == nil)
        #expect(QuotaCopy.sourcesNote(old.accounts[0]) == nil)
    }

    @Test func mergedNoteAppearsOnlyForMultipleSourcesAndNeverSumsWindows() {
        let one = AccountSnapshot(provider: "codex", accountId: "a", source: "codex_app_server", status: "ok",
                                  sources: [AccountSourceSummary(sourceId: "codex:1", status: "ok")])
        #expect(QuotaCopy.sourcesNote(one) == nil)
        let two = AccountSnapshot(provider: "codex", accountId: "a", source: "codex_app_server", status: "ok",
                                  sources: [AccountSourceSummary(sourceId: "codex:1", status: "ok"), AccountSourceSummary(sourceId: "codex:2", status: "stale")])
        let note = QuotaCopy.sourcesNote(two) ?? ""
        #expect(note.contains("2 个配置目录"))
        #expect(note.contains("不相加"))
    }

    @Test func sourceStatusUsesFixedWordsAndUnknownIsNotNormal() {
        #expect(QuotaCopy.sourceStatusText("ok") == "正常")
        #expect(QuotaCopy.sourceStatusText("error") == "读取失败")
        #expect(QuotaCopy.sourceStatusText("something_new") == "状态未知")
    }
}
