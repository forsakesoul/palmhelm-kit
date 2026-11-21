import Foundation
import Testing
@testable import PalmhelmKit

// #88 S2：BridgeClient 的条件读取与按条续读（真实 BridgeClient + URLProtocol 桩，只看请求形状与应答解析）。

@Suite(.serialized) struct TranscriptSyncClientTests {
    final class SyncStub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var headers: [String: String] = [:]
        nonisolated(unsafe) static var lastPath: String?
        nonisolated(unsafe) static var lastQuery: String?
        nonisolated(unsafe) static var lastIfNoneMatch: String?
        nonisolated(unsafe) static var lastAuthorization: String?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            SyncStub.lastPath = request.url?.path
            SyncStub.lastQuery = request.url?.query
            SyncStub.lastIfNoneMatch = request.value(forHTTPHeaderField: "If-None-Match")
            SyncStub.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            let response = HTTPURLResponse(url: request.url!, statusCode: SyncStub.status, httpVersion: nil, headerFields: SyncStub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if SyncStub.status != 304 { client?.urlProtocol(self, didLoad: SyncStub.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client() -> BridgeClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SyncStub.self]
        return BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "tok", session: URLSession(configuration: cfg))
    }

    private func reset(status: Int, body: String = "", headers: [String: String] = [:]) {
        SyncStub.status = status
        SyncStub.body = Data(body.utf8)
        SyncStub.headers = headers
        SyncStub.lastIfNoneMatch = nil
    }

    private static let pageJSON = #"{"status":"ok","sessionEpoch":"e1","revision":"r1","items":[{"id":"i1","role":"assistant","text":"截断…","truncated":true,"continuation":"tok.part"}],"hasMore":false,"partial":false}"#

    @Test func conditionalFetchSendsNoValidatorWithoutACachedPage() async throws {
        reset(status: 200, body: Self.pageJSON, headers: ["ETag": "\"v1\""])
        let fetched = try await client().transcriptConditional(targetId: "t1", ifNoneMatch: nil)
        #expect(SyncStub.lastIfNoneMatch == nil)
        guard case let .page(page, etag) = fetched else { Issue.record("expected a page"); return }
        #expect(etag == "\"v1\"" && page.items.first?.continuation == "tok.part")
    }

    // 回执后补声明：只附首页读取，参数规范化（epoch 一个、key 去重排序）；翻旧页（before）不带
    @Test func latestReadCarriesTheReceiptDeclarationButOlderPagesDoNot() async throws {
        reset(status: 200, body: Self.pageJSON, headers: ["ETag": "\"v1\""])
        let r = TranscriptReceiptRequest(sessionEpoch: "e1", eventKeys: ["kb", "ka", "kb"])!
        _ = try await client().transcriptConditional(targetId: "t1", before: nil, limit: 20, ifNoneMatch: nil, receipt: r)
        let q = SyncStub.lastQuery ?? ""
        #expect(q.contains("receiptEpoch=e1") && q.contains("receiptEventKey=ka&receiptEventKey=kb"))
        _ = try await client().transcriptConditional(targetId: "t1", before: "cur", limit: 20, ifNoneMatch: nil, receipt: r)
        #expect(!(SyncStub.lastQuery ?? "").contains("receipt"))
        _ = try await client().transcriptConditional(targetId: "t1", ifNoneMatch: nil)
        #expect(!(SyncStub.lastQuery ?? "").contains("receipt"), "the old signature sends no declaration")
    }

    @Test func receiptUpdatesDecodeFromAConditionalResponse() async throws {
        let body = #"{"status":"ok","sessionEpoch":"e1","revision":"r1","items":[],"hasMore":false,"partial":false,"receiptUpdates":[{"itemId":"A","receipt":{"commandKey":"ck","origin":"api","receiptState":"sent","eventKey":"K"}}]}"#
        reset(status: 200, body: body, headers: ["ETag": "\"v2\""])
        let fetched = try await client().transcriptConditional(targetId: "t1", before: nil, limit: 20, ifNoneMatch: nil, receipt: TranscriptReceiptRequest(sessionEpoch: "e1", eventKeys: ["K"]))
        guard case let .page(page, _) = fetched else { Issue.record("expected a page"); return }
        #expect(page.receiptUpdates?.first?.itemId == "A" && page.receiptUpdates?.first?.receipt.eventKey == "K")
    }

    @Test func conditionalFetchSendsTheValidatorAndAcceptsNotModified() async throws {
        reset(status: 304, headers: ["ETag": "\"v1\""])
        let fetched = try await client().transcriptConditional(targetId: "t1", ifNoneMatch: "\"v1\"")
        #expect(SyncStub.lastIfNoneMatch == "\"v1\"")
        #expect(fetched == .notModified)
    }

    // 续读：路径带条目 ID、令牌放在 cont 参数里原样传回；返回一段正文。
    @Test func itemContinuationUsesTheItemPathAndTokenAndReturnsASegment() async throws {
        reset(status: 200, body: #"{"status":"ok","sessionEpoch":"e1","itemId":"i1","text":"后段","hasMore":false}"#)
        let segment = try await client().transcriptItem(targetId: "t1", itemId: "i1", continuation: "tok.part")
        #expect(SyncStub.lastPath == "/v1/targets/t1/transcript/items/i1")
        #expect(SyncStub.lastQuery == "cont=tok.part")
        #expect(SyncStub.lastAuthorization == "Bearer tok")
        #expect(segment.isAvailable && segment.text == "后段" && segment.hasMore == false)
    }

    // 令牌被拒绝（410 reset）按 HTTP 错误抛出，调用方据此标记需要重新读取。
    @Test func itemContinuationResetIsAnHTTPError() async {
        reset(status: 410, body: #"{"error":"reset"}"#)
        await #expect(throws: BridgeError.self) {
            _ = try await client().transcriptItem(targetId: "t1", itemId: "i1", continuation: "tok.part")
        }
    }
}
