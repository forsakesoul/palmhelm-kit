import Foundation
import Testing
@testable import PalmhelmKit

// #23 Kit：能力提示的解码与回退、发送 mode 的请求体、promote / withdraw 的固定错误码与严格校验、
// 撤回态的投影（Bridge 对外为 rejected）与文案。网络层用真实 BridgeClient + URLProtocol 桩。
@Suite(.serialized) struct MessageActionsTests {
    private let eventKey = "api:0123456789abcdef:6f1c2c1e-0000-4000-8000-000000000000"

    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var lastMethod: String?
        nonisolated(unsafe) static var lastPath: String?
        nonisolated(unsafe) static var lastBody: Data?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Stub.lastMethod = request.httpMethod
            Stub.lastPath = request.url?.path
            Stub.lastBody = request.httpBody ?? Stub.readStream(request.httpBodyStream) // URLSession 会把请求体转成流
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Stub.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        static func readStream(_ stream: InputStream?) -> Data? {
            guard let stream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
    }

    private func client() -> BridgeClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        return BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "t", session: URLSession(configuration: cfg))
    }
    private func reply(_ status: Int, _ json: String) {
        Stub.status = status
        Stub.body = Data(json.utf8)
    }
    private func bodyObject() throws -> [String: Any] {
        let data = try #require(Stub.lastBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: 能力提示

    @Test func capabilityDecodesWhenPresentAndIsNilWhenAbsent() throws {
        let withCap = #"{"projectName":"p","id":"t1","capabilities":{"steer":true}}"#
        let t1 = try JSONDecoder().decode(TargetSummary.self, from: Data(withCap.utf8))
        #expect(t1.capabilities == TargetCapabilities(steer: true))
        #expect(t1.steerAvailability == .available)

        let off = try JSONDecoder().decode(TargetSummary.self, from: Data(#"{"projectName":"p","id":"t1","capabilities":{"steer":false}}"#.utf8))
        #expect(off.steerAvailability == .unavailable)

        // 旧 Bridge 没有字段：nil，不是 false，界面不能当作「不支持」。
        let old = try JSONDecoder().decode(TargetSummary.self, from: Data(#"{"projectName":"p","id":"t1"}"#.utf8))
        #expect(old.capabilities == nil)
        #expect(old.steerAvailability == .unknown)
    }

    // MARK: 发送

    @Test func legacySendBodyIsUnchangedWhenModeAndAttributionAreOmitted() async throws {
        reply(200, #"{"received":true,"eventKey":"\#(eventKey)"}"#)
        let r = try await client().sendMessage(text: "你好", clientMsgId: UUID(uuidString: "6F1C2C1E-0000-4000-8000-000000000000")!)
        #expect(r.received)
        let body = try bodyObject()
        #expect(Set(body.keys) == ["clientMsgId", "text"], "旧请求体不多出字段")
        #expect(Stub.lastMethod == "POST")
    }

    @Test func sendCarriesModeWhenGiven() async throws {
        reply(200, #"{"received":true,"eventKey":"\#(eventKey)"}"#)
        _ = try await client().sendMessage(text: "补一句", mode: .steer)
        let body = try bodyObject()
        #expect(body["mode"] as? String == "steer")
        #expect(Set(body.keys) == ["clientMsgId", "text", "mode"])
    }

    @Test func sendErrorsMapToFixedCodes() async throws {
        let cases: [(Int, String, MessageActionError)] = [
            (409, #"{"error":"steer_unavailable"}"#, .steerUnavailable(reason: nil)),
            (409, #"{"error":"steer_unavailable","reason":"disabled"}"#, .steerUnavailable(reason: .disabled)),
            (409, #"{"error":"device_paused"}"#, .devicePaused),
            (403, #"{"error":"read_only"}"#, .readOnly),
            (400, #"{"error":"bad_request"}"#, .http(status: 400)),
            (409, #"{"error":"<script>"}"#, .http(status: 409)), // 非固定码不回显
        ]
        for (status, json, expected) in cases {
            reply(status, json)
            await #expect(throws: expected) { _ = try await client().sendMessage(text: "x", mode: .steer) }
        }
    }

    // MARK: promote / withdraw

    @Test func promoteSendsSteerModeAndValidatesExactShape() async throws {
        reply(200, #"{"eventKey":"\#(eventKey)","mode":"steer","state":"queued"}"#)
        let r = try await client().promote(eventKey: eventKey)
        #expect(r == PromoteResult(eventKey: eventKey, state: "queued"))
        #expect(Stub.lastMethod == "POST")
        #expect(Stub.lastPath?.hasSuffix("/promote") == true)
        #expect(try bodyObject()["mode"] as? String == "steer")
    }

    @Test func promoteRejectsWrongShapeAndWrongValues() async throws {
        for json in [
            #"{"eventKey":"\#(eventKey)","mode":"steer","state":"queued","extra":1}"#,   // 多出字段
            #"{"eventKey":"\#(eventKey)","mode":"queue","state":"queued"}"#,            // 模式不对
            #"{"eventKey":"api:other:x","mode":"steer","state":"queued"}"#,              // 不是这条消息
            #"{"eventKey":"\#(eventKey)","mode":"steer"}"#,                             // 缺字段
        ] {
            reply(200, json)
            await #expect(throws: MessageActionError.invalidResponse) { _ = try await client().promote(eventKey: eventKey) }
        }
    }

    @Test func promoteErrorsMapToFixedCodesWithState() async throws {
        reply(409, #"{"error":"conflict","state":"queued"}"#)
        await #expect(throws: MessageActionError.conflict(state: "queued")) { _ = try await client().promote(eventKey: eventKey) }
        reply(409, #"{"error":"not_promotable"}"#)
        await #expect(throws: MessageActionError.notPromotable) { _ = try await client().promote(eventKey: eventKey) }
        reply(409, #"{"error":"steer_unavailable","reason":"no_turn"}"#)
        await #expect(throws: MessageActionError.steerUnavailable(reason: .noTurn)) { _ = try await client().promote(eventKey: eventKey) }
        reply(401, #"{}"#)
        await #expect(throws: MessageActionError.http(status: 401)) { _ = try await client().promote(eventKey: eventKey) }
    }

    @Test func withdrawUsesDeleteAndValidatesShape() async throws {
        reply(200, #"{"withdrawn":true,"eventKey":"\#(eventKey)"}"#)
        let r = try await client().withdraw(eventKey: eventKey)
        #expect(r == WithdrawResult(eventKey: eventKey))
        #expect(Stub.lastMethod == "DELETE")
        reply(200, #"{"withdrawn":false,"eventKey":"\#(eventKey)"}"#)
        await #expect(throws: MessageActionError.invalidResponse) { _ = try await client().withdraw(eventKey: eventKey) }
    }

    @Test func withdrawConflictCarriesProjectedState() async throws {
        reply(409, #"{"error":"not_withdrawable","state":"started"}"#)
        await #expect(throws: MessageActionError.notWithdrawable(state: "started")) { _ = try await client().withdraw(eventKey: eventKey) }
        reply(404, #"{"error":"not_found"}"#)
        await #expect(throws: MessageActionError.notFound) { _ = try await client().withdraw(eventKey: eventKey) }
    }

    // MARK: 撤回态的投影与文案

    @Test func withdrawReasonDecidesTheStatusText() throws {
        let cmd = try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"k","inboxSeq":1,"text":"x","truncated":false,"origin":"api","state":"rejected","reason":"withdrawn"}"#.utf8))
        #expect(SendTimingCopy.statusText(state: cmd.state, reason: cmd.reason, locale: zhHansLocale) == "已撤回，未发出")
        // 旧 Bridge 没有 reason：沿用旧逻辑（rejected → 被拒绝）。
        let old = try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"k","inboxSeq":1,"text":"x","truncated":false,"origin":"api","state":"rejected"}"#.utf8))
        #expect(old.reason == nil)
        #expect(SendTimingCopy.statusText(state: old.state, reason: old.reason) == "被拒绝")
    }

    @Test func withdrawnIsProjectedAsRejectedAndNeverWorking() {
        // Bridge 对外把撤回投影为 rejected：应属于历史，不是「工作中」。
        #expect(CurrentActivity.phase(state: "rejected", targetId: "t1", linked: true, targets: ["t1"]) == .history)
        // 若将来出现未知状态（如直接的 withdrawn），也不能当成工作中或成功。
        #expect(CurrentActivity.phase(state: "withdrawn", targetId: "t1", linked: true, targets: ["t1"]) == .unsupported)
    }

    @Test func copyDistinguishesQueuedFromQueuedUseAndNeverSaysAdopted() {
        #expect(SendTimingCopy.queuedAfterTurn == "排队中 · 本轮结束后发送")
        #expect(SendTimingCopy.queuedUse != SendTimingCopy.queuedAfterTurn)
        #expect(CommandCopy.text(.merged, locale: zhHansLocale) == "已并入当前回合")
        #expect(SendTimingCopy.steerNoTurn == "没有运行中的回合，未发出")
        #expect(SendTimingCopy.steerDisabled == "补充功能未开启")
        #expect(CommandCopy.text(.withdrawn, locale: zhHansLocale) == "已撤回，未发出")
        for text in [SendTimingCopy.steerMerged, SendTimingCopy.steerUnavailable, SendTimingCopy.queuedUse] {
            #expect(!text.contains("采纳"))
        }
        #expect(SendTimingCopy.conflict(state: "started") == "状态已变化：处理中")
        #expect(SendTimingCopy.conflict(state: "<x>") == "状态已变化，请重新读取")
        #expect(SendTimingCopy.text(for: .readOnly) == SendTimingCopy.readOnly)
    }

    /// 真实 BridgeClient 的线上形状：send 与 promote 都带 mode（promote 严格为 send_now）。
    @Test func realBridgeClientSerializesBothSendAndPromote() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MessageActionsTests.Stub.self]
        let client = BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "test", session: URLSession(configuration: config))
        Stub.status = 200
        Stub.body = Data(#"{"received":true,"eventKey":"k"}"#.utf8)
        _ = try await client.sendMessage(text: "hello", mode: .sendNow)
        let sendBody = try #require(Stub.lastBody)
        #expect(String(decoding: sendBody, as: UTF8.self).contains(#""mode":"send_now""#))
        Stub.body = Data(#"{"eventKey":"k","mode":"send_now","state":"queued"}"#.utf8)
        _ = try await client.promote(eventKey: "k", mode: .sendNow)
        let promoteBody = try #require(Stub.lastBody)
        #expect(String(decoding: promoteBody, as: UTF8.self) == #"{"mode":"send_now"}"#)
        #expect(Stub.lastPath?.hasSuffix("/k/promote") == true)
    }
}
