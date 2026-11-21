import XCTest
@testable import PalmhelmKit

// 与 Bridge shared/constants 共用的 3 组已知向量：openssl 生成的 P-256 公钥 DER SubjectPublicKeyInfo → SHA-256 → base64；短指纹 = 前 40 bit 的 base32。
final class PinningTests: XCTestCase {
    private let vectors: [(der: String, sha: String, short: String)] = [
        ("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEyqPrQ7xIUWTjzzHegZk883maLrvrnU8WeL8Ooo29VjZxTD3zt2ZXaWL+PCkWeawp3QEzLahzlPZzgj8vRdUSDQ==", "1xooYVTcLNi6VufRFGzQ/1Ga74PgCkHc8gZImeKzxXw=", "24NC-QYKU"),
        ("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEbG6eyFKjAL9NtmjQ6qJuO5zs5ojYEFZPtwWUzDA9gaFJVc5y/Q2UvtCIBJdL38KAMC8w2ZLPIiubXxLQjd5nDg==", "5LDVKca9OSAgn7EoGhRo9QBVQXHN/zEUYd7DCEuyNcY=", "4SYN-KKOG"),
        ("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEGEBGo94FkYM3qBLrPLFRCUeNU+aQl+DLF385twtdC6uyO0PG/ag0++UYn4kNoC+KnZQgzGa8W2jUs7jetWqqfQ==", "/qUglG1VnNBbPw/h4Hq6AyQK1yVDmxAwpsa4YHlxidE=", "72SS-BFDN"),
    ]

    func testKnownVectors() {
        for v in vectors {
            let der = Data(base64Encoded: v.der)!
            XCTAssertEqual(der.count, 91)
            XCTAssertEqual(der.prefix(26), SPKI.p256Header, "DER SPKI 头须与固定头一致（裸公钥加头即 SPKI）")
            XCTAssertEqual(SPKI.sha256Base64(derSPKI: der), v.sha)
            XCTAssertEqual(SPKI.shortFingerprint(spkiSha256: v.sha), v.short)
            // 由裸 65 字节公钥重建 SPKI 得到同一摘要（握手路径的算法）
            XCTAssertEqual(SPKI.sha256Base64(derSPKI: SPKI.p256Header + der.suffix(65)), v.sha)
        }
    }

    func testShortFingerprintRejectsBadInput() {
        XCTAssertNil(SPKI.shortFingerprint(spkiSha256: "not base64!"))
        XCTAssertNil(SPKI.shortFingerprint(spkiSha256: Data(repeating: 1, count: 31).base64EncodedString()))
    }

    func testHttpsEndpointUsesHttpsScheme() {
        let ep = BridgeEndpoint(host: "192.168.1.9", port: 47821, transport: .https, spkiSha256: vectors[0].sha)
        XCTAssertEqual(try ep.url("/v1/health").absoluteString, "https://192.168.1.9:47821/v1/health")
        XCTAssertEqual(try BridgeEndpoint(host: "127.0.0.1").url("/v1/health").scheme, "http")
    }

    // A1-079 F1：明文只留字面回环；ts.net（含 Funnel 公网名）、Tailscale 数字地址、局域网都不算。
    func testPlaintextAllowedOnlyForLiteralLoopback() {
        XCTAssertTrue(BridgeEndpoint.allowsPlaintext(host: "127.0.0.1"))
        XCTAssertTrue(BridgeEndpoint.allowsPlaintext(host: "::1"))
        for h in ["mac.tailnet.ts.net", "ts.net", "100.100.1.2", "192.168.1.9", "localhost", "127.0.0.1.example.com"] {
            XCTAssertFalse(BridgeEndpoint.allowsPlaintext(host: h), h)
        }
    }
}
