import Testing
import Foundation
@testable import PalmhelmKit

// 不可用原因（O1-080）：只有 owner_mismatch 换文案；缺失与未知值都沿用通用文案。
@Suite struct TranscriptUnavailableReasonTests {
    @Test func decodesOwnerMismatchReason() throws {
        let json = #"{"status":"unavailable","items":[],"hasMore":false,"partial":true,"reason":"owner_mismatch"}"#
        let p = try JSONDecoder().decode(TranscriptPage.self, from: Data(json.utf8))
        #expect(!p.isAvailable && p.reason == "owner_mismatch")
    }

    @Test func missingOrUnknownReasonDecodesWithoutChangingCopy() throws {
        let plain = try JSONDecoder().decode(TranscriptPage.self, from: Data(#"{"status":"unavailable","items":[],"hasMore":false,"partial":true}"#.utf8))
        #expect(plain.reason == nil)
        let unknown = try JSONDecoder().decode(TranscriptPage.self, from: Data(#"{"status":"unavailable","items":[],"hasMore":false,"partial":true,"reason":"future_thing"}"#.utf8))
        #expect(unknown.reason == "future_thing")
        #expect(TranscriptCopy.unavailableCopy(reason: nil) == (TranscriptCopy.unavailableTitle, TranscriptCopy.unavailableBody))
        #expect(TranscriptCopy.unavailableCopy(reason: "future_thing") == (TranscriptCopy.unavailableTitle, TranscriptCopy.unavailableBody))
    }

    @Test func ownerMismatchUsesItsOwnCopy() {
        let copy = TranscriptCopy.unavailableCopy(reason: "owner_mismatch")
        #expect(copy.title == "会话记录与这个窗格不匹配")
        #expect(copy.body == "Herdr 记录的会话属于另一个目录，为避免显示其他项目的对话已隐藏。在这个窗格重启 agent 后通常会恢复。")
    }

    @Test func threadKeepsReasonOnlyWhileUnavailable() {
        var t = TranscriptThread()
        t.applyLatest(TranscriptPage(status: "unavailable", reason: "owner_mismatch"))
        #expect(t.status == .unavailable && t.unavailableReason == "owner_mismatch")
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r1", items: []))
        #expect(t.status == .ok && t.unavailableReason == nil)
        t.applyLatest(TranscriptPage(status: "unavailable"))
        #expect(t.unavailableReason == nil)
    }

    // #99 S2：每个 Bridge 原因都有各自的说明；通用文案与未知原因不被误用。
    @Test func everyBridgeReasonHasItsOwnCopy() {
        let generic = TranscriptCopy.unavailableCopy(reason: nil)
        for reason in ["no_session", "provider_unsupported", "session_id_unrecognized", "file_missing", "locate_budget_exceeded", "no_window_cwd", "start_cwd_missing", "unproven_start", "file_unreadable", "io_error", "file_changed", "identity_changed", "identity_unverified", "agent_absent", "leaf_unresolved", "budget_exceeded"] {
            let copy = TranscriptCopy.unavailableCopy(reason: reason)
            #expect(!copy.title.isEmpty && !copy.body.isEmpty, "\(reason) needs copy")
            #expect(copy != generic, "\(reason) must not fall back to the generic copy")
            #expect(!copy.body.contains("/") && !copy.body.contains("~"), "copy must not show paths")
        }
    }

    @Test func statisticsOnlyReasonFallsBackToGenericCopy() {
        #expect(TranscriptCopy.unavailableCopy(reason: "format_unrecognized") == (TranscriptCopy.unavailableTitle, TranscriptCopy.unavailableBody))
    }
}
