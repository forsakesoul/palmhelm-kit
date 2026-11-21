import Foundation
import CryptoKit
import Security

/// 传输方式。启用 TLS 时（Mac 的局域网与 Tailscale 监听必须启用），所有监听地址（回环、局域网、Tailscale）均为 https：
/// 自签证书，按 SPKI 指纹固定，不校验主机名。未启用 TLS 时只有回环可用，为明文 http（iOS 只允许回环明文，见 BridgeClient.swift 的 allowsPlaintext）。
public enum Transport: String, Codable, Sendable, Equatable {
    case http, https
}

/// SPKI 指纹：证书公钥的 DER SubjectPublicKeyInfo 的 SHA-256。与 Bridge 的 local-api.json / POST /pair 响应 spkiSha256 同一口径。
public enum SPKI {
    /// P-256 未压缩公钥（X9.63，65 字节）前面固定的 SubjectPublicKeyInfo 头（26 字节）。
    public static let p256Header = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48,
        0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])

    public static func sha256Base64(derSPKI: Data) -> String {
        Data(SHA256.hash(data: derSPKI)).base64EncodedString()
    }

    /// 从 TLS 握手得到的叶证书公钥算 SPKI 摘要；非 P-256 EC 公钥返回 nil（Bridge 只签发 P-256）。
    public static func sha256Base64(leafOf trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf), let attrs = SecKeyCopyAttributes(key) as? [String: Any],
              attrs[kSecAttrKeyType as String] as? String == (kSecAttrKeyTypeECSECPrimeRandom as String),
              attrs[kSecAttrKeySizeInBits as String] as? Int == 256,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?, raw.count == 65, raw.first == 0x04
        else { return nil }
        return sha256Base64(derSPKI: p256Header + raw)
    }

    /// 人工比对用短指纹：摘要前 40 bit 的 RFC4648 base32（无填充，恰 8 字符），显示为 XXXX-XXXX。
    /// 只用于人眼对照 Mac 上 `pnpm pair` 的输出；网络校验一律用完整摘要。
    public static func shortFingerprint(spkiSha256 base64: String) -> String? {
        guard let digest = Data(base64Encoded: base64), digest.count == 32 else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let bytes = Array(digest.prefix(5))
        var bits = 0, acc = 0, out = ""
        for b in bytes {
            acc = (acc << 8) | Int(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(acc >> bits) & 31]) }
        }
        return String(out.prefix(4)) + "-" + String(out.suffix(4))
    }
}

/// 固定 SPKI 的会话代理。pin：只接受完整摘要相等的证书；observe：接受任意证书但记录看到的摘要（只用于配对前的健康探测，不带任何秘密）。
/// 不跟随任何重定向（配对码与 Bearer 不得被转发到别处）。
public final class PinnedSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    public enum Mode: Sendable { case pin(String), observe }
    private let mode: Mode
    private let lock = NSLock()
    private var seen: String?

    public init(mode: Mode) { self.mode = mode }

    /// observe 模式下最近一次握手看到的 SPKI 摘要。
    public var observed: String? { lock.withLock { seen } }

    // 用带 completionHandler 的 Objective-C 形式实现：URLSession 按选择器匹配代理方法，async 变体在 iOS 模拟器上未被调用（握手被默认处理后直接断开）。
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let got = SPKI.sha256Base64(leafOf: trust)
        else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        switch mode {
        case .pin(let want):
            completionHandler(got == want ? .useCredential : .cancelAuthenticationChallenge, got == want ? URLCredential(trust: trust) : nil)
        case .observe:
            lock.withLock { seen = got }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    // 任务级挑战：`bytes(for:delegate:)` 这类按任务指定代理的 API 只走这个入口，不走会话级入口（SSE 长连接在 TLS 下曾因此按默认信任评估被拒，-1202）。
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
