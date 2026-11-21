@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Device-only speech capture. Audio is streamed in memory; it is never written or sent to a service.
public final class OnDeviceSpeechCapture: SpeechCapture, @unchecked Sendable {
    public let events: AsyncStream<SpeechCaptureEvent>

    private enum Lifecycle: Equatable { case idle, preparing, recording, stopping, finished }
    private let continuation: AsyncStream<SpeechCaptureEvent>.Continuation
    private let audioHost: any CaptureAudioHost
    private let factory: any SpeechRecognitionFactory
    private let lock = NSLock()
    private var lifecycle = Lifecycle.idle
    private var audioHandle: (any CaptureAudioHandle)?
    private var recognition: (any SpeechRecognitionSession)?

    public convenience init() {
        self.init(audioHost: AVAudioEngineCaptureHost(), factory: SystemSpeechRecognitionFactory())
    }

    init(audioHost: any CaptureAudioHost, factory: any SpeechRecognitionFactory) {
        (events, continuation) = AsyncStream.makeStream(of: SpeechCaptureEvent.self)
        self.audioHost = audioHost
        self.factory = factory
    }

    /// Read-only capability query. It does not request microphone or speech permission and never installs a model.
    public static func availability(locale: String) async -> SpeechCaptureAvailability {
        await SystemSpeechRecognitionFactory().availability(locale: locale, isCurrent: { true })
    }

    /// Legacy-only capability check retained for existing Kit consumers.
    public static func supportsOnDevice(locale: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition ?? false
    }

    public func start(locale: String) async {
        guard beginPreparation() else { return }

        let isCurrent: @Sendable () -> Bool = { [weak self] in self?.isPreparing() ?? false }
        let availability = await factory.availability(locale: locale, isCurrent: isCurrent)
        guard isPreparing() else { return }
        guard availability.isAvailable else { finish(.failed(.unavailableOnDevice)); return }
        guard await factory.speechAuthorized() else {
            guard isPreparing() else { return }
            finish(.failed(.notAuthorized))
            return
        }
        guard isPreparing() else { return }

        let naturalFormat = audioHost.inputFormat()
        guard isPreparing() else { return }
        let session: (any SpeechRecognitionSession)?
        do {
            session = try await factory.makeSession(locale: locale, backend: availability.backend, naturalFormat: naturalFormat, isCurrent: isCurrent)
        } catch {
            guard isPreparing() else { return }
            finish(.failed(.engine))
            return
        }
        guard isPreparing() else { session?.cancel(); return }
        guard let session else { finish(.failed(.unavailableOnDevice)); return }
        attach(session)
    }

