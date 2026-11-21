import XCTest
@testable import PalmhelmKit

/// 假识别器：测试用事件驱动状态机；每次 start 由工厂新建一个实例，便于断言代际隔离。
final class FakeSpeechCapture: SpeechCapture, @unchecked Sendable {
    let events: AsyncStream<SpeechCaptureEvent>
    private let continuation: AsyncStream<SpeechCaptureEvent>.Continuation
    private let emitsStartedImmediately: Bool
    private(set) var startedLocale: String?
    private(set) var stopCalls = 0
    private(set) var cancelCalls = 0

    init(emitsStartedImmediately: Bool = true) {
        self.emitsStartedImmediately = emitsStartedImmediately
        (events, continuation) = AsyncStream.makeStream(of: SpeechCaptureEvent.self)
    }

    func start(locale: String) async {
        startedLocale = locale
        if emitsStartedImmediately { continuation.yield(.started(Date())) }
    }
    func markStarted(at date: Date) { continuation.yield(.started(date)) }
    func stop() { stopCalls += 1 }
    func cancel() {
        cancelCalls += 1
        continuation.finish()
    }
    func emit(_ event: SpeechCaptureEvent) { continuation.yield(event) }
}

/// 记录每次工厂创建的采集端（只在主 actor 上使用）。
final class CaptureFactory: @unchecked Sendable {
    private let emitsStartedImmediately: Bool
    private(set) var made: [FakeSpeechCapture] = []
    init(emitsStartedImmediately: Bool = true) { self.emitsStartedImmediately = emitsStartedImmediately }
    func make() -> any SpeechCapture {
        let c = FakeSpeechCapture(emitsStartedImmediately: emitsStartedImmediately)
        made.append(c)
        return c
    }
}

private actor PermissionReplies {
    private var continuations: [CheckedContinuation<Bool, Never>?] = []

    func request() async -> Bool {
        await withCheckedContinuation { continuations.append($0) }
    }

    var pendingCount: Int { continuations.count }

    func resolve(_ index: Int, allowed: Bool) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else { return }
        continuations[index] = nil
        continuation.resume(returning: allowed)
    }
}

@MainActor
final class VoiceInputTests: XCTestCase {
    private func context(version: Int = 1, thread: String = "t1") -> VoiceDraftContext {
        VoiceDraftContext(accountId: "a1", threadId: thread, draftVersion: version, cursor: 0)
    }

    private func makeController(micAllowed: Bool = true, emitsStartedImmediately: Bool = true) -> (VoiceInputController, CaptureFactory) {
        let factory = CaptureFactory(emitsStartedImmediately: emitsStartedImmediately)
        let controller = VoiceInputController(
            makeCapture: { factory.make() },
            microphoneAllowed: { micAllowed })
        return (controller, factory)
    }

