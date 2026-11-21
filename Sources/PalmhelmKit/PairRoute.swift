import Foundation

/// 配对时依次尝试账号的地址（O1-346）：先试二维码的主地址，再试附带的其他地址（ep 顺序，最多 maxCandidates 个）。
/// 只有「未连上」才换下一个地址：探测（probe）失败、或配对请求在发出前就连不上。
/// 配对请求已发出但结果不确定（超时 / 连接中断）时不换地址、不重发同一码（服务端可能已消费）：返回 resultUnknown。
/// 指纹不符、用户未确认指纹、Bridge 回报的指纹缺失或不一致、配对码错误等一律立即停止。
/// 同一台 Mac 的所有地址共用第一次确认的证书指纹：后续地址握手到的指纹必须相同。
public enum PairRoute {
    public static let maxCandidates = 4

    public struct Success<R> {
        /// 成功的地址；https 时已带上确认的 SPKI 摘要。
        public let endpoint: BridgeEndpoint
        public let response: R
        public let spkiSha256: String?
    }

    public enum Failure: Error {
        /// 所有地址都没连上；tried 列出试过的地址类型（局域网 / Tailscale）。
        case unreachable(tried: [String])
        /// 配对请求已发出，但没有收到结果（超时 / 连接中断）：可能已配对，不换地址、不重发同一码。
        case resultUnknown(endpoint: BridgeEndpoint)
        /// 立即停止：指纹相关错误见 PairRouteError，其余是 Bridge / 配对码 / 其他错误原样带出。
        case stopped(Error)
    }

    public enum PairRouteError: Error, Equatable {
        /// 广播的指纹、或先前确认的指纹与实际握手不一致。
        case fingerprintMismatch
        /// 用户没有确认证书指纹：不发配对码。
        case notConfirmed
        /// Bridge 回报的指纹与握手证书不一致。
        case reportedFingerprintMismatch
        /// https 下 Bridge 没有回报证书指纹：无法交叉校验，拒绝保存令牌。
        case reportedFingerprintMissing
    }

    /// 地址类型的展示名：Tailscale 主机名或 100.64/10 为 Tailscale，其余为局域网。
    public static func kindLabel(_ host: String) -> String {
        if host.hasSuffix(".ts.net") { return "Tailscale" }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return "Tailscale" }
        return KitL10n.string("局域网")
    }

    /// 配对请求的结果不确定：超时、连接中途断开（请求可能已到达并被处理）。
    static func isOutcomeUnknown(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        return u.code == .timedOut || u.code == .networkConnectionLost
    }

    /// probe：https 时取实际握手证书的 SPKI；confirm：用户确认（参数为完整 SPKI）；send：带上 pin 发送配对码。
    /// probeDeadline / sendDeadline 是绝对期限（秒），超过即按超时处理，不靠空闲超时。
    @MainActor
    public static func pair<R: Sendable>(
        candidates: [BridgeEndpoint],
        expectedSpki: String?,
        probeDeadline: Double = BridgeAPI.Deadline.pairProbe,
        sendDeadline: Double = BridgeAPI.Deadline.pairSend,
        probe: @escaping (BridgeEndpoint) async throws -> String,
        confirm: (String) async -> Bool,
        send: @escaping (BridgeEndpoint) async throws -> R,
        reportedSpki: (R) -> String?
    ) async -> Result<Success<R>, Failure> {
        var tried: [String] = []
        var confirmed: String?
        for ep in candidates.prefix(maxCandidates) {
            // 明文只留回环：非回环的 http 地址不尝试（与主地址的检查一致）
            if ep.transport == .http, !BridgeEndpoint.allowsPlaintext(host: ep.host) { continue }
            var endpoint = ep
            if ep.transport == .https {
                let spki: String
                do {
                    spki = try await withDeadline(probeDeadline) { try await probe(ep) }
                } catch {
                    // 探测阶段的任何网络失败都只说明这个地址没连上：换下一个
                    guard EndpointRotation.isNetworkFailure(error) else { return .failure(.stopped(error)) }
                    tried.append(kindLabel(ep.host))
                    continue
                }
                if let expectedSpki, expectedSpki != spki { return .failure(.stopped(PairRouteError.fingerprintMismatch)) }
                if let confirmed {
                    guard confirmed == spki else { return .failure(.stopped(PairRouteError.fingerprintMismatch)) }
                } else {
                    guard await confirm(spki) else { return .failure(.stopped(PairRouteError.notConfirmed)) }
                    confirmed = spki
                }
                endpoint.spkiSha256 = spki
            }
            do {
                let response = try await withDeadline(sendDeadline) { try await send(endpoint) }
                if ep.transport == .https {
                    // 严格相等：https 下 Bridge 必须回报与握手一致的指纹；缺失也拒绝（O1-347 R1）
                    guard let reported = reportedSpki(response) else { return .failure(.stopped(PairRouteError.reportedFingerprintMissing)) }
                    guard reported == endpoint.spkiSha256 else { return .failure(.stopped(PairRouteError.reportedFingerprintMismatch)) }
                }
                return .success(Success(endpoint: endpoint, response: response, spkiSha256: endpoint.spkiSha256))
            } catch {
                // 配对请求的结果不确定：不换地址、不重发同一码（O1-347 R2）
                if isOutcomeUnknown(error) { return .failure(.resultUnknown(endpoint: endpoint)) }
                guard EndpointRotation.isNetworkFailure(error) else { return .failure(.stopped(error)) }
                tried.append(kindLabel(ep.host)) // 请求在发出前就连不上：这个地址没连上，换下一个
            }
        }
        return .failure(.unreachable(tried: tried))
    }

    /// 绝对期限：超过 seconds 即抛出 URLError(.timedOut)，并取消未完成的操作（不依赖空闲超时）。
    @MainActor
    static func withDeadline<T: Sendable>(_ seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T {
        let work = Task { try await operation() }
        let clock = DeadlineClock()
        let timer = Task {
            try await Task.sleep(for: .seconds(seconds))
            clock.fired = true
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await work.value
        } catch {
            if clock.fired { throw URLError(.timedOut) }
            throw error
        }
    }
}

@MainActor
private final class DeadlineClock {
    var fired = false
}
