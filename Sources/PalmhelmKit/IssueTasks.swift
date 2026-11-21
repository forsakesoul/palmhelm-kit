import Foundation

// #21 S2：从 Palmhelm 派发 Issue / 需求任务。Kit 只做契约（DTO、请求形状）、固定文案与纯规则；
// 界面（sheet、列表、确认页）在两端。服务端是唯一的正文生成点，客户端不拼模板。

public enum IssueTaskPath {
    public static let options = "/v1/issue-tasks/options"
    public static let githubIssues = "/v1/issue-tasks/github/issues"
    public static let preview = "/v1/issue-tasks/preview"
    public static let create = "/v1/issue-tasks"
    public static func githubIssue(sourceId: String, number: Int) -> String { "\(githubIssues)/\(sourceId)/\(number)" }
}

/// `GET /v1/issue-tasks/options`。
public struct IssueTaskOptions: Decodable, Equatable, Sendable {
    /// 派发总开关（Bridge 派发关闭时手工需求也不可用）。
    public let createSupported: Bool
    public let dispatchEnabled: Bool
    public let github: IssueTaskGitHub
    public let sources: [IssueTaskSource]
    public let targets: [IssueTaskTarget]
    public let maxPromptUnits: Int
    /// Bridge 0.3.11 起给出（["zh","en"]）；缺失 = 旧 Bridge，只会生成中文模板。未知成员原样保留、不影响解码。
    public let templateLanguages: [String]?
}

/// 任务模板（Bridge 生成的固定外壳）的语言；只影响模板，不翻译 Issue 标题/正文/附言。
public enum IssueTaskTemplateLanguage: String, Encodable, Sendable { case zh, en }

public struct IssueTaskGitHub: Decodable, Equatable, Sendable {
    public let available: Bool
    /// 不可用的固定原因（如 `github_unavailable`）；可用时为 nil。
    public let reason: String?
    /// GitHub 来源是否可用（gh 可用且允许列表非空）；与手工需求的 `createSupported` 分开（spec §3）。
    public let createSupported: Bool
}

public struct IssueTaskSource: Decodable, Equatable, Hashable, Sendable {
    public let sourceId: String
    public let repo: String
}

public struct IssueTaskTarget: Decodable, Equatable, Hashable, Sendable {
    public let targetId: String
    public let label: String
    /// 可派发时给出目的地版本（不透明）；不可用时为 nil，`reason` 给出固定原因。
    public let destinationVersion: String?
    public let reason: String?
    /// "sensitive"：label 被 Bridge 的敏感规则替换成占位，客户端显示本地化占位（label 不是真名，不可当数据用）。
    public var labelPlaceholder: String? = nil
    public var usable: Bool { destinationVersion != nil }
    public var displayLabel: String { IssueTaskPlaceholder.text(label, labelPlaceholder) }
}

/// Bridge 对 Issue 来源字段的敏感占位标记（`<field>Placeholder:"sensitive"`）：只用于显示，被占位的值不可作为可派发正文。
public enum IssueTaskPlaceholder {
    public static func text(_ raw: String, _ marker: String?) -> String { marker == "sensitive" ? KitL10n.string("（已隐藏）") : raw }
}

/// `GET /v1/issue-tasks/github/issues?sourceId&page` 的一页。
public struct IssueTaskListPage: Decodable, Equatable, Sendable {
    public let items: [IssueTaskListItem]
    public let page: Int
}

public struct IssueTaskListItem: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public let number: Int
    public var id: Int { number }
    public let title: String
    public let state: String
    public let updatedAt: String
    public let url: String
    public var titlePlaceholder: String? = nil
    public var displayTitle: String { IssueTaskPlaceholder.text(title, titlePlaceholder) }
    public var isClosed: Bool { state == "closed" }
}

/// `GET /v1/issue-tasks/github/issues/{sourceId}/{number}`：白名单字段、正文（已过出站检查）与来源版本。
public struct IssueTaskDetail: Decodable, Equatable, Sendable {
    public let number: Int
    public let title: String
    public let state: String
    public let updatedAt: String
    public let url: String
    public let body: String
    public let sourceVersion: String
    public var titlePlaceholder: String? = nil
    public var bodyPlaceholder: String? = nil
    public var displayTitle: String { IssueTaskPlaceholder.text(title, titlePlaceholder) }
    public var displayBody: String { IssueTaskPlaceholder.text(body, bodyPlaceholder) }
    public var isClosed: Bool { state == "closed" }
}

