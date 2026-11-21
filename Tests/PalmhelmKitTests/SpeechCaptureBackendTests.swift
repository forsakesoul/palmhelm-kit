import AVFoundation
import XCTest
@testable import PalmhelmKit

private final class AudioStopCounter: CaptureAudioHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
}

private final class AudioHostStub: CaptureAudioHost, @unchecked Sendable {
    private let lock = NSLock()
    private let handle = AudioStopCounter()
    private var starts = 0
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopCount: Int { handle.stopCount }
    func inputFormat() -> AVAudioFormat? { nil }
    func start(targetFormat: AVAudioFormat?, receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void, failed: @escaping @Sendable () -> Void) throws -> any CaptureAudioHandle {
        lock.lock(); starts += 1; lock.unlock()
        return handle
    }
}

private final class BlockingAudioHost: CaptureAudioHost, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let handle = AudioStopCounter()

    func inputFormat() -> AVAudioFormat? { nil }
    func start(targetFormat: AVAudioFormat?, receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void, failed: @escaping @Sendable () -> Void) throws -> any CaptureAudioHandle {
        entered.signal()
        release.wait()
        return handle
    }
}

private final class RecognitionSessionStub: SpeechRecognitionSession, @unchecked Sendable {
    let inputFormat: AVAudioFormat? = nil
    private let lock = NSLock()
    private var onUpdate: (@Sendable (SpeechRecognitionUpdate) -> Void)?
    private var starts = 0
    private var finishes = 0
    private var cancels = 0
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var finishCount: Int { lock.lock(); defer { lock.unlock() }; return finishes }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancels }

    func start(onUpdate: @escaping @Sendable (SpeechRecognitionUpdate) -> Void) {
        lock.lock(); starts += 1; self.onUpdate = onUpdate; lock.unlock()
    }
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    func finish() { lock.lock(); finishes += 1; lock.unlock() }
    func cancel() { lock.lock(); cancels += 1; onUpdate = nil; lock.unlock() }
    func emit(_ update: SpeechRecognitionUpdate) {
        lock.lock(); let callback = onUpdate; lock.unlock()
        callback?(update)
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }
    var isEntered: Bool { entered }
    func release() { continuation?.resume(); continuation = nil }
}

private final class RecognitionFactoryStub: SpeechRecognitionFactory, @unchecked Sendable {
    let availability: SpeechCaptureAvailability
    let session: RecognitionSessionStub
    let availabilityGate: AsyncGate?
    let sessionGate: AsyncGate?

    init(availabilityGate: AsyncGate? = nil, sessionGate: AsyncGate? = nil) {
        availability = SpeechCaptureAvailability(analyzerServiceAvailable: false, analyzerLocaleSupported: false, analyzerModelInstalled: false, speechRecognizerOnDevice: true)
        session = RecognitionSessionStub()
        self.availabilityGate = availabilityGate
        self.sessionGate = sessionGate
    }

    func availability(locale: String, isCurrent: @escaping @Sendable () -> Bool) async -> SpeechCaptureAvailability {
        if let availabilityGate { await availabilityGate.wait() }
        return availability
    }
    func speechAuthorized() async -> Bool { true }
    func makeSession(locale: String, backend: SpeechCaptureBackend, naturalFormat: AVAudioFormat?, isCurrent: @escaping @Sendable () -> Bool) async throws -> (any SpeechRecognitionSession)? {
        if let sessionGate { await sessionGate.wait() }
        return session
    }
}

final class SpeechCaptureBackendTests: XCTestCase {
    private func signalArrived(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 2) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    func testBackendSelectionRequiresInstalledAnalyzerAndFallsBackOnlyOnDevice() {
        XCTAssertEqual(SpeechCaptureBackendSelection.choose(analyzerServiceAvailable: true, analyzerLocaleSupported: true, analyzerModelInstalled: true, speechRecognizerOnDevice: true), .speechAnalyzer)
        XCTAssertEqual(SpeechCaptureBackendSelection.choose(analyzerServiceAvailable: true, analyzerLocaleSupported: true, analyzerModelInstalled: false, speechRecognizerOnDevice: true), .speechRecognizer)
        XCTAssertEqual(SpeechCaptureBackendSelection.choose(analyzerServiceAvailable: true, analyzerLocaleSupported: false, analyzerModelInstalled: true, speechRecognizerOnDevice: false), .unavailableOnDevice)
        XCTAssertEqual(SpeechCaptureBackendSelection.choose(analyzerServiceAvailable: false, analyzerLocaleSupported: true, analyzerModelInstalled: true, speechRecognizerOnDevice: false), .unavailableOnDevice)
    }

    func testAnalyzerAccumulatorRetainsSeveralFinalSegmentsAndReplacesVolatileText() {
        var text = SpeechAnalyzerTextAccumulator()
        XCTAssertEqual(text.update("你好", isFinal: true), "你好")
        XCTAssertEqual(text.update("世界", isFinal: false), "你好世界")
        XCTAssertEqual(text.update("世界。", isFinal: true), "你好世界。")
        XCTAssertEqual(text.preview, "你好世界。")
    }

