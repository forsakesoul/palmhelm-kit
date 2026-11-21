import XCTest
@testable import PalmhelmKit

// #101 发送提示：提示由实际发送用的 mode（SendTimingRules.primaryMode）派生；前面条数只数真正仍在排队的条目。
final class ThreadSendHintTests: XCTestCase {
    private func command(state: String, reason: String? = nil) -> ApiCommand {
        ApiCommand(key: "k", inboxSeq: 1, text: "x", origin: "api", state: state, reason: reason)
    }

    private func mode(direct: Bool, status: String?, kind: String?, nativeSteer: Bool, supports: Bool = true) -> SendMode? {
        supports ? SendTimingRules.primaryMode(direct: direct, targetStatus: status, kind: kind, nativeSteer: nativeSteer) : nil
    }

    func testDirectClaudeWorkingWithNativeSteerInsertsDirectly() {
        let m = mode(direct: true, status: "working", kind: "claude", nativeSteer: true)
        XCTAssertEqual(ThreadSendHintRules.hint(mode: m, queuedAhead: 0, pendingAnswers: 0), .directInsert)
    }

    // 反例：非 Claude 的工作中直达即使 nativeSteer 为真，主按钮也不是插入（primaryMode 为 nil），提示不得说插入。
    func testNonClaudeNativeSteerDoesNotPromiseInsertion() {
        let m = mode(direct: true, status: "working", kind: "codex", nativeSteer: true)
        XCTAssertNil(m)
        XCTAssertNil(ThreadSendHintRules.hint(mode: m, queuedAhead: 0, pendingAnswers: 0))
    }

    // 能力缺省或禁用（supportsSendTiming 为假）：主按钮不带 mode，提示也不说排队或插入。
    func testUnsupportedSendTimingShowsNoModeHint() {
        let m = mode(direct: true, status: "working", kind: "claude", nativeSteer: true, supports: false)
        XCTAssertNil(ThreadSendHintRules.hint(mode: m, queuedAhead: 0, pendingAnswers: 0))
        let bound = mode(direct: false, status: "working", kind: "claude", nativeSteer: false, supports: false)
        XCTAssertNil(ThreadSendHintRules.hint(mode: bound, queuedAhead: 2, pendingAnswers: 0))
    }

    func testBoundWorkingTargetQueuesWithAheadCount() {
        let m = mode(direct: false, status: "working", kind: "claude", nativeSteer: true)
        XCTAssertEqual(m, .queue)
        XCTAssertEqual(ThreadSendHintRules.hint(mode: m, queuedAhead: 3, pendingAnswers: 0), .queued(ahead: 3))
        XCTAssertEqual(ThreadSendHintRules.hint(mode: m, queuedAhead: -1, pendingAnswers: 0), .queued(ahead: 0))
    }

    func testIdleTargetShowsNoQueueHintAndPendingAnswersStillShow() {
        XCTAssertNil(ThreadSendHintRules.hint(mode: mode(direct: false, status: "idle", kind: nil, nativeSteer: false), queuedAhead: 0, pendingAnswers: 0))
        XCTAssertEqual(ThreadSendHintRules.hint(mode: nil, queuedAhead: 0, pendingAnswers: 2), .pendingAnswers(2))
        XCTAssertEqual(ThreadSendHintRules.hint(mode: .queue, queuedAhead: 1, pendingAnswers: 2), .queued(ahead: 1), "发送方式优先")
    }

    // 反例：只有已结束的记录（撤回、并入、直达插话终态、过期）时，前面条数为 0。
    func testEndedQueueRecordsAreNotCountedAsAhead() {
        let commands = [
            command(state: "finished", reason: "withdrawn"),
            command(state: "finished", reason: "merged"),
            command(state: "finished", reason: "native_delivered"),
            command(state: "finished", reason: "queue_expired"),
            command(state: "queued", reason: "queue_expired_uncertain"),
        ]
        XCTAssertEqual(ThreadSendHintRules.queuedAhead(commands), 0)
    }

    func testOnlyRealPendingItemsAreCounted() {
        let commands = [
            command(state: "queued", reason: nil),
            command(state: "queued", reason: nil),
            command(state: "finished", reason: "withdrawn"),
            command(state: "working", reason: nil),
        ]
        XCTAssertEqual(ThreadSendHintRules.queuedAhead(commands), 2)
    }

    func testTextTable() {
        XCTAssertEqual(ThreadSendHintRules.text(.directInsert, agentName: "Claude"), "↳ 直接插入当前回合 · Claude 正在工作")
        XCTAssertEqual(ThreadSendHintRules.text(.queued(ahead: 0), agentName: "Claude"), "⏱ 排到本轮结束后发送")
        XCTAssertEqual(ThreadSendHintRules.text(.queued(ahead: 2), agentName: "Claude"), "⏱ 排到本轮结束后发送 · 前面还有 2 条")
        XCTAssertEqual(ThreadSendHintRules.text(.pendingAnswers(3), agentName: "Claude"), "有 3 条待答，在「等待」页处理")
    }
}
