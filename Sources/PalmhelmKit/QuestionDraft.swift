import Foundation

/// 提问卡的作答草稿（两端共用）：每题选项索引或自由文本，二选一；单选恰一项，多选至少一项。
/// 只做本地完整性检查，权威校验仍在 Bridge（越界、重复、不可选都会 400）。
public struct QuestionDraft: Sendable, Equatable {
    public private(set) var questions: [ProjectedQuestion]
    public private(set) var selected: [Set<Int>]
    public var texts: [String]

    public init(_ questions: [ProjectedQuestion]) {
        self.questions = questions
        selected = Array(repeating: [], count: questions.count)
        texts = Array(repeating: "", count: questions.count)
    }

    /// 点选项：单选替换、多选切换；不可选的选项忽略；选了选项就清掉这题的自由文本。
    public mutating func toggle(question q: Int, option o: Int) {
        guard questions.indices.contains(q), questions[q].options.indices.contains(o), questions[q].options[o].selectable else { return }
        if questions[q].multiSelect {
            if selected[q].contains(o) { selected[q].remove(o) } else { selected[q].insert(o) }
        } else {
            selected[q] = [o]
        }
        texts[q] = ""
    }

    /// 写自由文本时清掉这题的选项（一题只用一种作答方式）。
    public mutating func setText(question q: Int, _ text: String) {
        guard texts.indices.contains(q) else { return }
        texts[q] = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { selected[q] = [] }
    }

    public func isAnswered(_ q: Int) -> Bool {
        !texts[q].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selected[q].isEmpty
    }

    public var isComplete: Bool { questions.indices.allSatisfy(isAnswered) }

    /// 有自由文本超过上限时不提交（与拒绝原因同一上限）。
    public var tooLong: Bool { texts.contains(where: ApprovalMessage.isTooLong) }

    /// 组装成接口要的答案；不完整时为 nil。
    public var answers: [QuestionAnswer]? {
        guard isComplete, !tooLong else { return nil }
        return questions.indices.map { q in
            let t = texts[q].trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? .options(question: q, indexes: selected[q].sorted()) : .text(question: q, text: t)
        }
    }
}
