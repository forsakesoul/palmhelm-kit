@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

public enum SpeechCaptureBackend: String, Equatable, Sendable {
    case speechAnalyzer
    case speechRecognizer
    case unavailableOnDevice
}

public struct SpeechCaptureAvailability: Equatable, Sendable {
    public let backend: SpeechCaptureBackend
    public let analyzerServiceAvailable: Bool
    public let analyzerLocaleSupported: Bool
    public let analyzerModelInstalled: Bool
    public let speechRecognizerOnDevice: Bool

    init(analyzerServiceAvailable: Bool, analyzerLocaleSupported: Bool, analyzerModelInstalled: Bool, speechRecognizerOnDevice: Bool) {
        self.analyzerServiceAvailable = analyzerServiceAvailable
        self.analyzerLocaleSupported = analyzerLocaleSupported
        self.analyzerModelInstalled = analyzerModelInstalled
        self.speechRecognizerOnDevice = speechRecognizerOnDevice
        backend = SpeechCaptureBackendSelection.choose(
            analyzerServiceAvailable: analyzerServiceAvailable,
            analyzerLocaleSupported: analyzerLocaleSupported,
            analyzerModelInstalled: analyzerModelInstalled,
            speechRecognizerOnDevice: speechRecognizerOnDevice)
    }

    public var isAvailable: Bool { backend != .unavailableOnDevice }
}

enum SpeechCaptureBackendSelection {
    static func choose(analyzerServiceAvailable: Bool, analyzerLocaleSupported: Bool, analyzerModelInstalled: Bool, speechRecognizerOnDevice: Bool) -> SpeechCaptureBackend {
        if analyzerServiceAvailable && analyzerLocaleSupported && analyzerModelInstalled { return .speechAnalyzer }
        return speechRecognizerOnDevice ? .speechRecognizer : .unavailableOnDevice
    }
}

enum SpeechRecognitionUpdate: Sendable {
    case partial(String)
    case final(String)
    case failed(VoiceFailure)
}

protocol CaptureAudioHandle: Sendable {
    func stop()
}

protocol CaptureAudioHost: Sendable {
    func inputFormat() -> AVAudioFormat?
    func start(targetFormat: AVAudioFormat?, receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void, failed: @escaping @Sendable () -> Void) throws -> any CaptureAudioHandle
}

protocol SpeechRecognitionSession: AnyObject, Sendable {
    var inputFormat: AVAudioFormat? { get }
    func start(onUpdate: @escaping @Sendable (SpeechRecognitionUpdate) -> Void)
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
    func finish()
    func cancel()
}

protocol SpeechRecognitionFactory: Sendable {
    func availability(locale: String, isCurrent: @escaping @Sendable () -> Bool) async -> SpeechCaptureAvailability
    func speechAuthorized() async -> Bool
    func makeSession(locale: String, backend: SpeechCaptureBackend, naturalFormat: AVAudioFormat?, isCurrent: @escaping @Sendable () -> Bool) async throws -> (any SpeechRecognitionSession)?
}

struct SystemSpeechRecognitionFactory: SpeechRecognitionFactory {
    func availability(locale: String, isCurrent: @escaping @Sendable () -> Bool) async -> SpeechCaptureAvailability {
        let legacy = SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition == true
        var serviceAvailable = false
        var localeSupported = false
        var modelInstalled = false
        if #available(iOS 26, macOS 26, *) {
            serviceAvailable = SpeechTranscriber.isAvailable
            if serviceAvailable {
                let requested = Locale(identifier: locale)
                if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
                    guard isCurrent() else {
                        return SpeechCaptureAvailability(analyzerServiceAvailable: false, analyzerLocaleSupported: false, analyzerModelInstalled: false, speechRecognizerOnDevice: legacy)
                    }
                    localeSupported = true
                    let installed = await SpeechTranscriber.installedLocales
                    guard isCurrent() else {
                        return SpeechCaptureAvailability(analyzerServiceAvailable: false, analyzerLocaleSupported: false, analyzerModelInstalled: false, speechRecognizerOnDevice: legacy)
                    }
                    modelInstalled = installed.contains { $0.identifier == supported.identifier }
                }
            }
        }
        return SpeechCaptureAvailability(analyzerServiceAvailable: serviceAvailable, analyzerLocaleSupported: localeSupported, analyzerModelInstalled: modelInstalled, speechRecognizerOnDevice: legacy)
    }

    func speechAuthorized() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    func makeSession(locale: String, backend: SpeechCaptureBackend, naturalFormat: AVAudioFormat?, isCurrent: @escaping @Sendable () -> Bool) async throws -> (any SpeechRecognitionSession)? {
        switch backend {
        case .speechRecognizer:
            guard isCurrent(), let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.supportsOnDeviceRecognition else { return nil }
            return SFSpeechRecognitionSession(recognizer: recognizer)
        case .speechAnalyzer:
            guard #available(iOS 26, macOS 26, *), isCurrent(),
                  let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else { return nil }
            guard isCurrent() else { return nil }
            let installed = await SpeechTranscriber.installedLocales
            guard isCurrent(), installed.contains(where: { $0.identifier == supported.identifier }) else { return nil }
            let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            let modules: [any SpeechModule] = [transcriber]
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: naturalFormat) else {
                guard isCurrent(), let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.supportsOnDeviceRecognition else { return nil }
                return SFSpeechRecognitionSession(recognizer: recognizer)
            }
            guard isCurrent() else { return nil }
            let analyzer = SpeechAnalyzer(modules: modules)
            try await analyzer.prepareToAnalyze(in: format)
            guard isCurrent() else {
                let abandoned = SpeechAnalyzerRecognitionSession(analyzer: analyzer, transcriber: transcriber, inputFormat: format)
                abandoned.cancel()
                return nil
            }
            return SpeechAnalyzerRecognitionSession(analyzer: analyzer, transcriber: transcriber, inputFormat: format)
        case .unavailableOnDevice:
            return nil
        }
    }
}

