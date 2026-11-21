import Foundation

// 语音输入的纯状态机（#66 S1）：不碰麦克风、识别器与界面。
// 不变量：同一时间只有一代（generation）在途；重录或取消让上一代的迟到事件失效；放入只改本地草稿，从不发送。

/// 识别失败的固定枚举；界面按枚举给说明，不回显识别器原文。
public enum VoiceFailure: Equatable, Sendable {
    /// 该语言不支持设备端识别：明确不可用，不回退到云识别。
    case unavailableOnDevice
    /// 麦克风或语音识别权限被拒绝或受限。
    case notAuthorized
    /// 结束时没有识别到文字。
    case noSpeech
    /// 其余识别错误。
    case engine
}

public enum SpeechCaptureEvent: Equatable, Sendable {
    case started(Date)
    case partial(String)
    case final(String)
    case failed(VoiceFailure)
}

/// 录音层打开时冻结的草稿位置：放入时用它判断草稿是否仍是同一份。
public struct VoiceDraftContext: Equatable, Sendable {
    public let accountId: String
    public let threadId: String
    public let draftVersion: Int
    public let cursor: Int

    public init(accountId: String, threadId: String, draftVersion: Int, cursor: Int) {
        self.accountId = accountId
        self.threadId = threadId
        self.draftVersion = draftVersion
        self.cursor = cursor
    }
}

public enum VoicePhase: Equatable, Sendable {
    case idle
    case preparing
    case recording(partial: String)
    case transcribing(partial: String)
    case result(String)
    case failed(VoiceFailure)
}

public enum VoiceInputAction: Equatable, Sendable {
    case start(VoiceDraftContext, locale: String)
    case stop
    case cancel
    case event(SpeechCaptureEvent, generation: Int)
}

public enum VoiceEffect: Equatable, Sendable {
    case startCapture(generation: Int, locale: String)
    case stopCapture(generation: Int)
    case cancelCapture(generation: Int)
}

/// 当前草稿与冻结上下文比较后的放入结果。
public enum VoicePlacement: Equatable, Sendable {
    /// 可以直接放入（文字已去首尾空白）。
    case insert(String)
    /// 草稿或光标在录音期间变过：请用户选择追加或取消，不静默覆盖。
    case needsChoice(String)
    /// 账户或线程已变：不放入，提示回到原会话。
    case wrongThread
    /// 没有可放入的文字（空结果不能放入）。
    case nothingToPlace
}

public struct VoiceInputState: Equatable, Sendable {
    public private(set) var phase: VoicePhase = .idle
    public private(set) var context: VoiceDraftContext?
    public private(set) var generation = 0
    public private(set) var locale: String?
    public private(set) var recordingStartedAt: Date?

    public init() {}

    public var isActive: Bool {
        switch phase {
        case .preparing, .recording, .transcribing: true
        case .idle, .result, .failed: false
        }
    }

    @discardableResult
    public mutating func reduce(_ action: VoiceInputAction) -> [VoiceEffect] {
        switch action {
        case let .start(context, locale):
            var effects: [VoiceEffect] = []
            // 重录：取消上一代，它之后到达的事件因代不同被丢弃。
            if isActive { effects.append(.cancelCapture(generation: generation)) }
            generation += 1
            self.context = context
            self.locale = locale
            recordingStartedAt = nil
            phase = .preparing
            effects.append(.startCapture(generation: generation, locale: locale))
            return effects

        case .stop:
            if case .preparing = phase {
                generation += 1
                phase = .idle
                context = nil
                locale = nil
                recordingStartedAt = nil
                return [.cancelCapture(generation: generation - 1)]
            }
            guard case let .recording(partial) = phase else { return [] }
            phase = .transcribing(partial: partial)
            return [.stopCapture(generation: generation)]

        case .cancel:
            let effects: [VoiceEffect] = isActive ? [.cancelCapture(generation: generation)] : []
            generation += 1
            phase = .idle
            context = nil
            locale = nil
            recordingStartedAt = nil
            return effects

        case let .event(event, gen):
            guard gen == generation, isActive else { return [] }
            switch event {
            case let .started(at):
                guard case .preparing = phase else { return [] }
                recordingStartedAt = at
                phase = .recording(partial: "")
            case let .partial(text):
                if isTranscribing {
                    phase = .transcribing(partial: text)
                } else if case .recording = phase {
                    phase = .recording(partial: text)
                }
            case let .final(text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                recordingStartedAt = nil
                phase = trimmed.isEmpty ? .failed(.noSpeech) : .result(trimmed)
            case let .failed(failure):
                recordingStartedAt = nil
                phase = .failed(failure)
            }
            return []
        }
    }

    /// 放入前的判定。只比较冻结上下文与当前草稿，不做发送守卫（那些沿用原 composer 的路径）。
    public func placement(into current: VoiceDraftContext) -> VoicePlacement {
        guard let frozen = context, case let .result(text) = phase else { return .nothingToPlace }
        guard frozen.accountId == current.accountId, frozen.threadId == current.threadId else { return .wrongThread }
        return frozen.draftVersion == current.draftVersion ? .insert(text) : .needsChoice(text)
    }

    private var isTranscribing: Bool {
        if case .transcribing = phase { return true }
        return false
    }
}

/// 在草稿的光标处插入文字。光标按字符计；前面已有内容且不以换行结束时补一个换行，避免与上一段粘连。
public enum VoiceDraftInsertion {
    public static func apply(draft: String, cursor: Int, text: String) -> (draft: String, cursor: Int) {
        let chars = Array(draft)
        let at = min(max(cursor, 0), chars.count)
        let head = String(chars[..<at])
        let tail = String(chars[at...])
        let separator = (!head.isEmpty && head.last != "\n") ? "\n" : ""
        let inserted = separator + text
        return (head + inserted + tail, at + inserted.count)
    }
}
