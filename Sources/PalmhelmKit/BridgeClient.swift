import Foundation
import Network // URLSessionConfiguration.proxyConfigurations 的 ProxyConfiguration 类型

// Bridge 本机 API 的客户端：配对、健康、状态、发消息、审批、设备暂停，外加 SSE 事件流。
// 令牌由调用方注入（存 Keychain）；本类型不持久化任何东西。
public struct BridgeEndpoint: Sendable, Equatable, Codable, Hashable {
    public var host: String
    public var port: Int
    public var transport: Transport
    /// https 时固定的证书 SPKI 摘要（配对时人工核对后写入）；http 为 nil。
    public var spkiSha256: String?

    public init(host: String, port: Int = BridgeAPI.defaultPort, transport: Transport = .http, spkiSha256: String? = nil) {
        self.host = host
        self.port = port
        self.transport = transport
        self.spkiSha256 = spkiSha256
    }

    /// 明文 http 只允许发往字面回环。iOS 为 *.ts.net 放开了 ATS（含明文），不能靠 ATS 的地址分类兜底。
    public static func allowsPlaintext(host: String) -> Bool { host == "127.0.0.1" || host == "::1" }

    /// 所有 API 与 SSE 请求都经这里构造 URL：iOS 上非回环明文在发出配对码或 Bearer 之前即被拒绝。
    /// macOS 不拦：Mac App 按自己的监听配置连内置 Bridge（Tailscale 明文是 Bridge 支持的模式）。
    /// percentEncoded：path 里已有调用方编码好的路径段（如 reveal 的目标 id），原样使用，避免百分号被二次编码。
    func url(_ path: String, query: [URLQueryItem] = [], percentEncoded: Bool = false) throws -> URL {
        #if os(iOS)
        if transport == .http, !Self.allowsPlaintext(host: host) { throw BridgeError.plaintextRefused }
        #endif
        var c = URLComponents()
        c.scheme = transport.rawValue
        c.host = host
        c.port = port
        if percentEncoded { c.percentEncodedPath = path } else { c.path = path }
        if !query.isEmpty { c.queryItems = query }
        guard let u = c.url else { throw BridgeError.badURL }
        return u
    }
}

public enum RevealResult: Sendable, Equatable {
    case ok
    case failed(status: Int, code: String?)
}

public enum BridgeError: Error, Sendable, Equatable {
    case badURL
    /// 非回环地址用了明文 http（iOS）：请求未构造、未发送。
    case plaintextRefused
    case http(status: Int)
    case decoding
    /// 拒绝原因超过 Bridge 入口上限（500 UTF-16 单位）：本地拦下，不截断、不发送。
    case messageTooLong
}

public enum ApprovalMessage {
    public static let maxUTF16 = 500
    public static func isTooLong(_ s: String) -> Bool { s.utf16.count > maxUTF16 }
}

