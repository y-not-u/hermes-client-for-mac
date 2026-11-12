import XCTest
@testable import HermesMac

/// Delta coalescing keeps a WebSocket burst from redrawing the transcript once per
/// frame. These tests pin the two things that must never regress: the buffered tail
/// has to reach `messages` on every boundary, and the text has to keep its order.
@MainActor final class StreamingCoalescingTests: XCTestCase {
    private func conversation() -> Conversation {
        Conversation(key: ConversationKey(service: "fixture", profile: "a", storedID: "stream"))
    }

    private func delta(_ c: Conversation, _ text: String) {
        c.apply(type: "message.delta", payload: .object(["text": .string(text)]), visible: true)
    }

    /// The first delta of a burst paints immediately; the ones that follow wait, so
    /// a burst of frames results in far fewer transcript writes.
    func testBurstBuffersWithoutAppendingUntilFlushed() {
        let c = conversation()
        delta(c, "一")
        XCTAssertEqual(c.messages.last?.text, "一", "the first delta should paint at once")
        delta(c, "二")
        delta(c, "三")
        XCTAssertEqual(c.messages.last?.text, "一", "later deltas stay buffered inside the commit interval")
        XCTAssertEqual(c.messages.count, 1, "buffering must not create extra messages")
        c.commitPendingStream()
        XCTAssertEqual(c.messages.last?.text, "一二三")
        XCTAssertEqual(c.messages.count, 1)
    }

    func testIgnoredEventsDoNotFlushBufferedDeltas() {
        let c = conversation()
        delta(c, "一")
        delta(c, "二")
        c.apply(type: "future.informational", payload: .object([:]), visible: true)
        XCTAssertEqual(c.messages.last?.text, "一")
        c.commitPendingStream()
        XCTAssertEqual(c.messages.last?.text, "一二")
    }

    /// Buffered text must not depend on a boundary event to become visible.
    func testBufferedDeltasFlushOnTheirOwn() async throws {
        let c = conversation()
        delta(c, "一")
        delta(c, "二")
        XCTAssertEqual(c.messages.last?.text, "一")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(c.messages.last?.text, "一二", "the scheduled flush should land without a boundary event")
    }

    /// A completion replaces the streamed text with the authoritative reply; the
    /// buffered tail has to be committed first so nothing is appended out of order.
    func testCompletionFlushesTailBeforeReplacingText() {
        let c = conversation()
        delta(c, "部分")
        delta(c, "回答")
        c.apply(type: "message.complete", payload: .object(["text": .string("部分回答。")]), visible: true)
        XCTAssertEqual(c.messages.last?.text, "部分回答。")
        XCTAssertEqual(c.messages.count, 1, "a flushed tail must not add a second assistant message")
        XCTAssertFalse(c.generating)
    }

    /// Tool frames are boundaries: buffered prose belongs above the tool activity
    /// that follows it, and text after the tool starts a new bubble.
    func testToolBoundaryKeepsTextAboveTheActivity() {
        let c = conversation()
        delta(c, "正在查找")
        delta(c, "资料")
        c.apply(type: "tool.start", payload: .object(["tool_id": .string("one"), "name": .string("search")]), visible: true)
        XCTAssertEqual(c.messages.last?.text, "正在查找资料")
        delta(c, "工具之后")
        c.commitPendingStream()
        XCTAssertEqual(c.messages.map(\.text), ["正在查找资料", "工具之后"], "text after a tool belongs in its own message")
        XCTAssertEqual(c.toolActivities.count, 1)
    }

    /// `message.interim` appends its own text, so the buffered delta must land first
    /// to keep the order the model produced.
    func testInterimEventKeepsDeltaOrder() {
        let c = conversation()
        delta(c, "第一段")
        delta(c, "第二段")
        c.apply(type: "message.interim", payload: .object(["text": .string("（交接）")]), visible: true)
        XCTAssertEqual(c.messages.last?.text, "第一段第二段（交接）")
    }

    /// Snapshotting (page loads, resume) must persist the buffered tail. A metadata-only
    /// resume keeps the visible transcript, so the flushed text has to be in it already.
    func testSnapshotFlushesBufferedText() {
        let c = conversation()
        delta(c, "已到达")
        delta(c, "但未提交")
        c.snapshot(.object(["session_id": .string("runtime"), "messages_omitted": .bool(true)]))
        XCTAssertEqual(c.messages.map(\.text), ["已到达但未提交"])
    }

    /// An error ends the burst; the text that already arrived must survive.
    func testErrorEventFlushesBufferedText() {
        let c = conversation()
        delta(c, "半句")
        delta(c, "话")
        c.apply(type: "error", payload: .object(["message": .string("连接中断")]), visible: true)
        XCTAssertEqual(c.messages.last?.text, "半句话")
        XCTAssertEqual(c.error, "连接中断")
        XCTAssertFalse(c.generating)
    }

    /// Leaving a session (`newSession`, session switch) must not drop the tail of the
    /// reply that was streaming.
    func testLeavingSessionFlushesBufferedText() throws {
        let name = "HermesStreaming-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStore(local: LocalState(defaults: defaults))
        store.connected = true; store.selectedProfile = "a"
        let key = ConversationKey(service: store.service, profile: "a", storedID: "first")
        let c = Conversation(key: key)
        store.conversations[key] = c
        store.selectedSession = key.storedID
        delta(c, "问到一半")
        delta(c, "的答案")
        store.newSession()
        XCTAssertEqual(c.messages.last?.text, "问到一半的答案")
    }
}
