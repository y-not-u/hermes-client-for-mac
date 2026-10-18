import XCTest
@testable import HermesMac

/// Regression coverage for the server→client `clarify` bridge: the agent blocks on this request,
/// so an unhandled frame would leave the turn waiting out the backend's deadline and the tool
/// would report the questions as undelivered.
@MainActor final class ClarifyTests: XCTestCase {
    private func frame(_ questions: [JSON], answers: JSON = .null) -> JSON {
        var params: [String: JSON] = ["session_id": .string("runtime"), "questions": .array(questions)]
        if answers != .null { params["answers"] = answers }
        return .object(["jsonrpc": .string("2.0"), "id": .string("srq-1"), "method": .string("clarify"),
                        "params": .object(params)])
    }
    private var singleChoice: JSON {
        .object(["qid": .string("q0"), "question": .string("Deploy to which env?"),
                 "choices": .array([.string("staging (Recommended)"), .string("prod")]),
                 "multi_select": .bool(false)])
    }
    private var multiChoice: JSON {
        .object(["qid": .string("q1"), "question": .string("Which targets?"),
                 "choices": .array([.string("api (Recommended)"), .string("web"), .string("worker")]),
                 "multi_select": .bool(true)])
    }
    private var openEnded: JSON {
        .object(["qid": .string("q2"), "question": .string("Anything else?"), "choices": .null,
                 "multi_select": .bool(false)])
    }

    func testDecodesQuestionsAndStripsRecommendedLabel() throws {
        let request = try XCTUnwrap(ClarifyRequest(frame([singleChoice, multiChoice, openEnded])))
        XCTAssertEqual(request.id, "srq-1")
        XCTAssertEqual(request.questions.map(\.qid), ["q0", "q1", "q2"])
        XCTAssertEqual(request.questions[0].choices.first, "staging (Recommended)")
        XCTAssertEqual(ClarifyQuestion.bare("staging (Recommended)"), "staging")
        XCTAssertTrue(request.questions[2].isOpenEnded)
        XCTAssertTrue(request.questions[1].multiSelect)
        // An open-ended question captures text without an extra tap.
        XCTAssertEqual(request.typingQID, "q2")
    }

    func testMalformedFramesAreRejected() {
        XCTAssertNil(ClarifyRequest(frame([])))
        XCTAssertNil(ClarifyRequest(.object(["id": .string("srq-1"), "params": .object(["questions": .array([])])])))
        XCTAssertNil(ClarifyRequest(.object(["params": .object(["questions": .array([singleChoice])])])))
    }

    func testSingleSelectSendsBareChoice() throws {
        var request = try XCTUnwrap(ClarifyRequest(frame([singleChoice, multiChoice, openEnded])))
        request.selectedChoices["q0"] = ["prod (Recommended)"]
        request.selectedChoices["q1"] = ["web", "api (Recommended)"]
        request.drafts["q2"] = "  请先备份  "
        let answers = request.result()
        XCTAssertEqual(answers["q0"], .string("prod"))
        // Multi-select answers travel as a JSON array string the server decodes itself.
        XCTAssertEqual(answers["q1"], .string("[\"web\",\"api\"]"))
        XCTAssertEqual(answers["q2"], .string("请先备份"))
        XCTAssertTrue(request.isComplete)
    }

    func testIncompleteRequestRequiresEveryQuestion() throws {
        var request = try XCTUnwrap(ClarifyRequest(frame([singleChoice, multiChoice, openEnded])))
        request.selectedChoices["q0"] = ["staging"]
        XCTAssertFalse(request.isComplete)
        // Locked set: questions still needing input, ignoring staged choices.
        XCTAssertEqual(request.unanswered.map(\.qid), ["q0", "q1", "q2"])
        XCTAssertEqual(request.result().keys.sorted(), ["q0"])
        // A blank draft never counts as an answer.
        request.drafts["q2"] = "   "
        XCTAssertNil(request.pendingAnswer("q2"))
    }