public actor BridgeClient {
    public let endpoint: BridgeEndpoint
    private let token: String?
    private let session: URLSession

    /// https 端点自动使用固定 SPKI 的会话；没有指纹的 https 端点一律拒绝（不接受任何证书）。
    /// 单次请求期限（秒）：连接选择器用 4 秒；长连接事件流不设。
    private let timeout: TimeInterval?
    public init(endpoint: BridgeEndpoint, token: String?, session: URLSession? = nil, timeout: TimeInterval? = nil) {
        self.endpoint = endpoint
        self.token = token
        self.session = session ?? Self.makeSession(for: endpoint)
        self.timeout = timeout
    }

    /// 直连会话：不经系统代理（局域网/Tailscale 直连，代理会把 10.x 地址转发出去并返回 502），不缓存。
    static func directConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        // 直连：显式清空代理。iOS 17 起 URLSession 以 proxyConfigurations 为准，旧的 connectionProxyDictionary 不能可靠关闭系统代理；
        // 若仍走系统代理（如 Mac 上的本机代理），局域网 TLS 流量会被代理按其规则改写或拒绝（实测出现明文转发与 502）。
        c.proxyConfigurations = []
        c.connectionProxyDictionary = [:]
        c.urlCache = nil
        return c
    }

    static func makeSession(for endpoint: BridgeEndpoint) -> URLSession {
        // http 也挂同一代理，只为不跟随重定向：回环明文被 307 到别处时，配对码与 Bearer 不得随之转发（A1-080 F1-R）。
        // http 没有证书挑战，空 pin 不影响直连；http→https 的跳转同样由重定向回调拒绝。
        let delegate = PinnedSessionDelegate(mode: .pin(endpoint.spkiSha256 ?? ""))
        return URLSession(configuration: directConfiguration(), delegate: delegate, delegateQueue: nil)
    }

    /// 配对前探测：对 https 端点发一次不带任何秘密的 GET /v1/health（未认证会得到 401，这里只关心 TLS 握手），
    /// 返回实际握手证书的 SPKI 摘要（供人工核对后固定）。握手失败或没有证书信息则抛错。
    public static func probe(host: String, port: Int) async throws -> String {
        let delegate = PinnedSessionDelegate(mode: .observe)
        let session = URLSession(configuration: directConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let url = try BridgeEndpoint(host: host, port: port, transport: .https).url(BridgeAPI.Path.health)
        let request = URLRequest(url: url)
        _ = try await withAbsoluteDeadline(BridgeAPI.Deadline.request) { try await session.data(for: request) } // 状态码不重要：任何 HTTP 响应都意味着握手已完成
        guard let spki = delegate.observed else { throw BridgeError.decoding }
        return spki
    }

    /// 配对 POST 用配对的期限（pairSend），不用常规的 request 期限：与 PairRoute 的外层期限一致，内层不抢先（O1-349 R1）。
    public func pair(code: String, deviceName: String) async throws -> PairResponse {
        try await post(BridgeAPI.Path.pair, body: ["code": code, "deviceName": deviceName], authorized: false, deadline: BridgeAPI.Deadline.pairSend)
    }

    /// localizationVersion：声明本 App 的 APNs 文案能力（1 = 提醒用 loc-key，由 App 的主 bundle 本地化）；nil 不发送，Bridge 沿用旧中文 body。
    public func registerPush(token: String, environment: String, localizationVersion: Int? = nil) async throws {
        guard token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              ["development", "production"].contains(environment) else { throw BridgeError.decoding }
        struct Result: Decodable { var registered: Bool }
        struct Body: Encodable { var token: String; var environment: String; var localizationVersion: Int? }
        let r: Result = try await request("PUT", BridgeAPI.Path.devicesSelf + "/push", body: Body(token: token, environment: environment, localizationVersion: localizationVersion), authorized: true)
        guard r.registered else { throw BridgeError.decoding }
    }

    public func unregisterPush() async throws {
        // DELETE is idempotent; the body contains no registration credentials.
        let (status, _) = try await messageRequest("DELETE", BridgeAPI.Path.devicesSelf + "/push", body: nil)
        guard (200..<300).contains(status) else { throw BridgeError.http(status: status) }
    }

    public func health() async throws -> BridgeHealth { try await get(BridgeAPI.Path.health) }

    public func state() async throws -> BridgeState { try await get(BridgeAPI.Path.state) }

    public func send(text: String, clientMsgId: UUID = UUID()) async throws -> MessageReceipt {
        try await post(BridgeAPI.Path.messages, body: ["clientMsgId": clientMsgId.uuidString.lowercased(), "text": text], authorized: true)
    }

    /// #23：带可选 mode（queue / steer）的发送；缺省时请求体与 `send` 相同。署名已取消（O1-364），不再上送 attribution。
    /// 失败只回固定错误码（`MessageActionError`），不回显正文或路径。
    public func sendMessage(text: String, clientMsgId: UUID = UUID(), mode: SendMode? = nil, queueTTLSeconds: Int? = nil, responseLanguage: MessageResponseLanguage? = nil) async throws -> MessageReceipt {
        let body = SendMessageBody(clientMsgId: clientMsgId.uuidString.lowercased(), text: text, mode: mode?.rawValue, queueTTLSeconds: queueTTLSeconds, responseLanguage: responseLanguage?.rawValue)
        let (status, data) = try await messageRequest("POST", BridgeAPI.Path.messages, body: try JSONEncoder().encode(body))
        return try MessageActions.decodeSend(status: status, data: data)
    }

    /// 排队改为立即插入（steer）或立即发送（send_now）：对同一条消息做条件转换（不先删再发）。
    public func promote(eventKey: String, mode: SendMode = .steer) async throws -> PromoteResult {
        let path = try messagePath(eventKey) + "/promote"
        let (status, data) = try await messageRequest("POST", path, body: try JSONEncoder().encode(["mode": mode.rawValue]))
        return try MessageActions.decodePromote(eventKey: eventKey, mode: mode, status: status, data: data)
    }

    /// 撤回排队中的消息（只停止将来的派发；已开始处理则返回 `notWithdrawable`）。
    public func withdraw(eventKey: String) async throws -> WithdrawResult {
        let (status, data) = try await messageRequest("DELETE", try messagePath(eventKey), body: nil)
        return try MessageActions.decodeWithdraw(eventKey: eventKey, status: status, data: data)
    }

    private func messagePath(_ eventKey: String) throws -> String {
        var segment = CharacterSet.urlPathAllowed; segment.remove(charactersIn: "/")
        guard let encoded = eventKey.addingPercentEncoding(withAllowedCharacters: segment) else { throw MessageActionError.notFound }
        return BridgeAPI.Path.messages + "/" + encoded
    }

    /// 原始请求：返回状态码与正文，由 `MessageActions` 统一判定（非 2xx 也要读正文里的固定码）。
    private func messageRequest(_ method: String, _ path: String, body: Data?) async throws -> (Int, Data) {
        var request = URLRequest(url: try endpoint.url(path, percentEncoded: true))
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = method
        request.setValue(BridgeAPI.Header.json, forHTTPHeaderField: BridgeAPI.Header.contentType)
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        request.httpBody = body
        let (data, response) = try await dataWithDeadline(request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.decoding }
        return (http.statusCode, data)
    }

    /// 待批准的审批（重连后以此为准）。
    public func approvals() async throws -> [ApprovalView] {
        let r: ApprovalsResponse = try await get(BridgeAPI.Path.approvals + "?status=" + ApprovalStatus.pending.rawValue)
        return r.approvals
    }

    /// 审批决定；409 表示已被别处决定/过期/撤回（调用方重拉）。
    public func decide(approvalId: String, decision: ApprovalDecision) async throws -> String {
        try await decide(approvalId: approvalId, decision: decision, message: nil).status
    }

    /// 带可选拒绝原因（仅 deny；≤500 UTF-16 单位，Bridge 会做安全投影并在响应里回最终文本）。
    public func decide(approvalId: String, decision: ApprovalDecision, message: String?) async throws -> DecisionResponse {
        var body: [String: String] = ["decision": decision.rawValue]
        if decision == .deny, let m = message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            guard !ApprovalMessage.isTooLong(m) else { throw BridgeError.messageTooLong }
            body["message"] = m
        }
        return try await request("POST", BridgeAPI.Path.approvals + "/" + approvalId, body: body, authorized: true)
    }

    /// 提问 / 计划的投影正文（只读设备也可读）。
    public func approvalDetail(id: String) async throws -> ApprovalDetail {
        let r: ApprovalDetailResponse = try await get(BridgeAPI.Path.approvals + "/" + id)
        return r.approval
    }

    private struct AnswerBody: Encodable { let decision = "answer"; let answers: [QuestionAnswer] }
    private struct MessageBody: Encodable { let decision: String; let message: String? }

    /// 回答提问：逐题一条（漏答、越界、重复、不可选 → 400 answer_invalid；只读 403；已决定 409）。
    public func answer(approvalId: String, answers: [QuestionAnswer]) async throws -> DecisionResponse {
        try await request("POST", BridgeAPI.Path.approvals + "/" + approvalId, body: AnswerBody(answers: answers), authorized: true)
    }

    /// 打回计划继续规划（理由可空，≤500 单位，Bridge 投影）；计划不能经此批准。
    public func revise(approvalId: String, message: String?) async throws -> DecisionResponse {
        let m = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m, ApprovalMessage.isTooLong(m) { throw BridgeError.messageTooLong }
        return try await request("POST", BridgeAPI.Path.approvals + "/" + approvalId, body: MessageBody(decision: "revise", message: (m?.isEmpty ?? true) ? nil : m), authorized: true)
    }

    /// 交回终端：卡片撤下，终端照常询问。
    public func release(approvalId: String) async throws -> DecisionResponse {
        try await request("POST", BridgeAPI.Path.approvals + "/" + approvalId, body: MessageBody(decision: "release", message: nil), authorized: true)
    }

    /// 账户额度（只读；暂停的设备也可读）。refresh：手动刷新（服务端 60 秒节流，超频给缓存并标 throttled）。
    public func accounts(refresh: Bool = false) async throws -> AccountsResponse {
        try await get(BridgeAPI.Path.accounts + (refresh ? "?refresh=1" : ""))
    }

    /// 用量聚合（只读；暂停的设备也可读）。
    public func usage(window: UsageWindow) async throws -> UsageResponse {
        try await get(BridgeAPI.Path.usage + "?window=" + window.rawValue)
    }

    /// 503 且体为固定的 hook_status_unreadable 时抛 HookStatusUnreadable（带故障）；其他非 2xx 仍是 http(status)。
    public func hookInstallation(_ provider: HookProvider) async throws -> HookInstallation {
        var request = URLRequest(url: try endpoint.url("/v1/hooks/" + provider.rawValue))
        if let timeout { request.timeoutInterval = timeout }
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        let (data, response) = try await dataWithDeadline(request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.decoding }
        if http.statusCode == 503, let body = try? JSONDecoder().decode(HookUnreadableBody.self, from: data),
           body.error == "hook_status_unreadable" {
            throw HookStatusUnreadable(lastFailure: body.lastFailure)
        }
        guard (200..<300).contains(http.statusCode) else { throw BridgeError.http(status: http.statusCode) }
        do { return try JSONDecoder().decode(HookInstallation.self, from: data) } catch { throw BridgeError.decoding }
    }
    private struct HookUnreadableBody: Decodable { let error: String; let lastFailure: HookLaunchFailure? }

    /// `expectedConfigVersion` 只在 Claude 钩子指向别处 / 无法确认归属时的带版本确认修复里传；nil 时请求体字节与此前完全相同。
    public func setHookInstallation(_ provider: HookProvider, install: Bool, expectedConfigVersion: String? = nil) async throws -> HookInstallResult {
        var request = URLRequest(url: try endpoint.url("/v1/hooks/" + provider.rawValue))
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = "POST"
        request.setValue(BridgeAPI.Header.json, forHTTPHeaderField: BridgeAPI.Header.contentType)
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        var body = ["action": install ? "install" : "uninstall"]
        if let expectedConfigVersion { body["expectedConfigVersion"] = expectedConfigVersion }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await dataWithDeadline(request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.decoding }
        return decodeHookInstallResult(status: http.statusCode, data: data)
    }

    /// Claude 额度的状态行安装 / 卸载（需可控设备）：只回固定原因码，不回显路径或原文。
    public func setClaudeStatusline(install: Bool) async throws -> ClaudeStatuslineResult {
        var request = URLRequest(url: try endpoint.url(BridgeAPI.Path.accounts + "/claude/statusline"))
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = "POST"
        request.setValue(BridgeAPI.Header.json, forHTTPHeaderField: BridgeAPI.Header.contentType)
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        request.httpBody = try JSONEncoder().encode(["action": install ? "install" : "uninstall"])
        let (data, response) = try await dataWithDeadline(request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.decoding }
        return decodeClaudeStatuslineResult(status: http.statusCode, data: data)
    }

    /// Claude 额度的状态行是否已安装（只读）。内容不对抛 decoding，调用方不把它当作未安装。
    public func claudeStatuslineInstalled() async throws -> Bool {
        var request = URLRequest(url: try endpoint.url(BridgeAPI.Path.accounts + "/claude/statusline"))
        if let timeout { request.timeoutInterval = timeout }
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        let (data, response) = try await dataWithDeadline(request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.decoding }
        guard (200...299).contains(http.statusCode) else { throw BridgeError.http(status: http.statusCode) } // 保留状态码：404 = 旧 Bridge
        guard let v = try? JSONDecoder().decode(ClaudeStatuslineStatus.self, from: data) else { throw BridgeError.decoding }
        return v.installed
    }

    /// 立即更新价格（需可控设备）：只回固定原因码。
    public func refreshPrices() async throws -> PriceRefreshResult {
        var request = URLRequest(url: try endpoint.url(BridgeAPI.Path.usage + "/prices/refresh"))
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = "POST"
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        let (data, response) = try await dataWithDeadline(request) // 非 2xx 也要读正文里的固定原因码
        guard let http = response as? HTTPURLResponse else { throw BridgeError.decoding }
        return Self.decodePriceRefresh(status: http.statusCode, body: data)
    }

    static func decodePriceRefresh(status: Int, body: Data) -> PriceRefreshResult {
        struct Ok: Decodable { var result: String; var pricing: UsagePricingInfo }
        struct Err: Decodable { var error: String; var retryAfterMs: Int? }
        if status == 200 {
            guard let ok = try? JSONDecoder().decode(Ok.self, from: body) else { return .failed(code: "invalid_response") }
            switch ok.result { case "updated": return .updated(ok.pricing); case "current": return .current(ok.pricing); default: return .failed(code: "invalid_response") }
        }
        let err = try? JSONDecoder().decode(Err.self, from: body)
        if status == 429 { return .rateLimited(retryAfterMs: err?.retryAfterMs ?? 60_000) }
        if status == 401 { return .failed(code: "unauthorized") }
        if status == 404 { return .failed(code: "unsupported") } // 旧 Bridge 没有这个端点
        return .failed(code: err?.error ?? "fetch_failed")
    }

    /// 设备自改名（O1-364）：只改自己的展示名，不影响身份与权限；名字先过 DeviceNameRules。失败只抛 BridgeError.http(status)。
    public func renameSelf(_ name: String) async throws -> DeviceInfo {
        let r: DeviceResponse = try await request("PATCH", BridgeAPI.Path.devicesSelf, body: ["name": name], authorized: true)
        return r.device
    }

    /// 设备级暂停：只改自己，幂等；暂停后本设备的 send 返回 409，state/SSE/审批不受影响。
    public func setPaused(_ paused: Bool) async throws -> DeviceInfo {
        let r: DeviceResponse = try await request("PUT", BridgeAPI.Path.devicesSelf, body: ["paused": paused], authorized: true)
        return r.device
    }

    /// 设备自撤：用自己的令牌把自己从 Bridge 移除（重新配对同一台 Mac 后清掉旧的重复记录）。不需要 control；令牌已失效时抛 401。
    public func deleteSelf() async throws {
        struct Removed: Decodable { var removed: Bool }
        let r: Removed = try await request("DELETE", BridgeAPI.Path.devicesSelf, body: [String: String](), authorized: true)
        guard r.removed else { throw BridgeError.decoding }
    }

    /// 「在 Herdr 中显示」：让 Mac 上的 Herdr 把焦点切到该目标当前绑定的 agent（不发送任何输入）。
    /// 失败时回 Bridge 的固定错误码（read_only / target_not_found / pane_gone / pane_changed / herdr_unavailable 等）。
    public func reveal(targetId: String) async throws -> RevealResult {
        var segment = CharacterSet.urlPathAllowed; segment.remove(charactersIn: "/")
        guard let id = targetId.addingPercentEncoding(withAllowedCharacters: segment) else { throw BridgeError.badURL }
        var request = URLRequest(url: try endpoint.url(BridgeAPI.Path.targets + "/" + id + BridgeAPI.Path.revealSuffix, percentEncoded: true))
        request.httpMethod = "POST"
        request.setValue(BridgeAPI.Header.json, forHTTPHeaderField: BridgeAPI.Header.contentType)
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await dataWithDeadline(request) // 经公共绝对期限（O1-349 R4）
        guard let http = response as? HTTPURLResponse else { throw BridgeError.decoding }
        if (200..<300).contains(http.statusCode) { return .ok }
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        return .failed(status: http.statusCode, code: code)
    }

    private struct ErrorBody: Decodable { var error: String? }

    // MARK: #21 Issue 任务（S2）：读取走 GET，写入走 POST；失败保留 Bridge 的固定错误码（IssueTaskError）。

    public func issueTaskOptions() async throws -> IssueTaskOptions {
        try await issueCall("GET", IssueTaskPath.options, optionsRoute: true)
    }

    public func issueTaskList(sourceId: String, page: Int) async throws -> IssueTaskListPage {
        try await issueCall("GET", IssueTaskPath.githubIssues, query: [URLQueryItem(name: "sourceId", value: sourceId), URLQueryItem(name: "page", value: String(page))])
    }

    public func issueTaskDetail(sourceId: String, number: Int) async throws -> IssueTaskDetail {
        try await issueCall("GET", IssueTaskPath.githubIssue(sourceId: sourceId, number: number))
    }

    /// 预览（无状态、零写入）。
    public func issueTaskPreview(_ request: IssueTaskRequest) async throws -> IssueTaskPreview {
        try await issueCall("POST", IssueTaskPath.preview, body: try JSONEncoder().encode(request))
    }

    /// 确认入队：只回传 textDigest，服务端按同一来源重新生成并比对。202 只证明已入队。
    public func issueTaskCreate(_ request: IssueTaskRequest) async throws -> IssueTaskCreated {
        try await issueCall("POST", IssueTaskPath.create, body: try JSONEncoder().encode(request))
    }

    private func issueCall<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, optionsRoute: Bool = false) async throws -> T {
        var request = URLRequest(url: try endpoint.url(path, query: query))
        request.httpMethod = method
        if body != nil { request.setValue(BridgeAPI.Header.json, forHTTPHeaderField: BridgeAPI.Header.contentType) }
        request.httpBody = body
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        let (data, response) = try await dataWithDeadline(request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw IssueTaskError.failure(status: http.statusCode, body: data, optionsRoute: optionsRoute)
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw BridgeError.decoding }
    }

    /// 会话记录线程的一页（由旧到新）。`before` 传上一页的 `nextBefore`；游标失效时 Bridge 返回 410（`BridgeError.http(status: 410)`），
    /// 调用方丢弃旧游标从最新页重来。只读设备也可读。
    /// 窗格当前视口镜像（只读；只读设备可读）。
    public func screen(targetId: String) async throws -> ScreenSnapshot {
        var segment = CharacterSet.urlPathAllowed; segment.remove(charactersIn: "/")
        guard let id = targetId.addingPercentEncoding(withAllowedCharacters: segment) else { throw BridgeError.badURL }
        return try await get(BridgeAPI.Path.targets + "/" + id + BridgeAPI.Path.screenSuffix)
    }

    private func targetPath(_ targetId: String, _ suffix: String) throws -> String {
        var segment = CharacterSet.urlPathAllowed; segment.remove(charactersIn: "/")
        guard let id = targetId.addingPercentEncoding(withAllowedCharacters: segment) else { throw BridgeError.badURL }
        return BridgeAPI.Path.targets + "/" + id + suffix
    }
    /// 终端输入会话（第二片，需要 control）。
    public func inputSession(targetId: String) async throws -> InputSession { try await get(targetPath(targetId, BridgeAPI.Path.inputSessionSuffix)) }
    public func openInput(targetId: String) async throws -> InputSession { try await post(targetPath(targetId, BridgeAPI.Path.inputSessionSuffix), body: [:], authorized: true) }
    public func closeInput(targetId: String) async throws { let _: EmptyObject = try await request("DELETE", targetPath(targetId, BridgeAPI.Path.inputSessionSuffix), body: EmptyObject(), authorized: true) }
    /// 发按键（白名单，≤8）或一行文本（≤200，不含换行）：只发用户按下的内容，不自动回车。
    public func sendKeys(targetId: String, keys: [String]) async throws -> KeysResponse { try await request("POST", targetPath(targetId, BridgeAPI.Path.keysSuffix), body: ["keys": keys], authorized: true) }
    public func sendText(targetId: String, text: String) async throws -> KeysResponse { try await post(targetPath(targetId, BridgeAPI.Path.keysSuffix), body: ["text": text], authorized: true) }

    public func transcript(targetId: String, before: String? = nil, limit: Int = BridgeAPI.transcriptPageLimit) async throws -> TranscriptPage {
        var segment = CharacterSet.urlPathAllowed; segment.remove(charactersIn: "/")
        guard let id = targetId.addingPercentEncoding(withAllowedCharacters: segment) else { throw BridgeError.badURL }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        var request = URLRequest(url: try endpoint.url(BridgeAPI.Path.targets + "/" + id + BridgeAPI.Path.transcriptSuffix, query: query, percentEncoded: true))
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        return try await perform(request)
    }

    /// 条件读取（#88 S2）：带上 If-None-Match（只在缓存中仍有同一页时）；304 为未变，无正文。
    public func transcriptConditional(targetId: String, before: String? = nil, limit: Int = BridgeAPI.transcriptPageLimit, ifNoneMatch: String? = nil) async throws -> TranscriptFetch {
        try await transcriptConditional(targetId: targetId, before: before, limit: limit, ifNoneMatch: ifNoneMatch, receipt: nil)
    }

    /// 同上，首页读取可携带回执后补声明（`before` 非 nil 时忽略）。
    public func transcriptConditional(targetId: String, before: String?, limit: Int, ifNoneMatch: String?, receipt: TranscriptReceiptRequest?) async throws -> TranscriptFetch {
        var segment = CharacterSet.urlPathAllowed; segment.remove(charactersIn: "/")
        guard let id = targetId.addingPercentEncoding(withAllowedCharacters: segment) else { throw BridgeError.badURL }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        else if let receipt { query += receipt.queryItems } // 后补只附首页读取；Bridge 对 before 与后补参数混用回 400
        var request = URLRequest(url: try endpoint.url(BridgeAPI.Path.targets + "/" + id + BridgeAPI.Path.transcriptSuffix, query: query, percentEncoded: true))
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await dataWithDeadline(request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.decoding }
        return try TranscriptFetch.parse(status: http.statusCode, etag: http.value(forHTTPHeaderField: "ETag"), data: data)
    }

    /// 按条续读（#88 S2）：取截断条目的下一段，令牌原样传回；reset（410）等错误按 BridgeError.http 抛出。
    public func transcriptItem(targetId: String, itemId: String, continuation: String) async throws -> TranscriptItemSegment {
        var segment = CharacterSet.urlPathAllowed; segment.remove(charactersIn: "/")
        guard let id = targetId.addingPercentEncoding(withAllowedCharacters: segment),
              let item = itemId.addingPercentEncoding(withAllowedCharacters: segment) else { throw BridgeError.badURL }
        let query = [URLQueryItem(name: "cont", value: continuation)]
        var request = URLRequest(url: try endpoint.url(BridgeAPI.Path.targets + "/" + id + BridgeAPI.Path.transcriptSuffix + "/items/" + item, query: query, percentEncoded: true))
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        return try await perform(request)
    }

    /// 目标账本历史（#97）：只读，按游标向更旧翻页；目标已删除登记时仍可读。
    public func targetHistory(targetId: String, before: String? = nil, limit: Int = 20) async throws -> TargetHistoryPage {
        var segment = CharacterSet.urlPathAllowed; segment.remove(charactersIn: "/")
        guard let id = targetId.addingPercentEncoding(withAllowedCharacters: segment) else { throw BridgeError.badURL }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        var request = URLRequest(url: try endpoint.url(BridgeAPI.Path.targets + "/" + id + BridgeAPI.Path.historySuffix, query: query, percentEncoded: true))
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        return try await perform(request)
    }

    /// 会话内容搜索（只读；只读设备可用）。同一设备同时只允许一个在途搜索，另一个得到 `BridgeError.http(status: 409)`。
    public func search(q: String, limit: Int = BridgeAPI.searchLimit) async throws -> SearchResponse {
        let query = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: String(limit))]
        var request = URLRequest(url: try endpoint.url(BridgeAPI.Path.search, query: query))
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        return try await perform(request)
    }

    // 事件流：返回逐个事件的异步序列。断线由调用方按最后 seq 重连。
    // 构造请求后交给独立的流函数，闭包只捕获不可变、可发送的值，满足 Swift 6 区域隔离检查。
    public func events(since: Int?, firstByteDeadline: TimeInterval = BridgeAPI.Deadline.streamFirstByte) throws -> AsyncThrowingStream<BridgeEvent, Error> {
        var query: [URLQueryItem] = []
        if let since { query.append(URLQueryItem(name: "since", value: String(since))) }
        let url = try endpoint.url(BridgeAPI.Path.events, query: query)
        var request = URLRequest(url: url)
        request.timeoutInterval = BridgeAPI.Deadline.streamIdle
        request.setValue(BridgeAPI.Header.eventStream, forHTTPHeaderField: BridgeAPI.Header.accept)
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        return Self.stream(request: request, session: session, firstByteDeadline: firstByteDeadline)
    }

    private nonisolated static func stream(request: URLRequest, session: URLSession, firstByteDeadline: TimeInterval) -> AsyncThrowingStream<BridgeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 按任务显式带上固定证书的代理：会话级代理对 bytes(for:) 不一定生效。
                    // 首字节期限：卡在等响应头的尝试到期即取消（#85）；期限内拿到响应头后，正文由帧看门狗负责。
                    let (bytes, response) = try await Self.withAbsoluteDeadline(firstByteDeadline) {
                        try await session.bytes(for: request, delegate: session.delegate as? URLSessionTaskDelegate)
                    }
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw BridgeError.http(status: http.statusCode)
                    }
                    var parser = SSEParser()
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == UInt8(ascii: "\n") {
                            for frame in parser.feed(chunk) { continuation.yield(BridgeEventDecoder.decode(frame)) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let query = parts.count == 2 ? parts[1].split(separator: "&").map { kv -> URLQueryItem in
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init); return URLQueryItem(name: p[0], value: p.count == 2 ? p[1] : nil)
        } : []
        let url = try endpoint.url(parts[0], query: query)
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        if let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        return try await perform(request)
    }

    struct EmptyObject: Codable {}

    private func post<T: Decodable>(_ path: String, body: [String: String], authorized: Bool, deadline: TimeInterval? = nil) async throws -> T {
        try await request("POST", path, body: body, authorized: authorized, deadline: deadline)
    }

    private func request<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B, authorized: Bool, deadline: TimeInterval? = nil) async throws -> T {
        let url = try endpoint.url(path)
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = method
        request.setValue(BridgeAPI.Header.json, forHTTPHeaderField: BridgeAPI.Header.contentType)
        if authorized, let token { request.setValue(BridgeAPI.Header.bearerPrefix + token, forHTTPHeaderField: BridgeAPI.Header.authorization) }
        // 字典体的键序每次编码都可能不同；固定键序让同一请求的线上字节稳定。
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(body)
        return try await perform(request, deadline: deadline)
    }

    /// 绝对期限：`URLRequest.timeoutInterval` 只是空闲超时，正文持续滴答会一直等；这里按 `timeout` 从发起时刻起算，到期取消请求（A1-157 F6-R3）。
    /// 实例的 timeout（调用方显式给的）优先；否则用本次请求的期限；都没有则用常规期限（O1-348：此前只有 60 秒空闲超时）。
    private func dataWithDeadline(_ request: URLRequest, deadline: TimeInterval? = nil) async throws -> (Data, URLResponse) {
        let session = self.session
        return try await Self.withAbsoluteDeadline(timeout ?? deadline ?? BridgeAPI.Deadline.request) {
            try await session.data(for: request, delegate: session.delegate as? URLSessionTaskDelegate)
        }
    }

    /// 绝对期限：超过 seconds 即取消操作并抛出 URLError(.timedOut)；操作本身可取消（URLSession 会立即结束）。
    static func withAbsoluteDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }

    private func perform<T: Decodable>(_ request: URLRequest, deadline: TimeInterval? = nil) async throws -> T {
        let (data, response) = try await dataWithDeadline(request, deadline: deadline)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.decoding }
        guard (200..<300).contains(http.statusCode) else { throw BridgeError.http(status: http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw BridgeError.decoding }
    }
}
