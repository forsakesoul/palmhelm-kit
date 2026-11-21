import Foundation

// #21 S2：派发流程的共享规则（两端共用，不各写一套）。网络细节经 IssueTaskTransport 注入，便于用延迟假响应测试。

/// 派发需要的网络操作。BridgeClient 即实现。
public protocol IssueTaskTransport: Sendable {
    func issueTaskOptions() async throws -> IssueTaskOptions
    func issueTaskList(sourceId: String, page: Int) async throws -> IssueTaskListPage
    func issueTaskDetail(sourceId: String, number: Int) async throws -> IssueTaskDetail
    func issueTaskPreview(_ request: IssueTaskRequest) async throws -> IssueTaskPreview
    func issueTaskCreate(_ request: IssueTaskRequest) async throws -> IssueTaskCreated
}

extension BridgeClient: IssueTaskTransport {}

/// 失败后的恢复动作：作废预览、重新读取来源或选项，由用户显式重新预览或重选（不悄悄续用旧身份）。
public enum IssueTaskRecovery: Equatable, Sendable {
    case none
    case repreview
    case refreshDetail
    case refreshOptions
}

/// 失败的分类：服务端固定拒绝、结果未知（请求可能已到达）、旧 Bridge。
public enum IssueTaskFailure: Equatable, Sendable {
    case refused(code: String?, recovery: IssueTaskRecovery)
    case unknown
    case legacyBridge
    /// 本机门禁拦下（勿扰、暂停、断线、只读等）：没有发出请求，文案即门禁原因。
    case blocked(String)
}

/// 本机门禁的拒绝：会话层在发出请求之前抛出，保证被拦下时零请求。
public struct IssueTaskBlocked: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// 一次异步操作在连接代次核对之后的结论。`discarded` 表示发起后连接已变化，结果不得落到新连接上。
public enum IssueTaskResolution<Value: Sendable>: Sendable {
    case value(Value)
    case failed(IssueTaskFailure)
    case discarded
}

public enum IssueTaskFlow {
    public static func classify(_ error: Error) -> IssueTaskFailure {
        if let b = error as? IssueTaskBlocked { return .blocked(b.reason) }
        guard let e = error as? IssueTaskError else { return .unknown }
        switch e {
        case .unsupported: return .legacyBridge
        case let .http(_, code): return .refused(code: code, recovery: recovery(for: code))
        }
    }

    public static func recovery(for code: String?) -> IssueTaskRecovery {
        switch code {
        case "source_changed": return .refreshDetail
        case "destination_changed": return .refreshOptions
        case "preview_changed": return .repreview
        default: return .none
        }
    }

    /// 结果只在发起时的范围内有效：连接代次与草稿版本都必须一致（A1-190 F1）。任一变化即丢弃，不回显、不导航、不写入草稿。
    public static func resolve<Value: Sendable>(_ result: Result<Value, Error>, started: IssueTaskScope, current: IssueTaskScope) -> IssueTaskResolution<Value> {
        guard started == current else { return .discarded }
        switch result {
        case let .success(value): return .value(value)
        case let .failure(error): return .failed(classify(error))
        }
    }
}

/// 异步操作的作用域：发起时的连接代次与草稿版本。
public struct IssueTaskScope: Equatable, Sendable {
    public let epoch: Int
    public let draft: Int
    public init(epoch: Int, draft: Int) { self.epoch = epoch; self.draft = draft }
}

/// 结果未知的提交：只保存在当前 sheet 内，保存完整、不可变的请求（含 UUID 与 textDigest）。只能原样重投核对（A1-192 R2）。
public struct IssueTaskPendingSubmission: Equatable, Sendable {
    public let request: IssueTaskRequest
    public let summary: String
    public let targetId: String
    public init(request: IssueTaskRequest, summary: String, targetId: String) {
        self.request = request; self.summary = summary; self.targetId = targetId
    }
}

/// 最新选择序号：每次点选递增；返回的读取只采纳最新的一次（A1-192 R1）。
public struct IssueTaskSelectionGate: Sendable {
    private var latest = 0
    public init() {}
    /// 发起一次选择，返回它的序号。
    public mutating func next() -> Int {
        latest += 1
        return latest
    }
    /// 只有最新选择的结果才采纳；更早发起的结果一律丢弃。
    public func isLatest(_ sequence: Int) -> Bool { sequence == latest }
}

extension IssueTaskFlow {
    /// 确认只发出一次：原请求原样交给传输层（不重建 UUID 或正文）。
    public static func createOnce(_ transport: IssueTaskTransport, _ request: IssueTaskRequest) async -> Result<IssueTaskCreated, Error> {
        do { return .success(try await transport.issueTaskCreate(request)) } catch { return .failure(error) }
    }
}
