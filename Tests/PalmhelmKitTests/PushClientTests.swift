import Foundation
import Testing
@testable import PalmhelmKit

@Suite(.serialized) struct PushClientTests {
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requests: [URLRequest] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.append(request)
            let data = Data(#"{"registered":true}"#.utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    @Test func registrationAndRevocationUseOwnBearerAndPath() async throws {
        Stub.requests = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stub.self]
        let c = BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "fake-device", session: URLSession(configuration: config))
        try await c.registerPush(token: String(repeating: "ab", count: 32), environment: "development")
        try await c.unregisterPush()
        #expect(Stub.requests.map(\.httpMethod) == ["PUT", "DELETE"])
        #expect(Stub.requests.allSatisfy { $0.url?.path == "/v1/devices/self/push" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fake-device" })
        await #expect(throws: BridgeError.decoding) { try await c.registerPush(token: "bad", environment: "development") }
        await #expect(throws: BridgeError.decoding) { try await c.registerPush(token: String(repeating: "a", count: 64), environment: "invalid") }
        #expect(Stub.requests.count == 2)
    }
    @Test func oldBridgeAndPushCapabilityDecode() throws {
        let old = try JSONDecoder().decode(BridgeMeta.self, from: Data(#"{"id":"b"}"#.utf8))
        let new = try JSONDecoder().decode(BridgeMeta.self, from: Data(#"{"id":"b","pushConfigured":true}"#.utf8))
        #expect(old.pushConfigured == nil); #expect(new.pushConfigured == true)
    }
}