/// `POST /v1/issue-tasks/preview` 的结果：`text` 是待发的完整正文，确认时只回传 `textDigest`。
public struct IssueTaskPreview: Decodable, Equatable, Sendable {
    public let text: String
    public let textDigest: String
    public let destinationVersion: String
    public let sourceVersion: String?
}

/// `POST /v1/issue-tasks` 的 202：只证明已入队（不是执行结果）。
public struct IssueTaskCreated: Decodable, Equatable, Sendable {
    public let accepted: Bool
    public let eventKey: String
}

/// 请求里的来源。GitHub 只带 sourceId、number、version；手工只带标题、说明与可选参考链接。
public enum IssueTaskSourceInput: Encodable, Equatable, Sendable {
    case github(sourceId: String, number: Int, version: String)
    case manual(title: String, description: String, referenceUrl: String?)

    enum Keys: String, CodingKey { case kind, sourceId, number, version, title, description, referenceUrl }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .github(sourceId, number, version):
            try c.encode("github", forKey: .kind)
            try c.encode(sourceId, forKey: .sourceId)
            try c.encode(number, forKey: .number)
            try c.encode(version, forKey: .version)
        case let .manual(title, description, referenceUrl):
            try c.encode("manual", forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(description, forKey: .description)
            try c.encodeIfPresent(referenceUrl, forKey: .referenceUrl)
        }
    }
}

/// 预览与确认的共同请求体。确认时额外带 `clientMsgId` 与 `textDigest`（`clientMsgId` 为 nil 即预览）。
public struct IssueTaskRequest: Encodable, Equatable, Sendable {
    public let targetId: String
    public let destinationVersion: String
    public let source: IssueTaskSourceInput
    public let instructions: String
    public let ackClosed: Bool
    public let clientMsgId: String?
    public let textDigest: String?
    /// nil = 不编码该字段（旧 Bridge / 旧调用）；预览与确认必须同值，否则服务端按语言不同拒绝重投。
    public let templateLanguage: IssueTaskTemplateLanguage?

    public init(targetId: String, destinationVersion: String, source: IssueTaskSourceInput, instructions: String,
                ackClosed: Bool, clientMsgId: String? = nil, textDigest: String? = nil, templateLanguage: IssueTaskTemplateLanguage? = nil) {
        self.targetId = targetId; self.destinationVersion = destinationVersion; self.source = source
        self.instructions = instructions; self.ackClosed = ackClosed; self.clientMsgId = clientMsgId; self.textDigest = textDigest
        self.templateLanguage = templateLanguage
    }

    enum Keys: String, CodingKey { case targetId, destinationVersion, source, instructions, ackClosed, clientMsgId, textDigest, templateLanguage }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(targetId, forKey: .targetId)
        try c.encode(destinationVersion, forKey: .destinationVersion)
        try c.encode(source, forKey: .source)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(ackClosed, forKey: .ackClosed)
        try c.encodeIfPresent(clientMsgId, forKey: .clientMsgId)
        try c.encodeIfPresent(textDigest, forKey: .textDigest)
        try c.encodeIfPresent(templateLanguage, forKey: .templateLanguage)
    }
}

/// 写接口的业务错误（HTTP 非 2xx）。`code` 是 Bridge 的固定错误码；旧 Bridge 没有该路由时为 404 且无码。
public enum IssueTaskError: Error, Equatable, Sendable {
    case http(status: Int, code: String?)
    /// 旧 Bridge：options 路由本身 404（没有 issue-task 路由）。只由 options 请求产生，不与 Issue 的合法 404 混淆（A1-187 R3）。
    case unsupported
    public var isUnsupportedBridge: Bool { self == .unsupported }

    /// 把 HTTP 失败映射为 Kit 的错误。options 路由的 404 一律是旧 Bridge；其它路由保留固定错误码。
    public static func failure(status: Int, body: Data, optionsRoute: Bool) -> IssueTaskError {
        if optionsRoute, status == 404 { return .unsupported }
        struct Body: Decodable { let error: String? }
        return .http(status: status, code: (try? JSONDecoder().decode(Body.self, from: body))?.error)
    }
}