    func testFinalRecognitionReleasesAudioBeforeReturningFinalEvent() async {
        let host = AudioHostStub()
        let factory = RecognitionFactoryStub()
        let capture = OnDeviceSpeechCapture(audioHost: host, factory: factory)
        let stream = capture.events
        let events = Task { await Self.terminalEvents(from: stream) }

        await capture.start(locale: "en-US")
        factory.session.emit(.final("hello"))
        let observed = await events.value

        XCTAssertEqual(observed.count, 2)
        if case .started? = observed.first {} else { XCTFail("音频资源启动后应发 started") }
        XCTAssertEqual(observed.last, .final("hello"))
        XCTAssertEqual(host.startCount, 1)
        XCTAssertEqual(host.stopCount, 1)
        XCTAssertEqual(factory.session.cancelCount, 0, "正常终结由识别器自身结束，不再走取消分支")
    }

    func testRecognitionFailureStopsAudioAndCancelsSession() async {
        let host = AudioHostStub()
        let factory = RecognitionFactoryStub()
        let capture = OnDeviceSpeechCapture(audioHost: host, factory: factory)
        let stream = capture.events
        let events = Task { await Self.terminalEvents(from: stream) }

        await capture.start(locale: "en-US")
        factory.session.emit(.failed(.engine))
        let observed = await events.value

        XCTAssertEqual(observed.last, .failed(.engine))
        XCTAssertEqual(host.stopCount, 1)
        XCTAssertEqual(factory.session.cancelCount, 1)
    }

    func testStopFinishesInputAndRepeatedStopReleasesAudioOnlyOnce() async {
        let host = AudioHostStub()
        let factory = RecognitionFactoryStub()
        let capture = OnDeviceSpeechCapture(audioHost: host, factory: factory)
        let stream = capture.events
        let events = Task { await Self.terminalEvents(from: stream) }

        await capture.start(locale: "en-US")
        capture.stop()
        capture.stop()
        XCTAssertEqual(host.stopCount, 1)
        XCTAssertEqual(factory.session.finishCount, 1)
        factory.session.emit(.final("done"))
        let observed = await events.value
        XCTAssertEqual(observed.last, .final("done"))
        XCTAssertEqual(host.stopCount, 1)
    }

    func testRepeatedCancelStopsAudioAndSessionExactlyOnce() async {
        let host = AudioHostStub()
        let factory = RecognitionFactoryStub()
        let capture = OnDeviceSpeechCapture(audioHost: host, factory: factory)
        await capture.start(locale: "en-US")

        capture.cancel()
        capture.cancel()

        XCTAssertEqual(host.stopCount, 1)
        XCTAssertEqual(factory.session.cancelCount, 1)
    }

    func testCancelWhileCapabilityLookupIsPendingNeverStartsAudio() async {
        let gate = AsyncGate()
        let host = AudioHostStub()
        let factory = RecognitionFactoryStub(availabilityGate: gate)
        let capture = OnDeviceSpeechCapture(audioHost: host, factory: factory)
        let pending = Task { await capture.start(locale: "en-US") }
        await waitUntil { await gate.isEntered }

        capture.cancel()
        await gate.release()
        await pending.value

        XCTAssertEqual(host.startCount, 0)
        XCTAssertEqual(factory.session.startCount, 0)
    }

    func testCancelWhileRecognitionSessionIsBeingPreparedCancelsLateSession() async {
        let gate = AsyncGate()
        let host = AudioHostStub()
        let factory = RecognitionFactoryStub(sessionGate: gate)
        let capture = OnDeviceSpeechCapture(audioHost: host, factory: factory)
        let pending = Task { await capture.start(locale: "en-US") }
        await waitUntil { await gate.isEntered }

        capture.cancel()
        await gate.release()
        await pending.value

        XCTAssertEqual(host.startCount, 0)
        XCTAssertEqual(factory.session.startCount, 0)
        XCTAssertEqual(factory.session.cancelCount, 1, "迟到创建的识别会话必须立即释放")
    }

    func testCancelDuringAudioAcquisitionDoesNotWaitAndStopsLateHandle() async {
        let host = BlockingAudioHost()
        let factory = RecognitionFactoryStub()
        let capture = OnDeviceSpeechCapture(audioHost: host, factory: factory)
        let events = Task {
            var received: [SpeechCaptureEvent] = []
            for await event in capture.events { received.append(event) }
            return received
        }
        let starting = Task.detached { await capture.start(locale: "en-US") }

        guard signalArrived(host.entered) else {
            host.release.signal()
            await starting.value
            XCTFail("音频资源申请没有到达测试门")
            return
        }

        let cancelReturned = DispatchSemaphore(value: 0)
        let cancelling = Task.detached {
            capture.cancel()
            cancelReturned.signal()
        }
        let cancelledBeforeAcquisitionReturned = signalArrived(cancelReturned)
        host.release.signal()
        await starting.value
        await cancelling.value

        XCTAssertTrue(cancelledBeforeAcquisitionReturned, "取消不应等待正在申请音频资源的外部依赖")
        XCTAssertEqual(host.handle.stopCount, 1, "取消后才交付的音频句柄也必须释放一次")
        XCTAssertEqual(factory.session.cancelCount, 1)
        let received = await events.value
        XCTAssertTrue(received.isEmpty, "取消期间不得发 started 或终态识别结果")
    }

    private static func terminalEvents(from stream: AsyncStream<SpeechCaptureEvent>) async -> [SpeechCaptureEvent] {
        var events: [SpeechCaptureEvent] = []
        for await event in stream {
            events.append(event)
            if case .final = event { break }
            if case .failed = event { break }
        }
        return events
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("异步测试门未打开")
    }
}
