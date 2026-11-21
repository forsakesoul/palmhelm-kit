import Foundation
import Testing
@testable import PalmhelmKit

// 草稿槽状态机（规格 v5 §4、§10.1、§11.2）。只用合成正文。
@Suite struct DraftSlotTests {
    private let t1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let t2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func apply(_ slot: DraftSlot, _ events: [DraftEvent]) -> DraftSlot {
        events.reduce(slot) { DraftReducer.reduce($0, $1).slot }
    }

    @Test func missingSlotIsInitialState() {
        let s = DraftSlot()
        #expect(s.text == "" && s.editGen == 0 && s.inFlight == nil && s.offer == nil && s.note == nil)
        #expect(!s.hasDraft && s.isRecyclable)
    }

    // E1：编辑更新正文与 editGen，不推进 revision；hasDraft 翻转时给出成员变化。
    @Test func userEditDoesNotNotifyButFlipsMembership() {
        let r = DraftReducer.reduce(DraftSlot(), .userEdit("你好"))
        #expect(r.slot.text == "你好" && r.slot.editGen == 1)
        #expect(!r.notify)
        #expect(r.memberFlip == true)
        let r2 = DraftReducer.reduce(r.slot, .userEdit("   "))
        #expect(!r2.notify)
        #expect(r2.memberFlip == false, "纯空白不算草稿")
        #expect(r2.slot.text == "   ", "正文原样保留")
    }

    // E2：提交前冻结快照，清空输入框并推进 editGen，通知。
    @Test func submitAdmittedFreezesSnapshotAndClearsText() {
        let r = DraftReducer.reduce(apply(DraftSlot(), [.userEdit("A")]), .submitAdmitted(token: t1))
        #expect(r.notify)
        #expect(r.slot.text == "")
        #expect(r.slot.inFlight == DraftSubmission(snapshot: "A", editGenAtSubmit: 2, token: t1))
        #expect(r.slot.editGen == 2)
    }

    // E3：准入拒绝只写原因，不改正文。
    @Test func refusedSubmitKeepsTextAndWritesNote() {
        let s = apply(DraftSlot(), [.userEdit("A"), .submitRefused("未连接")])
        #expect(s.text == "A")
        #expect(s.inFlight == nil)
        #expect(s.note == .reason("未连接"))
    }

    // E5：accepted 清空在途，清掉 withdrawn 横幅，rejected 保留。
    @Test func acceptedClearsInFlightAndWithdrawnOffer() {
        let s = apply(DraftSlot(), [.userEdit("A"), .submitAdmitted(token: t1), .withdrawnOffer(text: "W", eventKey: "k1"), .outcome(token: t1, .accepted)])
        #expect(s.inFlight == nil)
        #expect(s.offer == nil)
        #expect(s.text == "", "accepted 不回填原文")
    }

    @Test func acceptedKeepsRejectedOffer() {
        var s = apply(DraftSlot(), [.userEdit("A"), .submitAdmitted(token: t1), .userEdit("B"), .outcome(token: t1, .rejected("拒绝"))])
        #expect(s.offer?.kind == .rejected)
        s = apply(s, [.submitAdmitted(token: t2), .outcome(token: t2, .accepted)])
        #expect(s.offer?.kind == .rejected, "accepted 只清 withdrawn，不清 rejected")
    }

    // E6：unknown 无论 id 是否存在都不回填、不自动重发，只写未知提示。
    @Test func unknownDoesNotRestoreAndNotesUnknown() {
        let s = apply(DraftSlot(), [.userEdit("A"), .submitAdmitted(token: t1), .outcome(token: t1, .unknown)])
        #expect(s.inFlight == nil)
        #expect(s.text == "")
        #expect(s.note == .unknownResult)
    }

    // E7：未编辑时拒绝 → 原文回填到输入框。
    @Test func rejectedWithoutEditRestoresSnapshot() {
        let s = apply(DraftSlot(), [.userEdit("A"), .submitAdmitted(token: t1), .outcome(token: t1, .rejected("拒绝"))])
        #expect(s.text == "A")
        #expect(s.inFlight == nil)
        #expect(s.offer == nil)
        #expect(s.note == .reason("拒绝"))
    }

    // E8：提交后用户已编辑（含删空）→ 原文作为 rejected offer，不覆盖正文。
    @Test func rejectedAfterEditBecomesOfferNotOverwrite() {
        let s = apply(DraftSlot(), [.userEdit("A"), .submitAdmitted(token: t1), .userEdit("B"), .outcome(token: t1, .rejected("拒绝"))])
        #expect(s.text == "B")
        #expect(s.offer == DraftOffer(id: t1.uuidString, text: "A", kind: .rejected))
    }

    // 反例（§10.1）：E2 → 系统清空（无用户编辑）→ rejected ⇒ E7（回填原文）。
    @Test func systemClearWithoutUserEditStillRestores() {
        let s = apply(DraftSlot(), [.userEdit("A"), .submitAdmitted(token: t1), .outcome(token: t1, .rejected("x"))])
        #expect(s.text == "A")
    }

    // 反例：E2 → B 删空 → rejected ⇒ 空稿 + rejected 横幅，且横幅仍在。
    @Test func deleteAfterSubmitThenRejectedShowsEmptyDraftWithOffer() {
        let s = apply(DraftSlot(), [.userEdit("A"), .submitAdmitted(token: t1), .userEdit(""), .outcome(token: t1, .rejected("x"))])
        #expect(s.text == "")
        #expect(s.offer?.kind == .rejected)
        #expect(!s.hasDraft)
    }

