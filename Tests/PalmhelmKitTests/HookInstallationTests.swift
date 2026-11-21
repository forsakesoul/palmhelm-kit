import Foundation
import Testing
@testable import PalmhelmKit

@Suite(.serialized) struct HookInstallationTests {
    @Test func successRequiresExplicitOk() {
        #expect(decodeHookInstallResult(status: 200, data: Data(#"{"ok":true}"#.utf8)).ok)
        for text in [#"{}"#, #"{"ok":false}"#, "<html>"] {
            #expect(decodeHookInstallResult(status: 200, data: Data(text.utf8)).error == "invalid_response")
        }
        #expect(decodeHookInstallResult(status: 409, data: Data(#"{"error":"settings_locked"}"#.utf8)).error == "settings_locked")
        #expect(decodeHookInstallResult(status: 500, data: Data(#"{"error":"/private/path"}"#.utf8)).error == "http_500")
    }
    @Test func installationIsRequiredAndFailureCopyDoesNotEchoUnknownReasons() throws {
        let value = try JSONDecoder().decode(HookInstallation.self, from: Data(#"{"installed":true,"trust":"unverifiable","lastFailure":{"reason":"launch_failed","at":1792399000000}}"#.utf8))
        #expect(value.installed)
        #expect(value.stale == nil)
        let stale = try JSONDecoder().decode(HookInstallation.self, from: Data(#"{"installed":true,"stale":true,"trust":"unverifiable"}"#.utf8))
        #expect(stale.stale == true)
        #expect(HookLaunchFailure(reason: "runtime_publish_failed", at: 1792399000000).validDate != nil)
        #expect(value.lastFailure?.validDate != nil)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HookInstallation.self, from: Data(#"{"trust":"unverifiable"}"#.utf8)) }
        #expect(HookLaunchFailure(reason: "/private/path", at: 1792399000000).validDate == nil)
        #expect(HookLaunchFailure(reason: "launch_failed", at: Int.max).validDate == nil)
    }
    @Test func fixedFailureCategoriesHaveCopyAndDates() {
        for reason in ["launch_failed", "runtime_publish_failed", "config_symlink_unsafe", "config_permissions", "config_unreadable", "update_failed"] {
            #expect(HookFailureCopy.text(for: reason) != nil)
            #expect(HookLaunchFailure(reason: reason, at: 1792399000000).validDate != nil)
        }
        #expect(HookFailureCopy.text(for: "config_symlink_unsafe") == "Claude 配置文件类型或位置不安全")
        #expect(HookFailureCopy.text(for: "config_permissions") == "Claude 配置文件的权限不安全（别人可写或不是你的文件）")
        #expect(HookFailureCopy.text(for: "config_unreadable") == "读不了 Claude 配置文件")
        #expect(HookFailureCopy.text(for: "update_failed") == "启动时自动更新失败")
        #expect(HookFailureCopy.text(for: "runtime_publish_failed") == "上次运行程序准备失败")
        #expect(HookFailureCopy.text(for: "/Users/example/secret") == nil)
        #expect(HookLaunchFailure(reason: "/Users/example/secret", at: 1792399000000).validDate == nil)
    }
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var last: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.last = request
            Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var out = Data(); var buf = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
                return out
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    @Test func realClientUsesProviderPathAndPreservesUnsupportedStatus() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        let client = BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "test", session: URLSession(configuration: cfg))
        Stub.body = Data(#"{"installed":false,"trust":"unverifiable","lastFailure":null}"#.utf8)
        Stub.status = 200
        #expect(try await client.hookInstallation(.codex).installed == false)
        #expect(Stub.last?.url?.path == "/v1/hooks/codex")
        #expect(Stub.last?.value(forHTTPHeaderField: "authorization") == "Bearer test")
        Stub.status = 404
        do { _ = try await client.hookInstallation(.claude); Issue.record("404 should throw") }
        catch BridgeError.http(let status) { #expect(status == 404) }
        Stub.status = 503
        do { _ = try await client.hookInstallation(.claude); Issue.record("503 should throw") }
        catch BridgeError.http(let status) { #expect(status == 503) }
        Stub.body = Data(#"{"error":"hook_status_unreadable","lastFailure":{"reason":"config_symlink_unsafe","at":1792399000000}}"#.utf8)
        do { _ = try await client.hookInstallation(.claude); Issue.record("unreadable should throw") }
        catch let unreadable as HookStatusUnreadable {
            #expect(unreadable.lastFailure == HookLaunchFailure(reason: "config_symlink_unsafe", at: 1792399000000))
        }
        Stub.body = Data(#"{"error":"hook_status_unreadable","lastFailure":null}"#.utf8)
        do { _ = try await client.hookInstallation(.claude); Issue.record("unreadable should throw") }
        catch let unreadable as HookStatusUnreadable { #expect(unreadable.lastFailure == nil) }
        Stub.status = 404; Stub.body = Data(#"{"error":"unsupported_runtime"}"#.utf8)
        do { _ = try await client.hookInstallation(.claude); Issue.record("404 should throw") }
        catch BridgeError.http(let status) { #expect(status == 404) }
        Stub.status = 200; Stub.body = Data(#"{"ok":true}"#.utf8)
        #expect(try await client.setHookInstallation(.claude, install: true).ok)
        #expect(Stub.last?.url?.path == "/v1/hooks/claude")
        #expect(Stub.last?.httpMethod == "POST")
        Stub.body = Data(#"{}"#.utf8)
        #expect(try await client.setHookInstallation(.codex, install: false).error == "invalid_response")
    }

    // #108：归属与配置版本。旧 Bridge 缺字段 = unreported（不是 current）；未知值 = unknown；版本只接受 64 位小写十六进制。
    @Test func ownershipDecodesAndNeverDefaultsToCurrent() throws {
        func decode(_ extra: String) throws -> HookInstallation { try JSONDecoder().decode(HookInstallation.self, from: Data(#"{"installed":true,"trust":"unverifiable"\#(extra)}"#.utf8)) }
        #expect(try decode("").ownership == .unreported)
        #expect(try decode(#","managedLocation":"none""#).ownership == .none)
        #expect(try decode(#","managedLocation":"current""#).ownership == .current)
        #expect(try decode(#","managedLocation":"other""#).ownership == .other)
        #expect(try decode(#","managedLocation":"unknown""#).ownership == .unknown)
        #expect(try decode(#","managedLocation":"brand-new""#).ownership == .unknown)
        let v = String(repeating: "a1", count: 32)
        #expect(try decode(#","managedLocation":"other","configVersion":"\#(v)""#).confirmableVersion == v)
        for bad in ["", "ABC", String(repeating: "A", count: 64), String(repeating: "a", count: 63), String(repeating: "g", count: 64), String(repeating: "a", count: 65)] {
            #expect(try decode(#","configVersion":"\#(bad)""#).confirmableVersion == nil)
        }
        #expect(try decode("").confirmableVersion == nil)
    }
    @Test func postBodyCarriesTheExpectedVersionOnlyWhenGiven() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        let client = BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "test", session: URLSession(configuration: cfg))
        Stub.status = 200; Stub.body = Data(#"{"ok":true}"#.utf8)
        _ = try await client.setHookInstallation(.claude, install: true)
        #expect(Stub.lastBody == Data(#"{"action":"install"}"#.utf8), "未传版本：请求体与此前完全一致")
        let v = String(repeating: "0f", count: 32)
        _ = try await client.setHookInstallation(.claude, install: true, expectedConfigVersion: v)
        #expect(Stub.lastBody == Data(#"{"action":"install","expectedConfigVersion":"\#(v)"}"#.utf8))
        Stub.status = 409; Stub.body = Data(#"{"error":"hook_confirmation_required"}"#.utf8)
        #expect(try await client.setHookInstallation(.claude, install: true).error == "hook_confirmation_required")
        Stub.body = Data(#"{"error":"settings_changed"}"#.utf8)
        #expect(try await client.setHookInstallation(.claude, install: true, expectedConfigVersion: v).error == "settings_changed")
    }
}
