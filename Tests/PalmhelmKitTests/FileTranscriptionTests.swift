import AVFoundation
import XCTest
@testable import PalmhelmKit

/// 手表送来的 m4a（AAC 16 kHz 单声道）经本机识别后端转成文字：覆盖成功路径与每条失败路径。
private final class FileSessionStub: SpeechRecognitionSession, @unchecked Sendable {
    let inputFormat: AVAudioFormat?
    private let lock = NSLock()
    private var onUpdate: (@Sendable (SpeechRecognitionUpdate) -> Void)?
    private var frames: AVAudioFrameCount = 0
    private var cancels = 0
    let reply: SpeechRecognitionUpdate?

    init(inputFormat: AVAudioFormat? = nil, reply: SpeechRecognitionUpdate?) {
        self.inputFormat = inputFormat
        self.reply = reply
    }
    var appendedFrames: AVAudioFrameCount { lock.lock(); defer { lock.unlock() }; return frames }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancels }
    func start(onUpdate: @escaping @Sendable (SpeechRecognitionUpdate) -> Void) {
        lock.lock(); self.onUpdate = onUpdate; lock.unlock()
    }
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock(); frames += buffer.frameLength; lock.unlock()
    }
    func finish() {
        lock.lock(); let callback = onUpdate; lock.unlock()
        if let reply { callback?(reply) }
    }
    func cancel() { lock.lock(); cancels += 1; onUpdate = nil; lock.unlock() }
}

private final class FileFactoryStub: SpeechRecognitionFactory, @unchecked Sendable {
    let availability: SpeechCaptureAvailability
    let authorized: Bool
    let session: FileSessionStub?
    let makeError: Error?
    private let lock = NSLock()
    private var makes = 0
    var makeCount: Int { lock.lock(); defer { lock.unlock() }; return makes }

    init(available: Bool = true, authorized: Bool = true, session: FileSessionStub?, makeError: Error? = nil) {
        availability = SpeechCaptureAvailability(
            analyzerServiceAvailable: false, analyzerLocaleSupported: false, analyzerModelInstalled: false,
            speechRecognizerOnDevice: available)
        self.authorized = authorized
        self.session = session
        self.makeError = makeError
    }
    func availability(locale: String, isCurrent: @escaping @Sendable () -> Bool) async -> SpeechCaptureAvailability { availability }
    func speechAuthorized() async -> Bool { authorized }
    func makeSession(locale: String, backend: SpeechCaptureBackend, naturalFormat: AVAudioFormat?, isCurrent: @escaping @Sendable () -> Bool) async throws -> (any SpeechRecognitionSession)? {
        lock.withLock { makes += 1 }
        if let makeError { throw makeError }
        return session
    }
}

final class FileTranscriptionTests: XCTestCase {
    /// 与手表录音同一格式（AAC / 16 kHz / 单声道）的真实 m4a。
    private func watchClip(seconds: Double = 0.5) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            ])
            let count = AVAudioFrameCount(16000 * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
            buffer.frameLength = count
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(count) { samples[i] = 0.3 * sin(Float(i) * 0.1) }
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    private func transcriber(_ factory: FileFactoryStub, timeout: Duration = .seconds(5)) -> OnDeviceFileTranscriber {
        OnDeviceFileTranscriber(factory: factory, timeout: timeout)
    }

    func testDecodesClipIntoSessionAndReturnsFinalText() async throws {
        let session = FileSessionStub(reply: .final("你好"))
        let result = await transcriber(FileFactoryStub(session: session)).transcribe(try watchClip(), locale: "zh-CN")
        XCTAssertEqual(result, .text("你好"))
        XCTAssertGreaterThan(session.appendedFrames, 6000)
    }

    func testConvertsToTheFormatTheBackendAsksFor() async throws {
        let wanted = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let session = FileSessionStub(inputFormat: wanted, reply: .final("ok"))
        let result = await transcriber(FileFactoryStub(session: session)).transcribe(try watchClip(), locale: "en-US")
        XCTAssertEqual(result, .text("ok"))
        XCTAssertGreaterThan(session.appendedFrames, 20000, "0.5 s at 48 kHz")
    }

    func testTextIsTrimmedAndBlankBecomesNoSpeech() async throws {
        let padded = await transcriber(FileFactoryStub(session: FileSessionStub(reply: .final("  hi \n")))).transcribe(try watchClip(), locale: "en-US")
        XCTAssertEqual(padded, .text("hi"))
        let blank = await transcriber(FileFactoryStub(session: FileSessionStub(reply: .final("   ")))).transcribe(try watchClip(), locale: "en-US")
        XCTAssertEqual(blank, .failed(.noSpeech))
    }

    func testLanguageNotAvailableOnDeviceIsExplicitAndStartsNothing() async throws {
        let factory = FileFactoryStub(available: false, session: FileSessionStub(reply: .final("x")))
        let result = await transcriber(factory).transcribe(try watchClip(), locale: "ja-JP")
        XCTAssertEqual(result, .failed(.unavailableOnDevice))
        XCTAssertEqual(factory.makeCount, 0)
    }

    func testSpeechPermissionDeniedIsExplicit() async throws {
        let factory = FileFactoryStub(authorized: false, session: FileSessionStub(reply: .final("x")))
        let result = await transcriber(factory).transcribe(try watchClip(), locale: "zh-CN")
        XCTAssertEqual(result, .failed(.notAuthorized))
        XCTAssertEqual(factory.makeCount, 0)
    }

    func testSessionUnavailableOrThrowing() async throws {
        let none = await transcriber(FileFactoryStub(session: nil)).transcribe(try watchClip(), locale: "zh-CN")
        XCTAssertEqual(none, .failed(.unavailableOnDevice))
        struct Boom: Error {}
        let boom = await transcriber(FileFactoryStub(session: nil, makeError: Boom())).transcribe(try watchClip(), locale: "zh-CN")
        XCTAssertEqual(boom, .failed(.engine))
    }

    func testEngineFailureFromBackendIsReported() async throws {
        let session = FileSessionStub(reply: .failed(.engine))
        let result = await transcriber(FileFactoryStub(session: session)).transcribe(try watchClip(), locale: "zh-CN")
        XCTAssertEqual(result, .failed(.engine))
    }

    func testUndecodableAudioFailsWithoutStartingBackend() async {
        let factory = FileFactoryStub(session: FileSessionStub(reply: .final("x")))
        let result = await transcriber(factory).transcribe(Data("not audio".utf8), locale: "zh-CN")
        XCTAssertEqual(result, .failed(.engine))
        XCTAssertEqual(factory.makeCount, 0)
    }

    func testBackendThatNeverAnswersTimesOutAndIsCancelled() async throws {
        let session = FileSessionStub(reply: nil)
        let result = await transcriber(FileFactoryStub(session: session), timeout: .milliseconds(200)).transcribe(try watchClip(), locale: "zh-CN")
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(session.cancelCount, 1)
    }
}