    /// 事件经 AsyncStream 异步送达：轮询到条件成立（或超时后交给断言失败）。
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func waitForPermissions(_ replies: PermissionReplies, count: Int) async {
        for _ in 0..<500 {
            if await replies.pendingCount == count { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("权限等待数未达到 \(count)")
    }

    private func startRecording(_ controller: VoiceInputController, context: VoiceDraftContext, locale: String) async {
        await controller.start(context: context, locale: locale)
        await settle { controller.state.recordingStartedAt != nil }
    }

    func testCancelDuringPermissionWaitDoesNotStartCaptureWhenAllowed() async {
        let replies = PermissionReplies()
        let factory = CaptureFactory()
        let controller = VoiceInputController(makeCapture: { factory.make() }, microphoneAllowed: { await replies.request() })
        let pending = Task { await controller.start(context: context(), locale: "zh-CN") }
        await waitForPermissions(replies, count: 1)

        controller.cancel()
        await replies.resolve(0, allowed: true)
        await pending.value

        XCTAssertEqual(controller.state.phase, .idle)
        XCTAssertTrue(factory.made.isEmpty, "取消后获准不得创建采集端")
    }

    func testCancelDuringPermissionWaitDoesNotRestoreDeniedState() async {
        let replies = PermissionReplies()
        let factory = CaptureFactory()
        let controller = VoiceInputController(makeCapture: { factory.make() }, microphoneAllowed: { await replies.request() })
        let pending = Task { await controller.start(context: context(), locale: "zh-CN") }
        await waitForPermissions(replies, count: 1)

        controller.cancel()
        await replies.resolve(0, allowed: false)
        await pending.value

        XCTAssertEqual(controller.state.phase, .idle, "取消后拒权返回不得恢复旧代错误页")
        XCTAssertTrue(factory.made.isEmpty)
    }

    func testStopDuringPermissionWaitInvalidatesPendingStart() async {
        let replies = PermissionReplies()
        let factory = CaptureFactory()
        let controller = VoiceInputController(makeCapture: { factory.make() }, microphoneAllowed: { await replies.request() })
        let pending = Task { await controller.start(context: context(), locale: "zh-CN") }
        await waitForPermissions(replies, count: 1)

        controller.stop()
        await replies.resolve(0, allowed: true)
        await pending.value

        XCTAssertEqual(controller.state.phase, .idle)
        XCTAssertTrue(factory.made.isEmpty, "停止后迟到授权不得启动采集端")
    }

    func testOverlappingPermissionRequestsOnlyNewestStartWins() async {
        let replies = PermissionReplies()
        let factory = CaptureFactory()
        let controller = VoiceInputController(makeCapture: { factory.make() }, microphoneAllowed: { await replies.request() })
        let first = Task { await controller.start(context: context(version: 1), locale: "zh-CN") }
        await waitForPermissions(replies, count: 1)
        let second = Task { await controller.start(context: context(version: 2), locale: "en-US") }
        await waitForPermissions(replies, count: 2)

        await replies.resolve(1, allowed: true)
        await second.value
        await replies.resolve(0, allowed: true)
        await first.value

        XCTAssertEqual(controller.state.context?.draftVersion, 2)
        XCTAssertEqual(factory.made.count, 1, "旧权限请求不得在新一代之后再创建采集端")
    }

    func testStartRecordsContextAndStartsCapture() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(), locale: "zh-CN")
        XCTAssertEqual(c.state.phase, .recording(partial: ""))
        XCTAssertEqual(c.state.context, context())
        await settle { f.made.first?.startedLocale != nil }
        XCTAssertEqual(f.made.first?.startedLocale, "zh-CN")
    }

    func testRecordingClockBeginsOnlyAfterCaptureReportsStarted() async {
        let (controller, factory) = makeController(emitsStartedImmediately: false)
        await controller.start(context: context(), locale: "zh-CN")
        XCTAssertEqual(controller.state.phase, .preparing)
        XCTAssertNil(controller.state.recordingStartedAt)

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        factory.made[0].markStarted(at: startedAt)
        await settle { controller.state.recordingStartedAt == startedAt }
        XCTAssertEqual(controller.state.phase, .recording(partial: ""))
        XCTAssertEqual(controller.state.recordingStartedAt, startedAt)
    }