public enum IssueTaskRules {
    public static let maxTitleUnits = 200

    /// 与服务端同一口径：UTF-16 码元。
    public static func units(_ s: String) -> Int { s.utf16.count }

    /// 手工需求：标题必填（≤200）；描述必填。
    public static func manualValid(title: String, description: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && units(t) <= maxTitleUnits && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 参考链接只接受 https://github.com/<owner>/<repo>/issues/<n>（与服务端相同的形状；不接受查询、片段、用户信息）。
    public static func validReferenceURL(_ s: String) -> Bool {
        let prefix = "https://github.com/"
        guard s.hasPrefix(prefix) else { return false }
        let parts = s.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[2] == "issues" else { return false }
        let name = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard (1...100).contains(parts[0].count), (1...100).contains(parts[1].count),
              parts[0].unicodeScalars.allSatisfy(name.contains), parts[1].unicodeScalars.allSatisfy(name.contains) else { return false }
        let number = parts[3]
        return number.count >= 1 && number.count <= 9 && number.first != "0" && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }

    /// GitHub 来源能否选择：gh 与允许列表都可用。不可用时整块灰掉（手工需求不受影响）。
    public static func githubAvailable(_ o: IssueTaskOptions) -> Bool { o.github.createSupported }

    /// 来源分段的默认值：GitHub 可用时默认 GitHub，否则默认手工需求（GitHub 分段此时禁用，不能停在它上面）。
    public static func defaultSource(_ o: IssueTaskOptions) -> IssueTaskDraft.Source { githubAvailable(o) ? .github : .manual }

    /// 手工需求能否开始：派发总开关打开且至少有一个可派发的会话。
    public static func manualAvailable(_ o: IssueTaskOptions) -> Bool { o.createSupported && o.targets.contains { $0.usable } }

    /// 确认页主按钮：预览已到且服务端给出了版本。
    public static func canConfirm(preview: IssueTaskPreview?) -> Bool { preview != nil }

    /// 固定文案：来自 Bridge 的错误码。未知码统一为「派发失败」，不回显服务端原文。
    public static func errorCopy(_ error: Error) -> String {
        guard let e = error as? IssueTaskError else { return KitL10n.string("派发失败，消息没有发出。") }
        if e.isUnsupportedBridge { return upgradeCopy }
        guard case let .http(_, code) = e, let code else { return KitL10n.string("派发失败，消息没有发出。") }
        return copy(forCode: code)
    }

    /// 解析结果的失败：旧 Bridge、结果未知（不冒充失败）、服务端固定拒绝。
    public static func errorCopy(_ failure: IssueTaskFailure) -> String {
        switch failure {
        case .legacyBridge: return upgradeCopy
        case .unknown: return KitL10n.string("网络结果未知，消息可能已发出。")
        case let .blocked(reason): return reason
        case let .refused(code, _): return code.map(copy(forCode:)) ?? KitL10n.string("派发失败，消息没有发出。")
        }
    }

    /// 当前界面语言对应的模板语言（按资源语言，不看地区或 Accept-Language）。
    public static func templateLanguage(resource: String) -> IssueTaskTemplateLanguage { resource.hasPrefix("en") ? .en : .zh }

    /// 该语言能否在这台 Bridge 上发：能力里有就发；没有能力字段（旧 Bridge）时中文照旧不带字段，英文不降级成中文。
    public enum TemplateDecision: Equatable, Sendable { case send(IssueTaskTemplateLanguage?), needsNewerBridge }
    public static func templateDecision(options: IssueTaskOptions?, resource: String) -> TemplateDecision {
        let lang = templateLanguage(resource: resource)
        if options?.templateLanguages?.contains(lang.rawValue) == true { return .send(lang) }
        return lang == .zh ? .send(nil) : .needsNewerBridge
    }
    public static var templateUpgradeCopy: String { KitL10n.string("英文任务模板需要 Bridge 0.3.11 或更新版本。") }

    static var upgradeCopy: String { KitL10n.string("这台 Bridge 还不支持从 Palmhelm 派发任务，请先升级 Bridge。") }

    static func copy(forCode code: String) -> String {
        switch code {
        case "destination_changed": return KitL10n.string("执行会话已变化，请重新选择。")
        case "target_unavailable": return KitL10n.string("这个执行会话现在不可用，请换一个。")
        case "direct_not_available": return KitL10n.string("这个会话只支持原生会话，暂不能派发。")
        case "owner_only": return KitL10n.string("kit.handoff.no_dispatch.full", default: "交接会话不接收派发。")
        case "not_observed": return KitL10n.string("kit.session.not_found.full", default: "没有在 Mac 上找到这个会话。")
        case "preview_changed": return KitL10n.string("需求内容已变化，请重新预览后再确认。")
        case "source_changed": return KitL10n.string("Issue 已更新，请重新预览后再确认。")
        case "closed_unacknowledged": return KitL10n.string("这个 Issue 已关闭，请先确认仍要处理。")
        case "idempotency_conflict": return KitL10n.string("这条请求的内容已变化，请返回重新预览后发送。")
        case "content_blocked": return KitL10n.string("内容含有敏感信息，无法派发。请删去相关内容后重试。")
        case "prompt_too_large": return KitL10n.string("内容超过 8000 字符上限，请精简后再试；不会自动截断。")
        case "device_paused": return KitL10n.string("此设备已暂停接收任务。")
        case "read_only": return KitL10n.string("此设备只有查看权限，不能派发任务。")
        case "dispatch_disabled": return KitL10n.string("Mac 上的 Bridge 没有开启派发。")
        case "busy": return KitL10n.string("GitHub 读取繁忙，请稍后再试。")
        case "source_unavailable": return KitL10n.string("暂时无法读取 GitHub，请稍后再试。")
        case "not_found": return KitL10n.string("找不到这个 Issue，或它不在允许的来源仓库里。")
        case "shutting_down": return KitL10n.string("Bridge 正在停止，请稍后再试。")
        case "unauthorized": return KitL10n.string("连接已失效，请重新配对。")
        default: return KitL10n.string("派发失败，消息没有发出。")
        }
    }

    /// gh 不可用时的固定说明（只指引到 Mac 终端，不替用户安装或登录）。
    public static func githubUnavailableCopy(reason: String?) -> String {
        switch reason {
        case "github_unavailable": return KitL10n.string("这台 Mac 上找不到可用的 GitHub CLI（gh），或它尚未登录。请到 Mac 终端执行 gh auth login，完成后再回来。手工需求仍可用。")
        default: return KitL10n.string("GitHub 来源暂不可用。请到 Mac 终端检查 gh 登录状态。手工需求仍可用。")
        }
    }

    /// 目的地不可选时的固定说明（按 Bridge 给出的原因）。
    public static func targetReasonCopy(_ reason: String?) -> String {
        switch reason {
        case "owner_only": return KitL10n.string("kit.handoff.no_dispatch.short", default: "交接会话不接收派发")
        case "direct_not_available": return KitL10n.string("只支持原生会话")
        case "not_observed": return KitL10n.string("kit.session.not_found.short", default: "没有在 Mac 上找到这个会话")
        case "target_unavailable": return KitL10n.string("会话暂不可用（已暂停或配置异常）")
        case "owner_only_session": return KitL10n.string("kit.handoff.no_dispatch.short", default: "交接会话不接收派发")
        default: return KitL10n.string("暂不可派发")
        }
    }
}

/// 派发表单的草稿（只在界面内存中，不落盘）。任何会进入正文的字段变化都会作废已取得的预览，
/// 确认只能用当前预览的 textDigest 与版本（spec §4：预览后的编辑必须重新预览）。
public struct IssueTaskDraft: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case github, manual }

    public var source: Source = .github { didSet { if oldValue != source { touched() } } }
    public var targetId: String? { didSet { if oldValue != targetId { touched() } } }
    public var destinationVersion: String? { didSet { if oldValue != destinationVersion { touched() } } }
    public var sourceId: String? { didSet { if oldValue != sourceId { issue = nil; touched() } } }
    public var issue: IssueTaskDetail? { didSet { if oldValue != issue { touched() } } }
    public var instructions: String = "" { didSet { if oldValue != instructions { touched() } } }
    public var ackClosed: Bool = false { didSet { if oldValue != ackClosed { touched() } } }
    public var title: String = "" { didSet { if oldValue != title { touched() } } }
    public var description: String = "" { didSet { if oldValue != description { touched() } } }
    public var referenceUrl: String = "" { didSet { if oldValue != referenceUrl { touched() } } }
    /// 随请求发出的模板语言（预览与确认同源）；只能经 syncTemplateLanguage 设置。
    public private(set) var templateLanguage: IssueTaskTemplateLanguage?
    /// 英文界面遇到旧 Bridge：不预览、不发请求，界面显示升级提示。
    public private(set) var templateNeedsNewerBridge = false
    /// 最近一次预览（只在它与当前草稿一致时可确认）。
    public private(set) var preview: IssueTaskPreview?

    /// 草稿内容的版本：任何会进入请求或正文的字段变化都递增。异步读取绑定发起时的版本，返回时不一致即丢弃（A1-190 F1）。
    public private(set) var revision = 0

    public init() {}

    public mutating func setPreview(_ p: IssueTaskPreview?) { preview = p }

    /// 按当前界面语言与 Bridge 能力更新模板语言；变化即作废预览（旧在途结果随 revision 丢弃）。
    /// `pending`＝有结果未知的提交：它保留原请求、原语言与原 UUID，只能原样重投，此时一律不改草稿。返回是否发生了变化。
    @discardableResult
    public mutating func syncTemplateLanguage(options: IssueTaskOptions?, resource: String, pending: Bool = false) -> Bool {
        guard !pending else { return false }
        let lang: IssueTaskTemplateLanguage?, blocked: Bool
        switch IssueTaskRules.templateDecision(options: options, resource: resource) {
        case let .send(l): lang = l; blocked = false
        case .needsNewerBridge: lang = nil; blocked = true
        }
        guard lang != templateLanguage || blocked != templateNeedsNewerBridge else { return false }
        templateLanguage = lang; templateNeedsNewerBridge = blocked
        touched()
        return true
    }

    /// 采纳一次预览的结果：只有草稿版本仍是发起时的版本才生效；编辑过则丢弃（A1-190 F1）。
    @discardableResult
    public mutating func acceptPreview(_ p: IssueTaskPreview, startedAt revision: Int) -> Bool {
        guard revision == self.revision else { return false }
        preview = p
        return true
    }

    private mutating func touched() {
        preview = nil
        revision += 1
    }

    /// 来源是否已准备好预览：GitHub 需要选中 Issue（已关闭还需确认）；手工需要标题与说明，参考链接若填写必须合法。
    public var readyForPreview: Bool {
        guard !templateNeedsNewerBridge, let targetId, destinationVersion != nil else { return false }
        switch source {
        case .github:
            guard let issue else { return false }
            return !issue.isClosed || ackClosed
        case .manual:
            guard IssueTaskRules.manualValid(title: title, description: description) else { return false }
            return referenceUrl.isEmpty || IssueTaskRules.validReferenceURL(referenceUrl)
        }
    }

    /// 预览请求（不带确认字段）。未就绪返回 nil。
    public func previewRequest() -> IssueTaskRequest? {
        guard readyForPreview, let targetId, let destinationVersion else { return nil }
        return IssueTaskRequest(targetId: targetId, destinationVersion: destinationVersion, source: sourceInput(), instructions: instructions, ackClosed: ackClosed, templateLanguage: templateLanguage)
    }

    /// 确认请求：只在当前预览存在时生成，回传预览的 textDigest 与服务端给出的来源版本。
    public func createRequest(clientMsgId: String) -> IssueTaskRequest? {
        guard let preview, let targetId, let destinationVersion else { return nil }
        return IssueTaskRequest(targetId: targetId, destinationVersion: destinationVersion, source: sourceInput(), instructions: instructions,
                                ackClosed: ackClosed, clientMsgId: clientMsgId, textDigest: preview.textDigest, templateLanguage: templateLanguage)
    }

    private func sourceInput() -> IssueTaskSourceInput {
        switch source {
        case .github:
            return .github(sourceId: sourceId ?? "", number: issue?.number ?? 0, version: issue?.sourceVersion ?? "")
        case .manual:
            return .manual(title: title.trimmingCharacters(in: .whitespacesAndNewlines), description: description,
                           referenceUrl: referenceUrl.isEmpty ? nil : referenceUrl)
        }
    }
}
