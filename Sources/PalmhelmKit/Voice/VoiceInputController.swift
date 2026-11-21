import Foundation
import Observation

/// 一次录音的采集端。每一代（generation）新建一个实例；事件经 `events` 按序到达，结束或失败后流结束。
public protocol SpeechCapture: AnyObject, Sendable {
    var events: AsyncStream<SpeechCaptureEvent> { get }
    func start(locale: String) async
    /// 结束采集并等待最终结果（经 `events` 给出 final 或 failed）。
    func stop()
    /// 丢弃采集，不再产生事件。
    func cancel()
}

/// 语音输入的驱动：执行状态机给出的效果，把采集事件送回状态机。界面只读 `state`。
@MainActor
@Observable
public final class VoiceInputController {
    public private(set) var state = VoiceInputState()

    @ObservationIgnored private let makeCapture: @Sendable () -> any SpeechCapture
    @ObservationIgnored private let microphoneAllowed: @Sendable () async -> Bool
    @ObservationIgnored private var capture: (any SpeechCapture)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var captureGeneration: Int?
    @ObservationIgnored private var permissionTicket = 0

    public init(makeCapture: @escaping @Sendable () -> any SpeechCapture, microphoneAllowed: @escaping @Sendable () async -> Bool) {
        self.makeCapture = makeCapture
        self.microphoneAllowed = microphoneAllowed
    }

    /// 点「开始录音」时才请求麦克风权限；拒绝时不创建采集端。
    public func start(context: VoiceDraftContext, locale: String) async {
        permissionTicket &+= 1
        let ticket = permissionTicket
        let effects = state.reduce(.start(context, locale: locale))
        let startCapture = effects.compactMap { effect -> (Int, String)? in
            guard case let .startCapture(generation, locale) = effect else { return nil }
            return (generation, locale)
        }.first
        run(effects.filter { if case .startCapture = $0 { false } else { true } })
        guard let (generation, requestedLocale) = startCapture else { return }

        let allowed = await microphoneAllowed()
        guard ticket == permissionTicket, state.generation == generation, case .preparing = state.phase else { return }
        guard allowed else {
            receive(.failed(.notAuthorized), generation: generation)
            return
        }

        let fresh = makeCapture()
        capture = fresh
        captureGeneration = generation
        pump = Task { [weak self] in
            for await event in fresh.events {
                self?.receive(event, generation: generation)
            }
        }
        Task { await fresh.start(locale: requestedLocale) }
    }

    public func stop() {
        permissionTicket &+= 1
        run(state.reduce(.stop))
    }

    public func cancel() {
        permissionTicket &+= 1
        run(state.reduce(.cancel))
    }

    public func placement(into current: VoiceDraftContext) -> VoicePlacement {
        state.placement(into: current)
    }

    private func run(_ effects: [VoiceEffect]) {
        for effect in effects {
            switch effect {
            case .startCapture:
                break
            case let .stopCapture(generation):
                guard captureGeneration == generation else { continue }
                capture?.stop()
            case let .cancelCapture(generation):
                guard captureGeneration == generation else { continue }
                capture?.cancel()
                pump?.cancel()
                pump = nil
                capture = nil
                captureGeneration = nil
            }
        }
    }

    private func receive(_ event: SpeechCaptureEvent, generation: Int) {
        guard generation == state.generation else { return }
        run(state.reduce(.event(event, generation: generation)))
        switch event {
        case .final, .failed:
            guard captureGeneration == generation else { return }
            pump?.cancel()
            pump = nil
            capture = nil
            captureGeneration = nil
        case .started, .partial:
            break
        }
    }
}