    func testPartialUpdatesRecordingText() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(), locale: "zh-CN")
        f.made[0].emit(.partial("你好"))
        await settle { c.state.phase == .recording(partial: "你好") }
        XCTAssertEqual(c.state.phase, .recording(partial: "你好"))
    }

    func testStopThenFinalGivesResult() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(), locale: "en-US")
        c.stop()
        XCTAssertEqual(f.made[0].stopCalls, 1)
        XCTAssertEqual(c.state.phase, .transcribing(partial: ""))
        f.made[0].emit(.final("hello world"))
        await settle { c.state.phase == .result("hello world") }
        XCTAssertEqual(c.state.phase, .result("hello world"))
    }

    func testResultIsTrimmed() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(), locale: "en-US")
        c.stop()
        f.made[0].emit(.final("  hi \n"))
        await settle { c.state.phase == .result("hi") }
        XCTAssertEqual(c.state.phase, .result("hi"))
    }

    func testEmptyFinalFailsWithNoSpeechAndCannotPlace() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(), locale: "ja-JP")
        c.stop()
        f.made[0].emit(.final("   "))
        await settle { c.state.phase == .failed(.noSpeech) }
        XCTAssertEqual(c.state.phase, .failed(.noSpeech))
        XCTAssertEqual(c.placement(into: context()), .nothingToPlace)
    }

    func testUnavailableOnDeviceFailsWithoutResult() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(), locale: "ja-JP")
        f.made[0].emit(.failed(.unavailableOnDevice))
        await settle { c.state.phase == .failed(.unavailableOnDevice) }
        XCTAssertEqual(c.state.phase, .failed(.unavailableOnDevice))
        XCTAssertEqual(c.placement(into: context()), .nothingToPlace)
    }

    func testCancelDropsLateFinalFromCancelledCapture() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(), locale: "zh-CN")
        c.cancel()
        XCTAssertEqual(f.made[0].cancelCalls, 1)
        XCTAssertEqual(c.state.phase, .idle)
        XCTAssertNil(c.state.context)
        f.made[0].emit(.final("迟到的结果"))
        await Task.yield()
        XCTAssertEqual(c.state.phase, .idle, "取消后的迟到结果不得写入状态")
    }

    func testRerecordCancelsPreviousAndIgnoresItsLateResult() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(), locale: "zh-CN")
        await startRecording(c, context: context(), locale: "zh-CN")
        XCTAssertEqual(f.made.count, 2)
        XCTAssertEqual(f.made[0].cancelCalls, 1, "重录必须取消上一代采集")
        f.made[0].emit(.partial("旧"))
        f.made[0].emit(.final("旧结果"))
        await Task.yield()
        XCTAssertEqual(c.state.phase, .recording(partial: ""), "上一代的迟到事件不得影响新一代")
        f.made[1].emit(.partial("新"))
        await settle { c.state.phase == .recording(partial: "新") }
        XCTAssertEqual(c.state.phase, .recording(partial: "新"))
    }

    func testStartWhileTranscribingDiscardsPreviousResult() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(), locale: "zh-CN")
        c.stop()
        await startRecording(c, context: context(version: 2), locale: "zh-CN")
        f.made[0].emit(.final("上一代的文字"))
        f.made[1].emit(.final("新文字"))
        await settle { c.state.phase == .result("新文字") }
        XCTAssertEqual(c.state.phase, .result("新文字"))
        XCTAssertEqual(c.state.context?.draftVersion, 2)
    }

    func testRestartLeavesExactlyOneLiveCapture() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(), locale: "zh-CN")
        await startRecording(c, context: context(), locale: "zh-CN")
        await startRecording(c, context: context(), locale: "zh-CN")
        XCTAssertEqual(f.made.map(\.cancelCalls), [1, 1, 0], "每代最多一个未取消的采集端")
    }

    func testMicrophoneDeniedNeverStartsCapture() async {
        let (c, f) = makeController(micAllowed: false)
        await c.start(context: context(), locale: "zh-CN")
        XCTAssertEqual(c.state.phase, .failed(.notAuthorized))
        XCTAssertTrue(f.made.isEmpty, "权限被拒时不得创建采集端")
    }

    func testStopWhileIdleIsNoop() {
        let (c, f) = makeController()
        c.stop()
        XCTAssertEqual(c.state.phase, .idle)
        XCTAssertTrue(f.made.isEmpty)
    }

    func testPlaceInsertsWhenDraftUnchanged() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(version: 3), locale: "zh-CN")
        c.stop()
        f.made[0].emit(.final("明天开会"))
        await settle { c.state.phase == .result("明天开会") }
        XCTAssertEqual(c.placement(into: context(version: 3)), .insert("明天开会"))
    }

    func testPlaceAsksWhenDraftVersionChanged() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(version: 3), locale: "zh-CN")
        c.stop()
        f.made[0].emit(.final("明天开会"))
        await settle { c.state.phase == .result("明天开会") }
        XCTAssertEqual(c.placement(into: context(version: 4)), .needsChoice("明天开会"))
    }

    func testPlaceRefusesWhenThreadChanged() async {
        let (c, f) = makeController()
        await startRecording(c, context: context(thread: "t1"), locale: "zh-CN")
        c.stop()
        f.made[0].emit(.final("给 t1 的话"))
        await settle { c.state.phase == .result("给 t1 的话") }
        XCTAssertEqual(c.placement(into: context(thread: "t2")), .wrongThread, "结果只能回到原会话")
    }

    func testInsertionAppendsAtCursorWithSeparator() {
        let r = VoiceDraftInsertion.apply(draft: "买菜", cursor: 2, text: "明天")
        XCTAssertEqual(r.draft, "买菜\n明天")
        XCTAssertEqual(r.cursor, 5)
    }

    func testInsertionClampsCursorAndCountsCharacters() {
        // 光标超出长度时钳到末尾；表情是一个字符，不按码元计。
        let r = VoiceDraftInsertion.apply(draft: "👍", cursor: 99, text: "好")
        XCTAssertEqual(r.draft, "👍\n好")
        XCTAssertEqual(r.cursor, 3)
    }

    func testInsertionSkipsSeparatorAfterNewlineOrWhenEmpty() {
        XCTAssertEqual(VoiceDraftInsertion.apply(draft: "a\n", cursor: 2, text: "b").draft, "a\nb")
        XCTAssertEqual(VoiceDraftInsertion.apply(draft: "", cursor: 0, text: "b").draft, "b")
    }
}