    // 反例：在途时 withdrawn 到达 → 结算后按 E10s：空稿自动回填。
    @Test func withdrawnDuringInFlightSettlesIntoEmptyDraft() {
        var s = apply(DraftSlot(), [.userEdit("A"), .submitAdmitted(token: t1), .withdrawnOffer(text: "W", eventKey: "k1")])
        #expect(s.offer == DraftOffer(id: "k1", text: "W", kind: .withdrawn), "在途时只挂 offer")
        s = DraftReducer.reduce(s, .outcome(token: t1, .unknown)).slot
        #expect(s.text == "W", "E6 后 withdrawn + 空稿：自动回填")
        #expect(s.offer == nil)
    }

    // E10：空稿（非在途、无 offer）收到撤回原文 → 直接回填，editGen 不变。
    @Test func withdrawnFillsRealEmptyDraftWithoutEditGenBump() {
        let r = DraftReducer.reduce(DraftSlot(), .withdrawnOffer(text: "W", eventKey: "k1"))
        #expect(r.slot.text == "W")
        #expect(r.slot.editGen == 0)
        #expect(r.notify)
    }

    // 11.2 E10 表驱动：① rejected 保留，丢弃 W
    @Test func withdrawnNeverOverwritesRejectedOffer() {
        let s = apply(DraftSlot(), [.userEdit("A"), .submitAdmitted(token: t1), .userEdit("B"), .outcome(token: t1, .rejected("x")), .userEdit(""), .withdrawnOffer(text: "W", eventKey: "k1")])
        #expect(s.offer?.kind == .rejected)
        #expect(s.text == "")
    }

    // 11.2 E10 表驱动：② 纯空白稿收到 W → 自动回填
    @Test func withdrawnFillsWhitespaceDraft() {
        let s = apply(DraftSlot(), [.userEdit("   "), .withdrawnOffer(text: "W", eventKey: "k1")])
        #expect(s.text == "W")
        #expect(s.offer == nil)
    }

    // 11.2 E10 表驱动：B + withdrawn → 删空 → 横幅仍在；随后 W2 覆盖 W。
    @Test func withdrawnOfferSurvivesDeleteAndIsReplacedByNewer() {
        var s = apply(DraftSlot(), [.userEdit("B"), .withdrawnOffer(text: "W", eventKey: "k1")])
        #expect(s.offer?.kind == .withdrawn)
        s = apply(s, [.userEdit("")])
        #expect(s.offer != nil, "删空不触发自动回填，横幅仍可选")
        s = apply(s, [.withdrawnOffer(text: "W2", eventKey: "k2")])
        #expect(s.offer == DraftOffer(id: "k2", text: "W2", kind: .withdrawn))
    }

    // E9：outcome token 不符 / 无在途 → no-op，不通知。
    @Test func staleOrDuplicateOutcomeIsNoOp() {
        let base = apply(DraftSlot(), [.userEdit("A"), .submitAdmitted(token: t1)])
        let wrong = DraftReducer.reduce(base, .outcome(token: t2, .rejected("x")))
        #expect(wrong.slot == base && !wrong.notify)
        let done = DraftReducer.reduce(apply(base, [.outcome(token: t1, .accepted)]), .outcome(token: t1, .rejected("x")))
        #expect(!done.notify && done.slot.text == "")
    }

    // E11 / E12：expectedID 不符 → no-op；相符 → 替换（editGen+1）或忽略。
    @Test func offerActionsRequireMatchingID() {
        let base = apply(DraftSlot(), [.userEdit("B"), .withdrawnOffer(text: "W", eventKey: "k1")])
        let noop = DraftReducer.reduce(base, .replaceOffer(expectedID: "other"))
        #expect(noop.slot == base && !noop.notify)
        let replaced = DraftReducer.reduce(base, .replaceOffer(expectedID: "k1"))
        #expect(replaced.slot.text == "W" && replaced.slot.editGen == base.editGen + 1 && replaced.slot.offer == nil)
        #expect(replaced.notify)
        let dismissed = DraftReducer.reduce(base, .dismissOffer(expectedID: "k1"))
        #expect(dismissed.slot.offer == nil && dismissed.slot.text == "B")
    }

    // E14：归档/删除成功时，只有完全无内容的槽才回收；有正文、在途或 offer 时保留。
    @Test func archivedRecyclesOnlyEmptySlots() {
        let empty = DraftReducer.reduce(DraftSlot(note: .reason("x")), .archivedOrDeleted)
        #expect(empty.slot.note == .reason("x"), "有提示的槽不应静默回收")
        let kept = DraftReducer.reduce(apply(DraftSlot(), [.userEdit("A")]), .archivedOrDeleted)
        #expect(kept.slot.text == "A")
        let blank = DraftReducer.reduce(apply(DraftSlot(), [.userEdit("   ")]), .archivedOrDeleted)
        #expect(blank.slot.text == "   ", "纯空白但非精确空串：不回收，正文保留")
        let recycled = DraftReducer.reduce(apply(DraftSlot(), [.userEdit("A"), .userEdit("")]), .archivedOrDeleted)
        #expect(recycled.slot == DraftSlot())
        #expect(recycled.memberFlip == nil, "本身无草稿，不翻转成员")
    }

    // 不变量 I6：键入不推进 revision。
    @Test func everyUserEditIsSilentForRevision() {
        var s = DraftSlot()
        for ch in ["a", "ab", "abc"] {
            let r = DraftReducer.reduce(s, .userEdit(ch))
            #expect(!r.notify)
            s = r.slot
        }
    }
}