    func testLockedAnswersSurviveReplay() throws {
        let replay = try XCTUnwrap(ClarifyRequest(frame([singleChoice, multiChoice], answers: .object(["q0": .string("staging")]))))
        XCTAssertTrue(replay.isLocked("q0"))
        XCTAssertEqual(replay.unanswered.map(\.qid), ["q1"])
        XCTAssertEqual(replay.result()["q0"], .string("staging"))
    }

    func testConversationStoresClarifyAndRequestCancelMatchesById() {
        let c = Conversation(key: ConversationKey(service: "fixture", profile: "a", storedID: "stored"))
        c.begin("question")
        c.apply(type: "tool.start", payload: .object(["tool_id": .string("t1"), "name": .string("clarify")]), visible: true)
        let request = ClarifyRequest(frame([singleChoice]))!
        c.clarifyRequests.append(request)
        c.approvals.append(Approval(id: "approval-1", params: .object([:])))

        // Cancelling the clarify must leave an unrelated approval card alone.
        c.apply(type: "request.cancel", payload: .object(["id": .string("srq-1"), "method": .string("clarify")]), visible: true)
        XCTAssertTrue(c.clarifyRequests.isEmpty)
        XCTAssertEqual(c.approvals.map(\.id), ["approval-1"])

        c.apply(type: "request.cancel", payload: .object(["id": .string("approval-1")]), visible: true)
        XCTAssertTrue(c.approvals.isEmpty)
    }

    func testSnapshotRestoresPendingClarifyAndKeepsStagedAnswers() {
        let c = Conversation(key: ConversationKey(service: "fixture", profile: "a", storedID: "stored"))
        // Staged state is written in place the way the store does it (a var-to-var copy would
        // defeat the staging this test asserts on).
        c.clarifyRequests = [ClarifyRequest(frame([singleChoice, multiChoice, openEnded]))!]
        c.clarifyRequests[0].selectedChoices = ["q0": ["prod"]]
        c.clarifyRequests[0].drafts = ["q2": "先行备份"]
        c.snapshot(.object([
            "session_id": .string("runtime"), "running": .bool(true), "messages_omitted": .bool(true),
            "open_requests": .array([frame([singleChoice, multiChoice, openEnded])])
        ]))
        XCTAssertEqual(c.clarifyRequests.map(\.id), ["srq-1"])
        // The staged answer survives the replay; only empty state is rebuilt from scratch.
        XCTAssertEqual(c.clarifyRequests.first?.choices(for: "q0"), ["prod"])
        XCTAssertEqual(c.clarifyRequests.first?.drafts["q2"], "先行备份")
    }

    func testSnapshotWithoutReplayDropsAnsweredCard() {
        let c = Conversation(key: ConversationKey(service: "fixture", profile: "a", storedID: "stored"))
        c.clarifyRequests = [ClarifyRequest(frame([singleChoice]))!]
        c.submittingClarify.insert("srq-1")
        // The server no longer holds the request: it was answered or withdrawn elsewhere.
        c.snapshot(.object(["session_id": .string("runtime"), "running": .bool(true), "open_requests": .array([])]))
        XCTAssertTrue(c.clarifyRequests.isEmpty)
        XCTAssertTrue(c.submittingClarify.isEmpty)
    }

    func testMetadataOnlySnapshotKeepsClarifyCard() {
        let c = Conversation(key: ConversationKey(service: "fixture", profile: "a", storedID: "stored"))
        c.clarifyRequests = [ClarifyRequest(frame([singleChoice]))!]
        // A snapshot that omits `open_requests` is not authoritative about pending requests.
        c.snapshot(.object(["session_id": .string("runtime"), "running": .bool(true), "messages_omitted": .bool(true)]))
        XCTAssertEqual(c.clarifyRequests.map(\.id), ["srq-1"])
    }

    func testCompletionClearsPendingClarify() {
        let c = Conversation(key: ConversationKey(service: "fixture", profile: "a", storedID: "stored"))
        c.begin("question")
        c.clarifyRequests = [ClarifyRequest(frame([singleChoice]))!]
        c.apply(type: "message.complete", payload: .object(["text": .string("done")]), visible: true)
        XCTAssertTrue(c.clarifyRequests.isEmpty)
        XCTAssertEqual(c.messages.map(\.text), ["question", "done"])
    }
}
