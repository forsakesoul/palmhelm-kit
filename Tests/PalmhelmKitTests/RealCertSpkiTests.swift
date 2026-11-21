import XCTest
import Security
@testable import PalmhelmKit

// 真实证书核对（可选）：REINS_DIAG_CERT=<cert.pem> 时，从 SecTrust 叶证书算出的 SPKI 摘要须等于 openssl 口径（Bridge local-api.json 的 spkiSha256）。
final class RealCertSpkiTests: XCTestCase {
    func testLeafSpkiFromRealCert() throws {
        guard let path = ProcessInfo.processInfo.environment["REINS_DIAG_CERT"] else { throw XCTSkip("no cert") }
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = Data(base64Encoded: b64)!
        let cert = SecCertificateCreateWithData(nil, der as CFData)!
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let key = SecCertificateCopyKey(cert)
        let attrs = key.flatMap { SecKeyCopyAttributes($0) as? [String: Any] }
        XCTAssertEqual(attrs?[kSecAttrKeySizeInBits as String] as? Int, 256)
        let viaTrust = SPKI.sha256Base64(leafOf: trust!)
        let viaDer = SPKI.sha256Base64(derSPKI: SPKI.p256Header + (SecKeyCopyExternalRepresentation(key!, nil)! as Data))
        XCTAssertEqual(viaTrust, viaDer)
        if let want = ProcessInfo.processInfo.environment["REINS_DIAG_SPKI"] { XCTAssertEqual(viaTrust, want) }
    }
}
