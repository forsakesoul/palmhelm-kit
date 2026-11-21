import Foundation

/// 单个线程草稿槽的纯状态机。
/// 不碰视图与网络：Session 负责 scope/token 核验与副作用，这里只决定槽如何迁移。

public struct DraftSubmission: Equatable, Sendable {
    public let snapshot: String
    public let editGenAtSubmit: Int
    public let token: UUID
    public init(snapshot: String, editGenAtSubmit: Int, token: UUID) {
        self.snapshot = snapshot
        self.editGenAtSubmit = editGenAtSubmit
        self.token = token
    }
}

public struct DraftOffer: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case withdrawn, rejected }
    /// rejected 用提交 token，withdrawn 用撤回事件键；生成后固定。
    public let id: String
    public let text: String
    public let kind: Kind
    public init(id: String, text: String, kind: Kind) {
        self.id = id
        self.text = text
        self.kind = kind
    }
}

/// 槽内提示的类别；文案由视图按本地化表示，Kit 不持有界面文字。
public enum DraftNote: Equatable, Sendable {
    case unknownResult
    case reason(String)
}

public struct DraftSlot: Equatable, Sendable {
    public var text: String = ""
    public var editGen: Int = 0
    public var inFlight: DraftSubmission?
    public var offer: DraftOffer?
    public var note: DraftNote?

    public init(text: String = "", editGen: Int = 0, inFlight: DraftSubmission? = nil, offer: DraftOffer? = nil, note: DraftNote? = nil) {
        self.text = text
        self.editGen = editGen
        self.inFlight = inFlight
        self.offer = offer
        self.note = note
    }

    /// 与 trim 口径一致：纯空白不算草稿，但正文原样保留。
    public var hasDraft: Bool { !WithdrawnDraft.isBlank(text) }
    /// 回收只看精确空串，原始空白格式保留。
    public var isRecyclable: Bool { text.isEmpty && inFlight == nil && offer == nil && note == nil }
}

/// 传输结果映射后的结算类别：完成为 accepted，未知为 unknown（不论标识），拒绝为 rejected。
public enum DraftOutcome: Equatable, Sendable {
    case accepted
    case unknown
    case rejected(String)
}

public enum DraftEvent: Equatable, Sendable {
    /// 用户编辑。
    case userEdit(String)
    /// 提交开始（准入通过后，等待传输之前）。
    case submitAdmitted(token: UUID)
    /// 准入拒绝。
    case submitRefused(String)
    /// 结果到达；提交标识不符时不改变状态。
    case outcome(token: UUID, DraftOutcome)
    /// 撤回的原文到达（事件键作为横幅标识）。
    case withdrawnOffer(text: String, eventKey: String)
    /// 用户选择替换为横幅原文；标识不符则不改变状态。
    case replaceOffer(expectedID: String)
    /// 用户忽略横幅；标识不符则不改变状态。
    case dismissOffer(expectedID: String)
    /// 归档或删除成功后，可回收的槽移除。
    case archivedOrDeleted
}

public struct DraftReduction: Equatable, Sendable {
    public var slot: DraftSlot
    /// 是否推进 revision。
    public var notify: Bool
    /// 草稿状态是否翻转；非 nil 时需同步成员集合。
    public var memberFlip: Bool?
}

public enum DraftReducer {
    public static func reduce(_ slot: DraftSlot, _ event: DraftEvent) -> DraftReduction {
        var s = slot
        let before = slot.hasDraft
        var notify = true
        switch event {
        case .userEdit(let t):
            s.text = t
            s.editGen += 1
            notify = false

        case .submitAdmitted(let token):
            s.editGen += 1
            s.inFlight = DraftSubmission(snapshot: s.text, editGenAtSubmit: s.editGen, token: token)
            s.text = ""
            s.note = nil

        case .submitRefused(let reason):
            s.note = .reason(reason)

        case .outcome(let token, let outcome):
            guard let sub = s.inFlight, sub.token == token else { return DraftReduction(slot: slot, notify: false, memberFlip: nil) }
            switch outcome {
            case .accepted:
                s.inFlight = nil
                if s.offer?.kind == .withdrawn { s.offer = nil }
            case .unknown:
                s.inFlight = nil
                s.note = .unknownResult
            case .rejected(let reason):
                s.inFlight = nil
                if s.editGen == sub.editGenAtSubmit {
                    s.text = sub.snapshot
                } else {
                    s.offer = DraftOffer(id: token.uuidString, text: sub.snapshot, kind: .rejected)
                }
                s.note = .reason(reason)
            }
            settleWithdrawnOffer(&s)

        case .withdrawnOffer(let w, let eventKey):
            if s.offer?.kind == .rejected {
                // 已有被拒的横幅时保留它。
            } else if s.inFlight == nil, WithdrawnDraft.isBlank(s.text), s.offer == nil {
                // 真正的空稿直接回填。
                s.text = w
            } else {
                // 在途或非空：挂成横幅，覆盖旧的撤回横幅。
                s.offer = DraftOffer(id: eventKey, text: w, kind: .withdrawn)
            }

        case .replaceOffer(let expectedID):
            guard let o = s.offer, o.id == expectedID else { return DraftReduction(slot: slot, notify: false, memberFlip: nil) }
            s.text = o.text
            s.editGen += 1
            s.offer = nil

        case .dismissOffer(let expectedID):
            guard let o = s.offer, o.id == expectedID else { return DraftReduction(slot: slot, notify: false, memberFlip: nil) }
            s.offer = nil

        case .archivedOrDeleted:
            if s.isRecyclable {
                let empty = DraftSlot()
                return DraftReduction(slot: empty, notify: false, memberFlip: before ? false : nil)
            }
            notify = false
        }

        let after = s.hasDraft
        return DraftReduction(slot: s, notify: notify, memberFlip: after == before ? nil : after)
    }

    /// 结算后，撤回的横幅若输入框为空则自动回填。
    private static func settleWithdrawnOffer(_ s: inout DraftSlot) {
        guard let o = s.offer, o.kind == .withdrawn, WithdrawnDraft.isBlank(s.text) else { return }
        s.text = o.text
        s.offer = nil
    }
}
