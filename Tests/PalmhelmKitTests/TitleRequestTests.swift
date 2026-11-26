import Foundation
import Testing
@testable import PalmhelmKit

// #134：对话自定义名的请求形状与应答解析（PUT /v1/targets/{id}/title）。使用本套件自己的 URLProtocol 桩。
@Suite(.serialized) struct TitleRequestTests {
    final class TitleStub: URLProtocol {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var lastMethod: String?
        nonisolated(unsafe) static var lastPath: String?
        nonisolated(unsafe) static var lastURL: String?
        nonisolated(unsafe) static var lastBody: Data?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            TitleStub.lastMethod = request.httpMethod
            TitleStub.lastPath = request.url?.path
            TitleStub.lastURL = request.url?.absoluteString
            // URLSession 上传时正文在 httpBodyStream 里（同 DeviceRenameTests 的读取方式）。
            TitleStub.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
                return data
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: TitleStub.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: TitleStub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client() -> BridgeClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TitleStub.self]
        return BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "t", session: URLSession(configuration: cfg))
    }

    private func bodyKeys(_ data: Data?) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])
    }

    @Test func setTitleSendsPutWithTitleKeyAndParsesTheResult() async throws {
        TitleStub.status = 200
        TitleStub.body = Data(#"{"customTitle":"周报","herdr":"synced"}"#.utf8)
        let r = try await client().setTitle(targetId: "target:demo", title: "周报")
        #expect(r == .ok(customTitle: "周报", herdr: "synced"))
        #expect(TitleStub.lastMethod == "PUT")
        #expect(TitleStub.lastPath == "/v1/targets/target:demo/title")
        let body = try bodyKeys(TitleStub.lastBody)
        #expect(body["title"] as? String == "周报")
        #expect(Set(body.keys) == ["title"], "只上送 title")
    }

    @Test func clearingSendsAnExplicitNullTitleKey() async throws {
        TitleStub.status = 200
        TitleStub.body = Data(#"{"customTitle":null,"herdr":"pane_gone"}"#.utf8)
        let r = try await client().setTitle(targetId: "t1", title: nil)
        #expect(r == .ok(customTitle: nil, herdr: "pane_gone"))
        let raw = String(data: TitleStub.lastBody ?? Data(), encoding: .utf8) ?? ""
        #expect(raw == #"{"title":null}"#, "清除时键必须存在且为 null：\(raw)")
    }

    // 保留字符 ID 按单个路径段编码：/ % ? # 都不能切分路径或变成查询串。
    @Test func reservedCharactersInTheIdStayOneEncodedSegment() async throws {
        TitleStub.status = 200
        TitleStub.body = Data(#"{"customTitle":null,"herdr":"synced"}"#.utf8)
        _ = try await client().setTitle(targetId: "a/b%?#c", title: nil)
        let url = TitleStub.lastURL ?? ""
        #expect(url.hasSuffix("/v1/targets/a%2Fb%25%3F%23c/title"), "保留字符必须编码为单段：\(url)")
        #expect(!url.contains("?"), "不能产生查询串")
    }

    // 成功体必须含 customTitle 键（字符串或 null）：缺键、类型不符都是协议错误，不能当作“已清除”。
    @Test func successBodyWithoutAValidCustomTitleKeyIsADecodingError() async {
        TitleStub.status = 200
        for body in [#"{}"#, #"{"herdr":"synced"}"#, #"{"customTitle":1}"#] {
            TitleStub.body = Data(body.utf8)
            await #expect(throws: BridgeError.decoding, "\(body) 应为 decoding") { _ = try await client().setTitle(targetId: "t1", title: "x") }
        }
    }

    @Test func unknownHerdrStringPassesThroughAndMissingHerdrIsNil() async throws {
        TitleStub.status = 200
        TitleStub.body = Data(#"{"customTitle":"x","herdr":"some_future_state"}"#.utf8)
        #expect(try await client().setTitle(targetId: "t1", title: "x") == .ok(customTitle: "x", herdr: "some_future_state"))
        TitleStub.body = Data(#"{"customTitle":"x"}"#.utf8)
        #expect(try await client().setTitle(targetId: "t1", title: "x") == .ok(customTitle: "x", herdr: nil))
    }

    @Test func readOnlyIsAStatusAndCodeNotAFallback() async throws {
        TitleStub.status = 403
        TitleStub.body = Data(#"{"error":"read_only"}"#.utf8)
        let r = try await client().setTitle(targetId: "t1", title: "x")
        #expect(r == .failed(status: 403, code: "read_only"))
    }

    @Test func undecodableSuccessBodyIsADecodingError() async {
        TitleStub.status = 200
        TitleStub.body = Data("not json".utf8)
        await #expect(throws: BridgeError.decoding) { _ = try await client().setTitle(targetId: "t1", title: "x") }
    }
}
