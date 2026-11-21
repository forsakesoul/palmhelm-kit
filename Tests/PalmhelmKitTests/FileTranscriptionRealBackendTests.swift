import AVFoundation
import XCTest
@testable import PalmhelmKit

/// 真实后端（不注入假实现）：opt-in，设 PALMHELM_FILE_TRANSCRIBE="<m4a 路径>|<locale>"。
/// 测试进程拿不到语音识别授权弹窗，所以只绕过授权这一步，其余全是生产路径。
final class FileTranscriptionRealBackendTests: XCTestCase {
    private struct NoPromptFactory: SpeechRecognitionFactory {
        let base = SystemSpeechRecognitionFactory()
        func availability(locale: String, isCurrent: @escaping @Sendable () -> Bool) async -> SpeechCaptureAvailability { await base.availability(locale: locale, isCurrent: isCurrent) }
        func speechAuthorized() async -> Bool { true }
        func makeSession(locale: String, backend: SpeechCaptureBackend, naturalFormat: AVAudioFormat?, isCurrent: @escaping @Sendable () -> Bool) async throws -> (any SpeechRecognitionSession)? {
            try await base.makeSession(locale: locale, backend: backend, naturalFormat: naturalFormat, isCurrent: isCurrent)
        }
    }

    func testRealBackendTranscribesWatchFormatClip() async throws {
        guard let spec = ProcessInfo.processInfo.environment["PALMHELM_FILE_TRANSCRIBE"] else { throw XCTSkip("opt-in") }
        let parts = spec.split(separator: "|").map(String.init)
        let data = try Data(contentsOf: URL(fileURLWithPath: parts[0]))
        let locale = parts.count > 1 ? parts[1] : "zh-CN"
        let availability = await SystemSpeechRecognitionFactory().availability(locale: locale, isCurrent: { true })
        print("PROBE availability backend=\(availability.backend) analyzerService=\(availability.analyzerServiceAvailable) localeSupported=\(availability.analyzerLocaleSupported) modelInstalled=\(availability.analyzerModelInstalled) legacyOnDevice=\(availability.speechRecognizerOnDevice)")
        let result = await OnDeviceFileTranscriber(factory: NoPromptFactory(), timeout: .seconds(30)).transcribe(data, locale: locale)
        print("PROBE result=\(result)")
        guard case .text = result else { return XCTFail("\(result)") }
    }
}
