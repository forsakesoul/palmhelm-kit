import Foundation

/// 一台 Mac 的账号（多台 Mac C1/C2）：同一台 Mac 的多个地址共用同一个证书 pin 与令牌；令牌存钥匙串（按 `id`），其余存本机。
public struct BridgeAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// `state.bridge.id`，首次连上才知道；用于已读/视角等按机器存的键。
    public var bridgeId: String?
    public var name: String
    public var endpoints: [BridgeEndpoint]
    public var deviceName: String
    /// 上次成功的地址下标；连接选择器从它开始。
    public var preferred: Int
    /// 用户是否手动改过账户名：改过则不再被 Bridge 自报的电脑名覆盖（O1-364 ③）；nil / false = 自动跟随。
    public var nameEdited: Bool?
    public init(id: String = UUID().uuidString.lowercased(), bridgeId: String? = nil, name: String, endpoints: [BridgeEndpoint], deviceName: String, preferred: Int = 0) {
        self.id = id; self.bridgeId = bridgeId; self.name = name; self.endpoints = endpoints; self.deviceName = deviceName; self.preferred = preferred
    }
    public var current: BridgeEndpoint? { endpoints.indices.contains(preferred) ? endpoints[preferred] : endpoints.first }
    public var spkiSha256: String? { endpoints.compactMap(\.spkiSha256).first }
}

/// 连接选择：候选按「上次成功 › 局域网字面量 › 主机名（Tailscale）› 回环」排序；只有网络层失败才换下一个，HTTP 状态码不换。
public enum EndpointRotation {
    /// 尝试顺序（下标）。`cellularOnly` 为真（只走蜂窝）时局域网字面量候选后置到域名之后；preferred 若是局域网地址同样不提前（#85）。
    public static func order(_ eps: [BridgeEndpoint], preferred: Int, cellularOnly: Bool = false) -> [Int] {
        let rank: (BridgeEndpoint) -> Int = { e in
            if BridgeEndpoint.allowsPlaintext(host: e.host) { return 3 }
            return e.host.contains(".") && Int(e.host.replacingOccurrences(of: ".", with: "")) == nil ? 2 : 1
        }
        // 局域网字面量在蜂窝下排到域名（2）之后，即 2.5
        let key: (Int) -> Double = { i in cellularOnly && rank(eps[i]) == 1 ? 2.5 : Double(rank(eps[i])) }
        var idx = Array(eps.indices).sorted { a, b in
            let ka = key(a), kb = key(b)
            return ka != kb ? ka < kb : a < b
        }
        let preferredIsLan = cellularOnly && eps.indices.contains(preferred) && rank(eps[preferred]) == 1
        if eps.indices.contains(preferred), !preferredIsLan, let i = idx.firstIndex(of: preferred) { idx.remove(at: i); idx.insert(preferred, at: 0) }
        return idx
    }

    /// 网络层失败（连不上 / 超时 / TLS 握手失败 / DNS）才换地址；`BridgeError.http` 等业务错误不换。
    public static func isNetworkFailure(_ error: Error) -> Bool {
        if error is BridgeError { return false }
        if let u = error as? URLError {
            switch u.code {
            case .cannotConnectToHost, .timedOut, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
                 .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .resourceUnavailable:
                return true
            default: return false
            }
        }
        return (error as NSError).domain == NSPOSIXErrorDomain
    }

