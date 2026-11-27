import Foundation
import Testing
@testable import PalmhelmKit

// #155 h29b（D10）：实时活动远程更新的 Kit 传输。路径、方法、请求体、409 的 slotVer、404 不支持、
// 413/其它 4xx 被拒、503 与网络失败为暂时失败；发送前的本地校验失败不发请求。
@Suite(.serialized) struct LiveActivityTransportTests {
    private static let token = "cc00dd11ee22ff33"
    private static let stateJSON = Data(#"{"rows":[{"kind":"task","topic":"t","what":"在跑"}],"waitingCount":0,"runningCount":1}"#.utf8)

    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var failWith: URLError.Code?
        nonisolated(unsafe) static var lastMethod: String?
        nonisolated(unsafe) static var lastPath: String?
        nonisolated(unsafe) static var lastBody: Data?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Stub.lastMethod = request.httpMethod
            Stub.lastPath = request.url?.path
            Stub.lastBody = request.httpBody ?? Stub.readStream(request.httpBodyStream)
            if let code = Stub.failWith {
                client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            }
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
        Stub.failWith = nil
        Stub.lastMethod = nil
        Stub.lastPath = nil
        Stub.lastBody = nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        return BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "t", session: URLSession(configuration: cfg))
    }

    private func reply(_ status: Int, _ json: String) {
        Stub.status = status
        Stub.body = Data(json.utf8)
    }

    private func put(items: [LiveActivityRef] = [LiveActivityRef(kind: .task, key: "cmd-1")],
                     rowRefs: [LiveActivityRef]? = nil, token: String = token, environment: String = "production") -> LiveActivityPut {
        LiveActivityPut(activityId: "act-1", token: token, environment: environment, rev: 3, ifSlot: "boot:0",
                        stateJSON: Self.stateJSON, items: items, rowRefs: rowRefs ?? items)
    }

    private func bodyObject() throws -> [String: Any] {
        let data = try #require(Stub.lastBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: 请求形状

    @Test func putSendsFieldsAndEmbedsStateVerbatim() async throws {
        reply(200, #"{"slotVer":"boot:1"}"#)
        let outcome = try await client().putLiveActivity(put())
        #expect(outcome == .ok(slotVer: "boot:1"))
        #expect(Stub.lastMethod == "PUT")
        #expect(Stub.lastPath == "/v1/devices/self/live-activity")
        let body = try bodyObject()
        #expect(body["activityId"] as? String == "act-1")
        #expect(body["token"] as? String == Self.token)
        #expect(body["environment"] as? String == "production")
        #expect(body["rev"] as? Int == 3)
        #expect(body["ifSlot"] as? String == "boot:0")
        #expect((body["items"] as? [[String: String]]) == [["kind": "task", "key": "cmd-1"]])
        #expect((body["rowRefs"] as? [[String: String]]) == [["kind": "task", "key": "cmd-1"]])
        let state = try #require(body["state"] as? [String: Any])
        #expect(state["waitingCount"] as? Int == 0)
        #expect(state["runningCount"] as? Int == 1)
        #expect((state["rows"] as? [Any])?.count == 1)
    }

    @Test func deleteSendsIdentityAndSlot() async throws {
        reply(200, #"{"slotVer":"boot:2"}"#)
        let outcome = try await client().deleteLiveActivity(LiveActivityDelete(activityId: "act-1", token: Self.token, environment: "production", rev: 3, ifSlot: "boot:1"))
        #expect(outcome == .ok(slotVer: "boot:2"))
        #expect(Stub.lastMethod == "DELETE")
        let body = try bodyObject()
        #expect(body["ifSlot"] as? String == "boot:1")
        #expect(body["state"] == nil)
    }

    @Test func getReturnsCurrentSlot() async throws {
        reply(200, #"{"slotVer":"boot:0"}"#)
        let outcome = try await client().liveActivitySlot()
        #expect(outcome == .ok(slotVer: "boot:0"))
        #expect(Stub.lastMethod == "GET")
        #expect(Stub.lastBody == nil)
    }

    // MARK: 结果分类

    @Test func slotConflictCarriesCurrentSlot() async throws {
        reply(409, #"{"error":"slot_conflict","slotVer":"boot:7"}"#)
        #expect(try await client().putLiveActivity(put()) == .slotConflict(slotVer: "boot:7"))
    }

    @Test func conflictWithoutSlotIsARejection() async throws {
        reply(409, #"{"error":"bad_request"}"#)
        #expect(try await client().putLiveActivity(put()) == .rejected(status: 409))
    }

    @Test func notFoundMeansUnsupported() async throws {
        reply(404, #"{"error":"not_found"}"#)
        #expect(try await client().putLiveActivity(put()) == .unsupported)
        #expect(try await client().liveActivitySlot() == .unsupported)
    }

    @Test func tooLargeAndOtherClientErrorsAreRejections() async throws {
        reply(413, #"{"error":"too_large"}"#)
        #expect(try await client().putLiveActivity(put()) == .rejected(status: 413))
        reply(400, #"{"error":"bad_request"}"#)
        #expect(try await client().putLiveActivity(put()) == .rejected(status: 400))
    }

    @Test func serverErrorsAreTransient() async throws {
        reply(503, #"{"error":"unavailable"}"#)
        #expect(try await client().putLiveActivity(put()) == .transient)
        reply(500, "")
        #expect(try await client().deleteLiveActivity(LiveActivityDelete(activityId: "act-1", token: Self.token, environment: "production", rev: 3, ifSlot: "boot:0")) == .transient)
    }

    @Test func networkFailureAndTimeoutAreTransient() async throws {
        Stub.failWith = .timedOut
        #expect(try await client().putLiveActivity(put()) == .transient)
        Stub.failWith = .notConnectedToInternet
        #expect(try await client().liveActivitySlot() == .transient)
        Stub.failWith = nil
    }

    @Test func successWithoutSlotVersionIsADecodingError() async throws {
        reply(200, #"{"ok":true}"#)
        await #expect(throws: BridgeError.self) { try await client().putLiveActivity(put()) }
    }

    // MARK: 发送前校验（不发请求）

    @Test func invalidRequestsThrowWithoutSending() async throws {
        let c = client()
        let bad: [LiveActivityPut] = [
            put(token: "abc"),                                   // 奇数位、过短
            put(token: "zz00dd11ee22ff33"),                      // 非十六进制
            put(environment: "staging"),
            put(items: (0..<101).map { LiveActivityRef(kind: .task, key: "k\($0)") }, rowRefs: [LiveActivityRef(kind: .task, key: "k0")]),
            put(items: [LiveActivityRef(kind: .task, key: "a"), LiveActivityRef(kind: .task, key: "a")], rowRefs: [LiveActivityRef(kind: .task, key: "a")]),
            put(items: [LiveActivityRef(kind: .task, key: String(repeating: "k", count: 129))]),
            put(items: [LiveActivityRef(kind: .task, key: "a")], rowRefs: []),                                  // 与 rows 长度不同
            put(items: [LiveActivityRef(kind: .task, key: "a")], rowRefs: [LiveActivityRef(kind: .approval, key: "b")]), // 不属于 items
        ]
        for p in bad {
            await #expect(throws: LiveActivityRequestError.self) { try await c.putLiveActivity(p) }
        }
        #expect(Stub.lastMethod == nil, "校验失败不得发出请求")
    }

    @Test func revisionSlotAndItemsMustBePresentAndTokensAreAsciiHex() async throws {
        let c = client()
        var zeroRev = put(); zeroRev.rev = 0
        var noSlot = put(); noSlot.ifSlot = ""
        var noItems = put(items: [], rowRefs: []); noItems.rowRefs = []
        let fullWidthToken = "ｃｃ00dd11ee22ff33"  // 全角字符：Character 层面可能被当作数字，但不是 ASCII 十六进制
        for p in [zeroRev, noSlot, noItems, put(token: fullWidthToken)] {
            await #expect(throws: LiveActivityRequestError.self) { try await c.putLiveActivity(p) }
        }
        #expect(Stub.lastMethod == nil, "这些校验失败都不得发出请求")
    }

    @Test func stateThatIsNotAnObjectWithRowsIsRejected() async throws {
        var p = put()
        p.stateJSON = Data("[1,2]".utf8)
        await #expect(throws: LiveActivityRequestError.self) { try await client().putLiveActivity(p) }
        #expect(Stub.lastMethod == nil)
    }
}