    private func beginPreparation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycle == .idle else { return false }
        lifecycle = .preparing
        return true
    }

    private func attach(_ session: any SpeechRecognitionSession) {
        lock.lock()
        guard lifecycle == .preparing else { lock.unlock(); session.cancel(); return }
        recognition = session
        lock.unlock()

        session.start { [weak self] update in
            Task { self?.receive(update) }
        }

        lock.lock()
        guard lifecycle == .preparing else { lock.unlock(); return }
        lock.unlock()

        do {
            let handle = try audioHost.start(
                targetFormat: session.inputFormat,
                receive: { [session] buffer, time in session.append(buffer, at: time) },
                failed: { [weak self] in Task { self?.receive(.failed(.engine)) } })

            lock.lock()
            guard lifecycle == .preparing else { lock.unlock(); handle.stop(); return }
            audioHandle = handle
            lifecycle = .recording
            continuation.yield(.started(Date()))
            lock.unlock()
        } catch {
            let shouldFinish: Bool
            let lateSession: (any SpeechRecognitionSession)?
            lock.lock()
            shouldFinish = lifecycle == .preparing
            if shouldFinish {
                lifecycle = .finished
                lateSession = recognition
                recognition = nil
            } else {
                lateSession = nil
            }
            lock.unlock()

            lateSession?.cancel()
            guard shouldFinish else { return }
            continuation.yield(.failed(.engine))
            continuation.finish()
        }
    }

    public func stop() {
        let handle: (any CaptureAudioHandle)?
        let session: (any SpeechRecognitionSession)?
        let stoppedDuringPreparation: Bool
        lock.lock()
        guard lifecycle == .recording else {
            if lifecycle == .preparing {
                lifecycle = .finished
                handle = audioHandle
                audioHandle = nil
                session = recognition
                recognition = nil
                stoppedDuringPreparation = true
            } else {
                handle = nil
                session = nil
                stoppedDuringPreparation = false
            }
            lock.unlock()
            handle?.stop()
            if stoppedDuringPreparation {
                session?.cancel()
                continuation.yield(.failed(.noSpeech))
                continuation.finish()
            }
            return
        }
        lifecycle = .stopping
        handle = audioHandle
        audioHandle = nil
        session = recognition
        lock.unlock()

        handle?.stop()
        session?.finish()
    }

    public func cancel() {
        lock.lock()
        guard lifecycle != .finished else { lock.unlock(); return }
        lifecycle = .finished
        let handle = audioHandle
        let session = recognition
        audioHandle = nil
        recognition = nil
        lock.unlock()

        handle?.stop()
        session?.cancel()
        continuation.finish()
    }

    private func isPreparing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lifecycle == .preparing
    }

    private func finish(_ event: SpeechCaptureEvent) {
        lock.lock()
        guard lifecycle != .finished else { lock.unlock(); return }
        lifecycle = .finished
        let handle = audioHandle
        let session = recognition
        audioHandle = nil
        recognition = nil
        lock.unlock()

        handle?.stop()
        session?.cancel()
        continuation.yield(event)
        continuation.finish()
    }

    private func receive(_ update: SpeechRecognitionUpdate) {
        let handle: (any CaptureAudioHandle)?
        let session: (any SpeechRecognitionSession)?
        lock.lock()
        let active = lifecycle == .recording || lifecycle == .stopping
        guard active || lifecycle == .preparing else { lock.unlock(); return }
        switch update {
        case let .partial(text):
            guard active else { lock.unlock(); return }
            handle = nil
            session = nil
            lock.unlock()
            continuation.yield(.partial(text))
        case let .final(text):
            guard active else { lock.unlock(); return }
            lifecycle = .finished
            handle = audioHandle
            audioHandle = nil
            recognition = nil
            session = nil
            lock.unlock()
            handle?.stop()
            continuation.yield(.final(text))
            continuation.finish()
        case let .failed(failure):
            lifecycle = .finished
            handle = audioHandle
            session = recognition
            audioHandle = nil
            recognition = nil
            lock.unlock()
            handle?.stop()
            session?.cancel()
            continuation.yield(.failed(failure))
            continuation.finish()
        }
    }
}

private struct AVAudioEngineCaptureHost: CaptureAudioHost {
    func inputFormat() -> AVAudioFormat? {
        let format = AVAudioEngine().inputNode.outputFormat(forBus: 0)
        return format.channelCount > 0 ? format : nil
    }

    func start(targetFormat: AVAudioFormat?, receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void, failed: @escaping @Sendable () -> Void) throws -> any CaptureAudioHandle {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.channelCount > 0 else { throw CaptureAudioError.noInput }
        let relay = try AudioBufferRelay(sourceFormat: sourceFormat, targetFormat: targetFormat, receive: receive, failed: failed)

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        #endif

        input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { buffer, time in
            relay.forward(buffer, time: time)
        }
        do {
            engine.prepare()
            try engine.start()
            return AudioEngineHandle(engine: engine)
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw error
        }
    }
}

final class AudioBufferRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat?
    private let receive: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private let failed: @Sendable () -> Void
    private var didFail = false

    init(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat?, receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void, failed: @escaping @Sendable () -> Void) throws {
        self.targetFormat = targetFormat
        self.receive = receive
        self.failed = failed
        if let targetFormat, !sourceFormat.isEqual(targetFormat) {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { throw CaptureAudioError.cannotConvert }
            self.converter = converter
        } else {
            converter = nil
        }
    }

    func forward(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let converter, let targetFormat else {
            receive(buffer, time)
            return
        }
        lock.lock()
        guard !didFail else { lock.unlock(); return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 1)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            didFail = true
            lock.unlock()
            failed()
            return
        }
        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            guard !provided else { inputStatus.pointee = .noDataNow; return nil }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        let shouldFail = conversionError != nil || status == .error
        if shouldFail { didFail = true }
        lock.unlock()
        if shouldFail {
            failed()
        } else if converted.frameLength > 0 {
            receive(converted, time)
        }
    }
}

private final class AudioEngineHandle: CaptureAudioHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?

    init(engine: AVAudioEngine) { self.engine = engine }

    func stop() {
        lock.lock()
        guard let engine else { lock.unlock(); return }
        self.engine = nil
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    deinit { stop() }
}

private enum CaptureAudioError: Error { case noInput, cannotConvert }
