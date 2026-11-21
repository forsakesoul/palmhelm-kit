import Foundation

// 纯函数式 SSE 分帧：按空行切事件，收集 id / event / data 行；data 多行以 \n 拼接。
// 不做网络，不做重连；调用方把收到的字节逐段 feed 进来，取出完整事件。
public struct SSEFrame: Sendable, Equatable {
    public var id: String?
    public var event: String?
    public var data: String
}

public struct SSEParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ chunk: Data) -> [SSEFrame] {
        buffer.append(chunk)
        var frames: [SSEFrame] = []
        while let range = buffer.firstRange(of: Data("\n\n".utf8)) {
            let raw = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let text = String(data: raw, encoding: .utf8), let frame = Self.parse(block: text) {
                frames.append(frame)
            }
        }
        return frames
    }

    static func parse(block: String) -> SSEFrame? {
        var id: String?
        var event: String?
        var data: [String] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(":") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon]
            var value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
            switch field {
            case "id": id = String(value)
            case "event": event = String(value)
            case "data": data.append(String(value))
            default: break
            }
        }
        if id == nil, event == nil, data.isEmpty { return nil }
        return SSEFrame(id: id, event: event, data: data.joined(separator: "\n"))
    }
}

public enum BridgeEventDecoder {
    private struct Sync: Decodable { var highWater: Int; var count: Int; var mode: String }
    private struct Ready: Decodable { var highWater: Int }
    private struct Progress: Decodable {
        var eventKey: String; var state: String; var reason: String?; var queue: QueueMeta?; var stop: StopDisposition?
        private enum CodingKeys: String, CodingKey { case eventKey, state, reason, stopDisposition }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            eventKey = try c.decode(String.self, forKey: .eventKey)
            state = try c.decode(String.self, forKey: .state)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            queue = try QueueMeta.decode(from: decoder)
            stop = StopDisposition.decode(c, forKey: .stopDisposition)
        }
    }
    private struct Targets: Decodable { var targets: [TargetSummary]; var spaces: [SpaceInfo]?; var currentBlocked: [CurrentBlocked]?; var currentBlockedFresh: Bool?; var observation: BridgeObservation? }

    public static func decode(_ frame: SSEFrame) -> BridgeEvent {
        let decoder = JSONDecoder()
        let data = Data(frame.data.utf8)
        switch frame.event.flatMap(SSEEventName.init(rawValue:)) {
        case .sync:
            if let s = try? decoder.decode(Sync.self, from: data) { return .sync(highWater: s.highWater, count: s.count, mode: s.mode) }
        case .outbox:
            if let item = try? decoder.decode(HistoryItem.self, from: data) { return .outbox(item) }
        case .ready:
            if let r = try? decoder.decode(Ready.self, from: data) { return .ready(highWater: r.highWater) }
        case .progress:
            if let p = try? decoder.decode(Progress.self, from: data) { return .progress(ProgressPayload(eventKey: p.eventKey, state: p.state, reason: p.reason, queue: p.queue, stop: p.stop)) }
        case .resetRequired:
            if let r = try? decoder.decode(Ready.self, from: data) { return .resetRequired(highWater: r.highWater) }
        case .inbound:
            if let c = try? decoder.decode(ApiCommand.self, from: data) { return .inbound(c) }
        case .approval:
            if let a = try? decoder.decode(ApprovalView.self, from: data) { return .approval(a) }
        case .targets:
            if let t = try? decoder.decode(Targets.self, from: data) { return .targets(t.targets, spaces: t.spaces, currentBlocked: t.currentBlocked, currentBlockedFresh: t.currentBlockedFresh, observation: t.observation) }
        case .device:
            if let d = try? decoder.decode(DeviceInfo.self, from: data) { return .device(d) }
        case .transcriptChanged:
            if let c = try? decoder.decode(TranscriptChange.self, from: data) { return .transcriptChanged(c) }
        case .ping:
            return .ping
        case .none:
            break
        }
        return .unknown(name: frame.event ?? "")
    }
}
