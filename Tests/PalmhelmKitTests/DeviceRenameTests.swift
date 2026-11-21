import Foundation
import Testing
@testable import PalmhelmKit

// O1-364 ④：设备名规则与自改名请求。使用本套件自己的 URLProtocol 桩（不与 MessageActionsTests 共享静态状态）。
@Suite(.serialized) struct DeviceRenameTests {
    final class RenameStub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var lastMethod: String?
        nonisolated(unsafe) static var lastPath: String?
        nonisolated(unsafe) static var lastBody: Data?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            RenameStub.lastMethod = request.httpMethod
            RenameStub.lastPath = request.url?.path
            RenameStub.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
                return data
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: RenameStub.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: RenameStub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func client() -> BridgeClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RenameStub.self]
        return BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "t", session: URLSession(configuration: cfg))
    }

    @Test func nameRuleKeepsOneLineTrimmedAndAtMost32Scalars() {
        #expect(DeviceNameRules.clean("  我的\n  iPhone  ") == "我的 iPhone")
        #expect(DeviceNameRules.clean("a\u{7}b\tc") == "a b c")
        #expect(DeviceNameRules.clean("   ") == nil, "空白不算名字")
        #expect(DeviceNameRules.clean(String(repeating: "x", count: 32)) != nil)
        #expect(DeviceNameRules.clean(String(repeating: "x", count: 33)) == nil, "超过 32 字符拒绝而不截断")
    }

    @Test func renameSelfPatchesOnlyTheNameAndReturnsTheDevice() async throws {
        RenameStub.status = 200
        RenameStub.body = Data(#"{"device":{"id":"d1","name":"小明的 iPhone","paused":false,"permission":"readonly"}}"#.utf8)
        let d = try await client().renameSelf("小明的 iPhone")
        #expect(d.name == "小明的 iPhone")
        #expect(RenameStub.lastMethod == "PATCH")
        #expect(RenameStub.lastPath == "/v1/devices/self")
        let body = try JSONSerialization.jsonObject(with: RenameStub.lastBody ?? Data()) as? [String: Any]
        #expect(Set(body?.keys.map { $0 } ?? []) == ["name"], "只上送名字")
    }

    @Test func renameFailureIsAStatusNotAFallback() async throws {
        RenameStub.status = 400
        RenameStub.body = Data(#"{"error":"invalid_name"}"#.utf8)
        await #expect(throws: BridgeError.http(status: 400)) { _ = try await client().renameSelf("x") }
    }
}
