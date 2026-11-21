@preconcurrency import AVFoundation
import Foundation
import os

public enum FileTranscriptionResult: Equatable, Sendable {
    case text(String)
    case failed(VoiceFailure)
    /// 后端在时限内没有给出结果（已取消）。
    case timedOut
}

/// 把一段已录好的音频（如手表送来的 m4a）交给本机识别后端转成文字。
/// 与实时录音共用同一套后端与可用性判断：只在设备上识别，不回退云端；不需要麦克风权限，只需要语音识别授权。
enum VoiceLog {
    static let logger = Logger(subsystem: "app.palmhelm.kit", category: "voice-file")
    /// 只记阶段与错误类型/域/码，不含音频或文字内容。
    static func failure(_ stage: String, _ error: Error?) {
        guard let error else { logger.error("stage=\(stage, privacy: .public)"); return }
        let ns = error as NSError
        logger.error("stage=\(stage, privacy: .public) type=\(String(describing: type(of: error)), privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public)")
    }
}

public struct OnDeviceFileTranscriber: Sendable {
    private let factory: any SpeechRecognitionFactory
    private let timeout: Duration

    public init(timeout: Duration = .seconds(7)) {
        self.init(factory: SystemSpeechRecognitionFactory(), timeout: timeout)
    }

    init(factory: any SpeechRecognitionFactory, timeout: Duration) {
        self.factory = factory
        self.timeout = timeout
    }

    public func transcribe(_ audio: Data, locale: String) async -> FileTranscriptionResult {
        // AVAudioFile 只能从 URL 读；临时文件在本函数返回前删除。
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let file: AVAudioFile
        // 不能用 .completeFileProtection：手表请求常在 iPhone 锁屏时到达，那时这类文件既写不进也读不出。
        // 取“首次解锁后可用”，与手机锁屏后仍要工作的后台场景一致。
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: audio, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            file = try AVAudioFile(forReading: url)
        } catch {
            VoiceLog.failure("open-file", error)
            return .failed(.engine)
        }
        guard file.length > 0 else { return .failed(.noSpeech) }

        let availability = await factory.availability(locale: locale, isCurrent: { true })
        guard availability.isAvailable else { return .failed(.unavailableOnDevice) }
        guard await factory.speechAuthorized() else { return .failed(.notAuthorized) }
        let session: any SpeechRecognitionSession
        do {
            guard let made = try await factory.makeSession(locale: locale, backend: availability.backend, naturalFormat: file.processingFormat, isCurrent: { true }) else {
                return .failed(.unavailableOnDevice)
            }
            session = made
        } catch {
            VoiceLog.failure("make-session", error)
            return .failed(.engine)
        }
        return await run(session, file: file)
    }

    private func run(_ session: any SpeechRecognitionSession, file: AVAudioFile) async -> FileTranscriptionResult {
        let (updates, sink) = AsyncStream.makeStream(of: SpeechRecognitionUpdate.self)
        session.start { update in
            switch update {
            case .partial: break
            case .final, .failed: sink.yield(update); sink.finish()
            }
        }
        let relay: AudioBufferRelay
        do {
            relay = try AudioBufferRelay(sourceFormat: file.processingFormat, targetFormat: session.inputFormat, receive: { buffer, time in session.append(buffer, at: time) }, failed: { VoiceLog.failure("convert", nil); sink.yield(.failed(.engine)); sink.finish() })
        } catch {
            VoiceLog.failure("relay-init", error)
            session.cancel()
            return .failed(.engine)
        }
        let feed = Task.detached {
            while file.framePosition < file.length, !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                do { try file.read(into: buffer) } catch { VoiceLog.failure("read", error); sink.yield(.failed(.engine)); sink.finish(); return }
                if buffer.frameLength == 0 { break }
                relay.forward(buffer, time: AVAudioTime(sampleTime: file.framePosition, atRate: file.processingFormat.sampleRate))
            }
            session.finish()
        }
        let timeout = self.timeout
        let outcome: FileTranscriptionResult = await withTaskGroup(of: FileTranscriptionResult?.self) { group in
            group.addTask {
                for await update in updates {
                    switch update {
                    case let .final(text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? .failed(.noSpeech) : .text(trimmed)
                    case let .failed(failure): return .failed(failure)
                    case .partial: continue
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed(.engine)
        }
        feed.cancel()
        if outcome == .timedOut { session.cancel() }
        return outcome
    }
}
