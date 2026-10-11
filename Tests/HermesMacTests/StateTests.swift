import XCTest
@testable import HermesMac

@MainActor final class StateTests: XCTestCase {
    func testStreamingCompletionAndUnknownEvents() {
        let c = Conversation(key: ConversationKey(service: "local", profile: "a", storedID: "stored"))
        c.begin("question")
        c.apply(type: "message.delta", payload: .object(["text": .string("partial")]), visible: false)
        c.apply(type: "future.event", payload: .object(["anything": .array([.null])]), visible: false)
        XCTAssertEqual(c.messages.map(\.text), ["question", "partial"])
        c.apply(type: "message.complete", payload: .object(["text": .string("complete")]), visible: false)
        XCTAssertEqual(c.messages.map(\.text), ["question", "complete"])
        XCTAssertFalse(c.generating)
        XCTAssertTrue(c.unread)
    }

    func testDraftsAndSelectionPersistPerService() throws {
        let name = "HermesMacTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let local = LocalState(defaults: defaults)
        let key = LocalState.draftKey(profile: "a", session: "session")
        local.update("service-a") { $0.drafts[key] = "中文草稿"; $0.lastSession["a"] = "session"; $0.selectedProfile = "a" }
        local.update("service-b") { $0.drafts[key] = "other" }
        let restored = LocalState(defaults: defaults)
        XCTAssertEqual(restored.state("service-a").drafts[key], "中文草稿")
        XCTAssertEqual(restored.state("service-b").drafts[key], "other")
        XCTAssertEqual(restored.state("service-a").lastSession["a"], "session")
        XCTAssertNotEqual(key, LocalState.draftKey(profile: "b", session: "session"))
    }

    func testSnapshotRestoresInflightAndApproval() {
        let c = Conversation(key: ConversationKey(service: "local", profile: "a", storedID: "stored"))
        c.snapshot(.object([
            "session_id": .string("runtime"), "running": .bool(true),
            "messages": .array([.object(["role": .string("system"), "content": .string("hidden")])]),
            "inflight": .object(["user": .string("question"), "assistant": .string("partial")]),
            "open_requests": .array([.object(["id": .string("approval"), "method": .string("approval"), "params": .object([:])])])
        ]))
        XCTAssertEqual(c.runtimeID, "runtime")
        XCTAssertEqual(c.messages.map(\.text), ["question", "partial"])
        XCTAssertTrue(c.generating)
        XCTAssertEqual(c.approvals.map(\.id), ["approval"])
    }
    func testMetadataOnlySnapshotPreservesHistoryAndReplacesPartialStream() {
        let c = Conversation(key: ConversationKey(service: "local", profile: "a", storedID: "stored"))
        c.begin("question")
        c.appendStream("partial")
        c.snapshot(.object([
            "session_id": .string("runtime"), "messages_omitted": .bool(true), "running": .bool(true),
            "inflight": .object(["user": .string("question"), "assistant": .string("partial restored")])
        ]))
        XCTAssertEqual(c.messages.map(\.text), ["question", "partial restored"])
        c.snapshot(.object(["session_id": .string("runtime"), "messages_omitted": .bool(true)]))
        XCTAssertEqual(c.messages.map(\.text), ["question", "partial restored"])
        c.apply(type: "message.complete", payload: .object(["text": .string("partial restored")]), visible: true)
        XCTAssertEqual(c.messages.count, 2)
    }
}