private final class SFSpeechRecognitionSession: SpeechRecognitionSession, @unchecked Sendable {
    let inputFormat: AVAudioFormat? = nil
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: (@Sendable (SpeechRecognitionUpdate) -> Void)?
    private var lastText = ""
    private var finished = false

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
    }

    func start(onUpdate: @escaping @Sendable (SpeechRecognitionUpdate) -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        self.onUpdate = onUpdate
        lock.unlock()

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.receive(result: result, error: error)
        }
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
        } else {
            self.task = task
            lock.unlock()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) { request.append(buffer) }

    func finish() { request.endAudio() }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let task = self.task
        self.task = nil
        onUpdate = nil
        lock.unlock()
        task?.cancel()
    }

    private func receive(result: SFSpeechRecognitionResult?, error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if let result {
            lastText = result.bestTranscription.formattedString
            if result.isFinal {
                finished = true
                let update = onUpdate
                onUpdate = nil
                task = nil
                let text = lastText
                lock.unlock()
                update?(.final(text))
                return
            }
            let update = onUpdate
            let text = lastText
            lock.unlock()
            update?(.partial(text))
            return
        }
        guard let error else { lock.unlock(); return }
        VoiceLog.failure("sfspeech", error)
        finished = true
        let update = onUpdate
        onUpdate = nil
        task = nil
        let text = lastText
        lock.unlock()
        if text.isEmpty { update?(.failed(.noSpeech)) } else { update?(.final(text)) }
    }
}

struct SpeechAnalyzerTextAccumulator: Equatable, Sendable {
    private(set) var finalized = ""
    private(set) var volatile = ""

    mutating func update(_ text: String, isFinal: Bool) -> String {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        return preview
    }

    var preview: String { finalized + volatile }
}

@available(iOS 26, macOS 26, *)
private final class SpeechAnalyzerRecognitionSession: SpeechRecognitionSession, @unchecked Sendable {
    let inputFormat: AVAudioFormat?
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputs: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var onUpdate: (@Sendable (SpeechRecognitionUpdate) -> Void)?
    private var accumulator = SpeechAnalyzerTextAccumulator()
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var cancelled = false
    private var finishing = false

    init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, inputFormat: AVAudioFormat) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputFormat = inputFormat
        (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    func start(onUpdate: @escaping @Sendable (SpeechRecognitionUpdate) -> Void) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        self.onUpdate = onUpdate
        lock.unlock()

        let resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self.consume(text, isFinal: result.isFinal)
                }
            } catch {
                VoiceLog.failure("analyzer-results", error)
                self.emit(.failed(.engine))
            }
        }
        let analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await analyzer.start(inputSequence: inputs)
            } catch {
                VoiceLog.failure("analyzer-start", error)
                self.emit(.failed(.engine))
            }
        }
        lock.lock()
        if cancelled {
            lock.unlock()
            resultsTask.cancel()
            analysisTask.cancel()
        } else {
            self.resultsTask = resultsTask
            self.analysisTask = analysisTask
            lock.unlock()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        let canAppend = !cancelled && !finishing
        lock.unlock()
        if canAppend { continuation.yield(AnalyzerInput(buffer: buffer)) }
    }

    func finish() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        finishing = true
        continuation.finish()
        lock.unlock()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await analysisTask?.value
                await resultsTask?.value
                let finalText = self.finalTextIfActive()
                if let finalText { self.emit(.final(finalText)) }
            } catch {
                VoiceLog.failure("analyzer-finalize", error)
                self.emit(.failed(.engine))
            }
        }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        onUpdate = nil
        continuation.finish()
        let analysisTask = self.analysisTask
        let resultsTask = self.resultsTask
        lock.unlock()
        analysisTask?.cancel()
        resultsTask?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func consume(_ text: String, isFinal: Bool) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        let preview = accumulator.update(text, isFinal: isFinal)
        let update = onUpdate
        lock.unlock()
        update?(.partial(preview))
    }

    private func finalTextIfActive() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cancelled ? nil : accumulator.preview
    }

    private func emit(_ update: SpeechRecognitionUpdate) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        let callback = onUpdate
        if case .final = update { onUpdate = nil }
        lock.unlock()
        callback?(update)
    }
}