    /// 把 Bridge 自报的地址表并入账号：lan 字面量与 tailscale 主机名各保留，回环只在当前已是回环时保留（联调）；沿用同一个 pin。
    public static func merge(_ account: BridgeAccount, with api: [ApiEndpoint]) -> BridgeAccount {
        var a = account
        let pin = a.spkiSha256
        let keepLoopback = a.endpoints.contains { BridgeEndpoint.allowsPlaintext(host: $0.host) }
        var out: [BridgeEndpoint] = []
        for e in api {
            if e.kind == "loopback", !keepLoopback { continue }
            let ep = BridgeEndpoint(host: e.host, port: e.port, transport: e.transport, spkiSha256: e.transport == .https ? pin : nil)
            if !out.contains(where: { $0.host == ep.host && $0.port == ep.port }) { out.append(ep) }
        }
        // 当前在用的地址即使不在自报表里也保留（例如手填的主机名）；但 Bridge 自报了 MagicDNS 名时，旧的 .ts.net 名视为过期丢弃（填错/改名后不再反复试）
        let isTs: (String) -> Bool = { $0.hasSuffix(".ts.net") }
        if let cur = a.current, !out.contains(where: { $0.host == cur.host && $0.port == cur.port }),
           !(isTs(cur.host) && out.contains { isTs($0.host) }) { out.insert(cur, at: 0) }
        guard !out.isEmpty else { return a }
        let curHost = a.current?.host
        a.endpoints = out
        a.preferred = out.firstIndex { $0.host == curHost } ?? 0
        return a
    }
}

/// 配对深链 `palmhelm://pair?host=&port=&code=&tls=&fp=&ep=lan:ip:port,ts:host:port`（Mac 配对窗口二维码）。
public struct PairLink: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var code: String
    public var tls: Bool
    public var fp: String?
    /// 附加地址（不含 host 本身），按 ep 顺序。
    public var extra: [BridgeEndpoint]

    public static func parse(_ url: URL) -> PairLink? {
        guard url.scheme == "palmhelm", url.host == "pair", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func q(_ k: String) -> String? { items.first { $0.name == k }?.value }
        // 统一在这里校验：扫码、深链、Bonjour 之外的所有配对入口都只接受形态合法的链接，非法一律拒绝而不是回落默认值
        guard let host = q("host"), validHost(host), let code = q("code"), code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let port: Int
        if let raw = q("port") { guard let p = validPort(raw) else { return nil }; port = p } else { port = BridgeAPI.defaultPort }
        let tls = q("tls") == "1"
        var fp: String?
        if let raw = q("fp"), !raw.isEmpty {
            guard let d = Data(base64Encoded: raw), d.count == 32 else { return nil } // 必须是完整的 SPKI SHA-256
            fp = raw
        }
        var extra: [BridgeEndpoint] = []
        for part in (q("ep") ?? "").split(separator: ",") {
            let f = part.split(separator: ":").map(String.init)
            guard f.count == 3, let p = validPort(f[2]), f[0] == "lan" || f[0] == "ts", validHost(f[1]) else { continue }
            if f[1] == host, p == port { continue }
            // 去重（同一地址只试一次）并限制候选数：主地址 + 附带地址不超过 PairRoute.maxCandidates（O1-347 S1）
            if extra.contains(where: { $0.host == f[1] && $0.port == p }) { continue }
            if extra.count + 1 >= PairRoute.maxCandidates { break }
            extra.append(BridgeEndpoint(host: f[1], port: p, transport: tls ? .https : .http, spkiSha256: nil))
        }
        return PairLink(host: host, port: port, code: code, tls: tls, fp: fp, extra: extra)
    }

    static func validPort(_ s: String) -> Int? {
        guard !s.isEmpty, s.count <= 5, s.allSatisfy({ $0.isASCII && $0.isNumber }), let p = Int(s), (1...65535).contains(p) else { return nil }
        return p
    }
    /// 主机名或 IP：ASCII、无空白与 URL 结构字符、长度有限。
    static func validHost(_ h: String) -> Bool {
        !h.isEmpty && h.count <= 253 && h.allSatisfy { $0.isASCII && !$0.isWhitespace && !"/?#@[]\\%".contains($0) }
    }
}

/// 设备名规则（O1-364 ④，与 Bridge 的 renameSelf 投影一致）：控制字符与多余空白压成单行，去首尾空白，非空，至多 32 个 Unicode 标量。
public enum DeviceNameRules {
    public static let maxScalars = 32
    /// 合法则返回规范化后的名字，否则 nil（调用方给出明确提示，不发送）。
    public static func clean(_ raw: String) -> String? {
        let flat = raw.unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.isWhitespace ? " " : String($0) }.joined()
        let collapsed = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.unicodeScalars.count <= maxScalars else { return nil }
        return collapsed
    }
}
