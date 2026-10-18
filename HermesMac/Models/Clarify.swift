import Foundation

/// One question of a server→client `clarify` request (`tui_gateway/contracts/server_requests.py`).
/// The wire carries `qid`, text, optional choices and a multi-select flag; answers are keyed by `qid`.
struct ClarifyQuestion: Identifiable, Equatable {
    /// Suffix the server appends to the first (best) choice. Presentation only: an answer must be
    /// sent back without it, matching `tools/clarify_tool.py::strip_recommended`.
    static let recommendedLabel = "(Recommended)"
    /// The server caps a call at 5 questions and 4 offered choices per question.
    static let maxQuestions = 5

    let qid: String
    let question: String
    let choices: [String]
    let multiSelect: Bool

    var id: String { qid }
    var isOpenEnded: Bool { choices.isEmpty }

    init(_ json: JSON) {
        qid = json["qid"].string
        question = json["question"].string
        choices = json["choices"].array.map(\.string).filter { !$0.isEmpty }
        multiSelect = json["multi_select"].bool
    }

    init(qid: String, question: String, choices: [String] = [], multiSelect: Bool = false) {
        self.qid = qid; self.question = question; self.choices = choices; self.multiSelect = multiSelect
    }

    static func decode(_ json: JSON) -> [ClarifyQuestion] {
        json.array.map(ClarifyQuestion.init).filter { !$0.qid.isEmpty && !$0.question.isEmpty }
    }

    /// Choice label without the presentation suffix, for display and for the answer value.
    static func bare(_ choice: String) -> String {
        let trimmed = choice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasSuffix(recommendedLabel.lowercased()) else { return trimmed }
        return String(trimmed.dropLast(recommendedLabel.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The value sent for `selected`: a multi-select question answers with a JSON array string, which
    /// `tools/clarify_tool.py::_clean_answer` decodes server-side.
    func answer(for selected: [String]) -> String {
        let bare = selected.map(ClarifyQuestion.bare)
        guard multiSelect else { return bare.first ?? "" }
        guard let data = try? JSONEncoder().encode(bare) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One live `clarify` server request. The answer frame is `{answers: {qid: string|null}}`; an
/// empty result means "cancel all", and a `null` answer means "skipped".
struct ClarifyRequest: Identifiable, Equatable {
    let id: String
    let questions: [ClarifyQuestion]
    /// Answers the server already locked (`open_requests` replay carries them back).
    var lockedAnswers: [String: String] = [:]
    /// The question currently accepting free text (an open-ended question, or "Other" picked).
    var typingQID: String?
    var drafts: [String: String] = [:]
    var selectedChoices: [String: [String]] = [:]

    init(id: String, questions: [ClarifyQuestion]) {
        self.id = id
        self.questions = questions
        typingQID = questions.first(where: \.isOpenEnded)?.qid
    }

    init?(_ frame: JSON) {
        let id = frame["id"].string
        let questions = ClarifyQuestion.decode(frame["params"]["questions"])
        guard !id.isEmpty, !questions.isEmpty else { return nil }
        self.init(id: id, questions: questions)
        if case .object(let locked) = frame["params"]["answers"] {
            for (qid, value) in locked {
                if case .string(let answer) = value, !answer.isEmpty { lockedAnswers[qid] = answer }
            }
        }
    }

    /// Questions the server has not locked yet (an answer the user only staged still counts here).
    var unanswered: [ClarifyQuestion] { questions.filter { lockedAnswers[$0.qid] == nil } }

    /// Complete when every question has an answer, either locked by the server or staged here.
    /// Staged answers count: the card's submit button must enable as soon as the user has answered
    /// every question, without waiting for the server to lock each one.
    var isComplete: Bool {
        for question in questions where lockedAnswers[question.qid] == nil {
            guard let answer = pendingAnswer(question.qid), !answer.isEmpty else { return false }
        }
        return true
    }

    /// A copy of this request with `other`'s staged (unsent) answers applied. A reconnect replay
    /// re-delivers the request without them, and the user should not lose what they already picked.
    func mergingStaged(_ other: ClarifyRequest) -> ClarifyRequest {
        var merged = self
        merged.drafts = drafts.merging(other.drafts) { _, staged in staged }
        merged.selectedChoices = selectedChoices.merging(other.selectedChoices) { _, staged in staged }
        if other.typingQID != nil { merged.typingQID = other.typingQID }
        return merged
    }

    /// Choices staged for `qid` (empty when nothing is picked).
    func choices(for qid: String) -> [String] {
        selectedChoices[qid] ?? []
    }

    func isLocked(_ qid: String) -> Bool {
        lockedAnswers[qid] != nil
    }

    /// Pick a choice, replacing a single-select answer and toggling a multi-select one.
    mutating func select(_ choice: String, for qid: String) {
        guard let question = questions.first(where: { $0.qid == qid }), question.choices.contains(choice) else { return }
        drafts[qid] = nil
        typingQID = nil
        if question.multiSelect {
            var picked = selectedChoices[qid] ?? []
            if let position = picked.firstIndex(of: choice) { picked.remove(at: position) } else { picked.append(choice) }
            selectedChoices[qid] = picked
        } else {
            selectedChoices[qid] = [choice]
        }
    }

    /// The answer currently staged for `qid`, or nil while it still needs input. Free text wins
    /// over a picked choice, mirroring the server's "Other" text-capture mode.
    func pendingAnswer(_ qid: String) -> String? {
        if let text = drafts[qid]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        guard let question = questions.first(where: { $0.qid == qid }) else { return nil }
        let picked = selectedChoices[qid] ?? []
        guard !picked.isEmpty else { return nil }
        return question.answer(for: picked)
    }

    /// `{qid: answer}` for every question that has one; locked answers are carried back untouched.
    func result() -> [String: JSON] {
        var answers: [String: JSON] = [:]
        for question in questions {
            if let locked = lockedAnswers[question.qid] { answers[question.qid] = .string(locked); continue }
            guard let answer = pendingAnswer(question.qid), !answer.isEmpty else { continue }
            answers[question.qid] = .string(answer)
        }
        return answers
    }
}
