import XCTest
import Security
@testable import HermesMac

private final class StartupOfflineProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var remainingFailures = 0
    static func failNextRequest() {
        lock.lock(); defer { lock.unlock() }
        remainingFailures = 1
    }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return remainingFailures > 0 && request.url?.path == "/api/status"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.remainingFailures -= 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@MainActor final class IntegrationTests: XCTestCase {
    private var address: String { ProcessInfo.processInfo.environment["HERMES_TEST_SERVER"] ?? "" }
    private func fixture(_ body: [String: JSON]) async throws -> JSON {
        var request = URLRequest(url: try XCTUnwrap(URL(string: address + "/__test")))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(JSON.object(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(JSON.self, from: data)
    }
    private func prepare() async throws -> (AppStore, HermesClient, UserDefaults, String) {
        guard !address.isEmpty else { throw XCTSkip("Run script/test.sh to enable real URLSession protocol integration tests") }
        _ = try await fixture(["action": .string("reset")])
        let name = "HermesMacTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let local = LocalState(defaults: defaults)
        local.address = address
        let client = try HermesClient(address: address, credentials: Credentials(sessionToken: "fixture-token"))
        let store = AppStore(local: local, makeClient: { requested in
            if requested == client.service { return client }
            return try HermesClient(address: requested, credentials: Credentials(sessionToken: "fixture-token"))
        })
        await store.connect()
        XCTAssertTrue(store.connected, store.error ?? "failed connection")
        return (store, client, defaults, name)
    }
    private func eventually(timeout: Double = 6, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(predicate(), "Timed out waiting for protocol state")
    }
    private func emit(_ stored: String, type: String, text: String = "") async throws {
        _ = try await fixture(["action": .string("emit"), "stored_id": .string(stored), "frame": .object([
            "method": .string("event"), "params": .object(["type": .string(type), "payload": .object(["text": .string(text)])])
        ])])
    }

    func testArchiveRemovesCurrentSessionAndPreservesDraft() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "archive me"; await store.send()
        let c = try XCTUnwrap(store.current)
        let row = try XCTUnwrap(store.sessions["a"]?.first { $0.id == c.key.storedID })
        XCTAssertFalse(store.canRemoveSession(row.id, profile: "a"))
        try await emit(row.id, type: "message.complete", text: "done")
        try await eventually { !c.generating }
        store.draft = "saved draft"
        await store.removeSession(row, archive: true, profile: "a", service: client.service)
        XCTAssertNil(store.selectedSession)
        XCTAssertNil(store.conversations[c.key])
        XCTAssertNil(store.local.state(client.service).lastSession["a"])
        XCTAssertEqual(store.local.state(client.service).drafts[LocalState.draftKey(profile: "a", session: row.id)], "saved draft")
        await store.loadSessions(profile: "a", query: row.id)
        XCTAssertFalse(store.sessions["a", default: []].contains { $0.id == row.id })
        let stats = try await fixture(["action": .string("stats")])
        let write = try XCTUnwrap(stats["session_writes"].array.last)
        XCTAssertEqual(write["method"].string, "PATCH")
        XCTAssertEqual(write["profile"].string, "a")
        XCTAssertTrue(write["body"]["archived"].bool)
    }

    func testDeleteUsesOriginalProfileAndClearsOnlyItsDraft() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        let row = SessionSummary(id: "same-id", title: "delete me")
        _ = try await fixture(["action": .string("configure"), "session_rows": .array([
            .object(["id": .string(row.id), "title": .string(row.title), "profile": .string("a")]),
            .object(["id": .string(row.id), "title": .string(row.title), "profile": .string("b")])
        ])])
        await store.loadSessions(profile: "a")
        store.local.update(client.service) {
            $0.lastSession["a"] = row.id
            $0.drafts[LocalState.draftKey(profile: "a", session: row.id)] = "remove"
            $0.drafts[LocalState.draftKey(profile: "b", session: row.id)] = "keep"
        }
        await store.selectProfile("b")
        store.draft = "current draft"
        await store.removeSession(row, archive: false, profile: "a", service: client.service)
        XCTAssertEqual(store.selectedProfile, "b")
        XCTAssertEqual(store.draft, "current draft")
        XCTAssertFalse(store.sessions["a", default: []].contains { $0.id == row.id })
        XCTAssertTrue(store.sessions["b", default: []].contains { $0.id == row.id })
        XCTAssertNil(store.local.state(client.service).drafts[LocalState.draftKey(profile: "a", session: row.id)])
        XCTAssertEqual(store.local.state(client.service).drafts[LocalState.draftKey(profile: "b", session: row.id)], "keep")
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["session_writes"].array.last?["method"].string, "DELETE")
        XCTAssertEqual(stats["session_writes"].array.last?["profile"].string, "a")
    }

    func testFailedSessionRemovalPreservesListAndSelection() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        await store.openSession("cli-readonly")
        store.draft = "keep draft"
        let row = try XCTUnwrap(store.sessions["a"]?.first { $0.id == "cli-readonly" })
        await store.removeSession(row, archive: false, profile: "a", service: "http://other-service")
        var stats = try await fixture(["action": .string("stats")])
        XCTAssertTrue(stats["session_writes"].array.isEmpty)
        _ = try await fixture(["action": .string("configure"), "session_write_error": .bool(true)])
        for archive in [true, false] {
            await store.removeSession(row, archive: archive, profile: "a", service: client.service)
            XCTAssertEqual(store.selectedSession, row.id)
            XCTAssertEqual(store.draft, "keep draft")
            XCTAssertTrue(store.sessions["a", default: []].contains { $0.id == row.id })
            XCTAssertNotNil(store.error)
            XCTAssertTrue(store.canRemoveSession(row.id, profile: "a"))
        }
        stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["session_writes"].array.count, 2)
    }

    func testRedirectPreservesPartialReplyAndContinuesBelowCorrection() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "original"; await store.send()
        let c = try XCTUnwrap(store.current)
        try await emit(c.key.storedID, type: "message.delta", text: "partial before")
        try await eventually { c.messages.last?.text == "partial before" }
        store.draft = "change direction"
        XCTAssertTrue(store.canSend)
        await store.send()
        XCTAssertTrue(c.generating)
        XCTAssertEqual(store.draft, "")
        XCTAssertEqual(c.messages.last?.deliveryStatus, "已提交改向")
        try await emit(c.key.storedID, type: "message.delta", text: "new answer")
        try await emit(c.key.storedID, type: "message.complete", text: "corrected answer")
        try await eventually { !c.generating }
        XCTAssertEqual(c.messages.map(\.text), ["original", "partial before", "change direction", "corrected answer"])
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["requests"].array.filter { $0["method"].string == "prompt.submit" }.count, 1)
    }

    func testUnsupportedRedirectFallsBackToSteer() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "original"; await store.send()
        _ = try await fixture(["action": .string("configure"), "correction_error": .number(4010)])
        store.draft = "guidance"; await store.send()
        XCTAssertEqual(store.current?.messages.last?.deliveryStatus, "已提交引导，等待执行边界")
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["requests"].array.suffix(2).map { $0["method"].string }, ["session.redirect", "session.steer"])
        XCTAssertFalse(store.current?.uncertain == true)
    }

    func testQueueKeepsActiveReplyAndForcesBackendQueue() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "original"; await store.send()
        let c = try XCTUnwrap(store.current)
        try await emit(c.key.storedID, type: "message.delta", text: "partial")
        try await eventually { c.messages.last?.text == "partial" }
        store.draft = "next turn"; await store.send(queue: true)
        try await emit(c.key.storedID, type: "message.complete", text: "original answer")
        try await eventually { !c.generating }
        XCTAssertEqual(c.messages.map(\.text), ["original", "original answer", "next turn"])
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["requests"].array.last?["params"]["queued"], .bool(true))
        XCTAssertFalse(stats["requests"].array.contains { $0["method"].string == "session.redirect" })
    }

    func testCorrectionAtCompletionBecomesSingleNextTurn() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "original"; await store.send()
        _ = try await fixture(["action": .string("configure"), "complete_on_correction": .bool(true)])
        store.draft = "follow up"; await store.send()
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["requests"].array.filter { $0["method"].string == "prompt.submit" }.count, 2)
        XCTAssertEqual(store.current?.messages.filter { $0.text == "follow up" }.count, 1)
        XCTAssertEqual(store.current?.messages.first { $0.text == "follow up" }?.deliveryStatus, "已提交下一轮")
    }

    func testCorrectionRefusalRestoresDraftWithoutRetry() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "original"; await store.send()
        _ = try await fixture(["action": .string("configure"), "correction_error": .number(4004)])
        store.draft = "retry manually"; await store.send()
        XCTAssertEqual(store.draft, "retry manually")
        XCTAssertEqual(store.current?.messages.last?.deliveryStatus, "提交失败")
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["requests"].array.last?["method"].string, "session.redirect")
    }

    func testCorrectionDisconnectDoesNotResubmit() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "original"; await store.send()
        let c = try XCTUnwrap(store.current)
        _ = try await fixture(["action": .string("configure"), "drop_on_correction": .bool(true)])
        store.draft = "unknown"; await store.send()
        XCTAssertTrue(c.uncertain)
        XCTAssertEqual(c.messages.last?.deliveryStatus, "提交结果未知")
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["requests"].array.filter { $0["method"].string == "prompt.submit" }.count, 1)
        XCTAssertFalse(stats["requests"].array.contains { $0["method"].string == "session.steer" })
    }

    func testCorrectionStaysWithOriginalConversationAfterNavigation() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "original"; await store.send()
        let c = try XCTUnwrap(store.current)
        _ = try await fixture(["action": .string("configure"), "correction_delay": .number(0.2)])
        store.draft = "correction"
        let sending = Task { await store.send() }
        try await eventually { c.messages.last?.text == "correction" }
        await store.selectProfile("b"); store.draft = "unsent B"
        await sending.value
        XCTAssertEqual(store.draft, "unsent B")
        XCTAssertEqual(c.messages.last?.deliveryStatus, "已提交改向")
        await store.selectProfile("a")
        store.newSession(); store.draft = "another session"
        XCTAssertFalse(store.canSend)
    }

    func testSessionListAndSearchExcludeCronBeforePagination() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        var rows: [JSON] = (0..<45).flatMap { index in
            [JSON.object(["id": .string("cron-\(index)"), "title": .string("match scheduled run"), "source": .string("cron"), "profile": .string("a")]),
             JSON.object(["id": .string("chat-\(index)"), "title": .string("match cron discussion"), "source": .string("cli"), "profile": .string("a")])]
        }
        rows.append(.object(["id": .string("other-profile"), "title": .string("match other"), "source": .string("cli"), "profile": .string("b")]))
        _ = try await fixture(["action": .string("configure"), "session_rows": .array(rows)])

        await store.loadSessions(profile: "a")
        XCTAssertEqual(store.sessions["a"]?.map(\.id), (0..<40).map { "chat-\($0)" })
        XCTAssertEqual(store.listHasMore["a"], true)
        await store.loadSessions(profile: "a", more: true)
        XCTAssertEqual(store.sessions["a"]?.map(\.id), (0..<45).map { "chat-\($0)" } + ["cli-readonly"])
        XCTAssertEqual(store.listHasMore["a"], false)

        await store.loadSessions(profile: "a", query: "match")
        XCTAssertEqual(store.sessions["a"]?.map(\.id), (0..<40).map { "chat-\($0)" })
        let stats = try await fixture(["action": .string("stats")])
        let reads = stats["session_reads"].array
        XCTAssertTrue(reads.allSatisfy { $0["exclude_sources"].string == "cron" })
        XCTAssertEqual(reads.dropLast().last?["offset"].string, "40")
        XCTAssertEqual(reads.last?["path"].string, "/api/sessions/search")
    }

    func testColdStartAutomaticallyRetriesAndRestoresSavedNativeLogin() async throws {
        guard !address.isEmpty else { throw XCTSkip("Run script/test.sh to enable protocol integration tests") }
        _ = try await fixture(["action": .string("reset")])
        _ = try await fixture(["action": .string("configure"), "native": .bool(true)])
        let name = "HermesMacStartupTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let local = LocalState(defaults: defaults); local.address = address
        local.update(address) { $0.selectedProfile = "b"; $0.drafts[LocalState.draftKey(profile: "b", session: nil)] = "saved draft" }
        try Keychain.save(Credentials(accessToken: "fresh-token", refreshToken: "refresh-token", provider: "fixture", expiresAt: 9999999999), service: address)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StartupOfflineProtocol.self]
        StartupOfflineProtocol.failNextRequest()
        let client = try HermesClient(address: address, session: URLSession(configuration: config))
        let store = AppStore(local: local, makeClient: { _ in client })
        defer {
            client.disconnect(); defaults.removePersistentDomain(forName: name)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.hermes.mac.credentials", kSecAttrAccount as String: address] as CFDictionary)
        }
        await store.connect()
        XCTAssertFalse(store.connected)
        XCTAssertTrue(store.connecting)
        XCTAssertEqual(store.connection, "等待自动重连…")
        try await eventually { store.connected && store.selectedProfile == "b" }
        XCTAssertEqual(store.draft, "saved draft")
        XCTAssertNil(store.error)
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["refreshes"].number, 0)
        XCTAssertEqual(stats["tickets"].number, 1)
    }

    func testConcurrentProfilesApprovalUnreadAndDraftIsolation() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "A question"
        await store.send()
        let a = try XCTUnwrap(store.current)
        XCTAssertTrue(a.generating)
        store.draft = "A draft"
        await store.selectProfile("b")
        store.draft = "B question"
        await store.send()
        let b = try XCTUnwrap(store.current)
        store.draft = "B draft"
        try await emit(a.key.storedID, type: "message.delta", text: "A partial")
        try await emit(b.key.storedID, type: "future.event", text: "ignored")
        _ = try await fixture(["action": .string("emit"), "stored_id": .string(a.key.storedID), "frame": .object([
            "id": .string("approval-a"), "method": .string("approval"), "params": .object([
                "command": .string("echo A"), "choices": .array([.string("once"), .string("deny")])])
        ])])
        try await eventually { store.profileApproval("a") }
        XCTAssertFalse(store.profileApproval("b"))
        XCTAssertEqual(store.current?.key, b.key)
        XCTAssertEqual(a.messages.last?.text, "A partial")
        await store.selectProfile("a")
        XCTAssertEqual(store.draft, "A draft")
        let approval = try XCTUnwrap(a.approvals.first)
        await store.approve(approval, conversation: a, choice: "deny")
        await store.selectProfile("b")
        XCTAssertEqual(store.draft, "B draft")
        try await emit(a.key.storedID, type: "message.complete", text: "A complete")
        try await eventually { store.profileUnread("a") }
        XCTAssertTrue(b.generating)
        XCTAssertFalse(store.profileUnread("b"))
        await store.selectProfile("a")
        XCTAssertFalse(store.profileUnread("a"))
        XCTAssertEqual(a.messages.map(\.text), ["A question", "A complete"])
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["responses"].array.first?["result"]["choice"].string, "deny")
        XCTAssertEqual(stats["requests"].array.filter { $0["method"].string == "prompt.submit" }.count, 2)
    }

    func testApprovalUsesQueueIdentityAndRequiresConfirmation() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "question"
        await store.send()
        let conversation = try XCTUnwrap(store.current)
        for choice in ["once", "session", "deny"] {
            let approval = Approval(id: "srq-\(choice)", params: .object([
                "request_id": .string("queue-\(choice)"),
                "choices": .array([.string(choice)])
            ]))
            conversation.approvals.append(approval)
            await store.approve(approval, conversation: conversation, choice: choice)
            XCTAssertTrue(conversation.approvals.isEmpty)
            XCTAssertTrue(conversation.submittingApprovals.isEmpty)
            XCTAssertNil(conversation.approvalErrors[approval.id])
        }
        let expired = Approval(id: "srq-expired", params: .object([
            "request_id": .string("expired"), "choices": .array([.string("once")])
        ]))
        conversation.approvals.append(expired)
        await store.approve(expired, conversation: conversation, choice: "once")
        XCTAssertEqual(conversation.approvals.map(\.id), [expired.id])
        XCTAssertNotNil(conversation.approvalErrors[expired.id])
        XCTAssertTrue(conversation.submittingApprovals.isEmpty)
        let stats = try await fixture(["action": .string("stats")])
        let calls = stats["requests"].array.filter { $0["method"].string == "approval.respond" }
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.first?["params"]["request_id"].string, "queue-once")
        XCTAssertEqual(calls.first?["params"]["session_id"].string, conversation.runtimeID)
        XCTAssertTrue(stats["responses"].array.isEmpty)
    }

    func testLateCreateResponseRemainsOwnedByOriginalProfile() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        _ = try await fixture(["action": .string("configure"), "create_delay": .number(0.25)])
        store.draft = "delayed A"
        let sending = Task { await store.send() }
        try await eventually { store.profileBusy("a") }
        await store.selectProfile("b")
        store.draft = "unsent B"
        await sending.value
        XCTAssertEqual(store.selectedProfile, "b")
        XCTAssertNil(store.current)
        XCTAssertEqual(store.draft, "unsent B")
        let a = try XCTUnwrap(store.conversations.values.first { $0.key.profile == "a" })
        XCTAssertEqual(a.messages.first?.text, "delayed A")
        await store.selectProfile("a")
        XCTAssertEqual(store.current?.key, a.key)
        XCTAssertEqual(store.draft, "")
    }

    func testCLIHistoryFallsBackToReadOnly() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        await store.openSession("cli-readonly")
        let c = try XCTUnwrap(store.current)
        XCTAssertNotNil(c.readOnlyReason)
        XCTAssertNil(c.runtimeID)
        XCTAssertEqual(c.messages.map(\.text), ["CLI question", "CLI answer"])
        store.draft = "cannot send"
        XCTAssertFalse(store.canSend)
    }

    func testLargeToolHistoryUsesBoundedHTTPPagesAndMetadataOnlyResume() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        _ = try await fixture(["action": .string("configure"), "large_history": .bool(true)])
        await store.openSession("large-history")
        let c = try XCTUnwrap(store.current)
        XCTAssertTrue(store.connected)
        XCTAssertNotNil(c.runtimeID)
        XCTAssertNil(c.readOnlyReason)
        XCTAssertEqual(c.historyOffset, 20)
        XCTAssertTrue(c.hasOlder)
        XCTAssertTrue(c.messages.allSatisfy { $0.role == "user" || $0.role == "assistant" })
        XCTAssertEqual(c.messages.first?.text, "message-46")
        XCTAssertEqual(c.messages.last?.text, "message-64")
        for _ in 0..<3 { await store.loadOlder(c) }
        XCTAssertEqual(c.historyOffset, 66)
        XCTAssertFalse(c.hasOlder)
        XCTAssertEqual(c.messages.count, 43)
        XCTAssertEqual(Set(c.messages.map(\.id)).count, c.messages.count)
        XCTAssertFalse(c.messages.contains { $0.role == "tool" })
        await store.connect()
        XCTAssertTrue(store.connected)
        XCTAssertNil(c.readOnlyReason)
        let stats = try await fixture(["action": .string("stats")])
        let resumes = stats["requests"].array.filter { $0["method"].string == "session.resume" }
        XCTAssertFalse(resumes.isEmpty)
        XCTAssertTrue(resumes.allSatisfy { $0["params"]["omit_messages"].bool })
        XCTAssertTrue(stats["history_reads"].array.allSatisfy {
            $0["limit"].string == "20" && $0["order"].string == "latest" && $0["inline_images"].string == "false"
        })
    }

    func testStatusQueryConfirmsUserBeyondLatestToolPage() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "confirmed before tool records"; await store.send()
        let c = try XCTUnwrap(store.current)
        try await emit(c.key.storedID, type: "message.complete", text: "done")
        try await eventually { !c.generating }
        _ = try await fixture(["action": .string("append_tools"), "stored_id": .string(c.key.storedID), "count": .number(25)])
        _ = try await fixture(["action": .string("configure"), "resume_delay": .number(0.2)])
        c.uncertain = true
        let querying = Task { await store.retryResume() }
        try await eventually { c.queryingStatus }
        await store.retryResume()
        await querying.value
        XCTAssertFalse(c.queryingStatus)
        XCTAssertFalse(c.uncertain)
        XCTAssertNil(c.statusQueryResult)
        XCTAssertTrue(c.messages.contains { $0.text == "confirmed before tool records" })
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["requests"].array.filter { $0["method"].string == "session.resume" }.count, 1)
        XCTAssertEqual(stats["requests"].array.filter { $0["method"].string == "prompt.submit" }.count, 1)
        XCTAssertEqual(stats["history_reads"].array.map { $0["offset"].string }, ["0", "20"])
    }

    func testUnconfirmedIdleMessageCanBeRecoveredWithoutResending() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "original"; await store.send()
        let c = try XCTUnwrap(store.current)
        try await emit(c.key.storedID, type: "message.complete", text: "done")
        try await eventually { !c.generating }
        c.begin("unconfirmed message"); c.uncertain = true
        store.draft = "existing draft"
        await store.retryResume()
        XCTAssertTrue(c.uncertain)
        XCTAssertNotNil(c.statusQueryResult)
        XCTAssertNotNil(c.recoverableMessageID)
        XCTAssertFalse(store.canSend)
        store.recoverUnconfirmedMessage()
        XCTAssertEqual(store.draft, "existing draft\n\nunconfirmed message")
        XCTAssertFalse(c.uncertain)
        XCTAssertTrue(store.canSend)
        store.recoverUnconfirmedMessage()
        XCTAssertEqual(store.draft, "existing draft\n\nunconfirmed message")
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["requests"].array.filter { $0["method"].string == "prompt.submit" }.count, 1)
    }

    func testDisconnectReattachesWithoutResubmittingAndInterrupts() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "only once"
        await store.send()
        let c = try XCTUnwrap(store.current)
        try await emit(c.key.storedID, type: "message.delta", text: "visible partial")
        try await eventually { c.messages.last?.text == "visible partial" }
        _ = try await fixture(["action": .string("drop")])
        try await eventually { !store.connected }
        XCTAssertEqual(c.messages.last?.text, "visible partial")
        XCTAssertTrue(c.uncertain)
        try await eventually { store.connected && c.runtimeID != nil && !c.uncertain }
        XCTAssertTrue(c.generating)
        XCTAssertEqual(c.messages.last?.text, "visible partial")
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["requests"].array.filter { $0["method"].string == "prompt.submit" }.count, 1)
        XCTAssertEqual(stats["requests"].array.filter { $0["method"].string == "session.resume" }.count, 1)
        await store.interrupt()
        try await eventually { !c.generating }
        XCTAssertEqual(c.messages.last?.text, "interrupted")
    }
    func testCompletionBetweenHistoryPageAndResumeIsNotLost() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "finish while reconnecting"
        await store.send()
        let c = try XCTUnwrap(store.current)
        _ = try await fixture(["action": .string("configure"), "complete_on_resume": .bool(true)])
        await store.connect()
        try await eventually { c.messages.last?.text == "finished during resume" }
        XCTAssertEqual(c.messages.map(\.text), ["finish while reconnecting", "finished during resume"])
        XCTAssertFalse(c.generating)
        XCTAssertFalse(c.uncertain)
        XCTAssertTrue(store.connected)
    }
    func testNativeTokenRefreshAndWebSocketTicket() async throws {
        guard !address.isEmpty else { throw XCTSkip("Run script/test.sh to enable protocol integration tests") }
        _ = try await fixture(["action": .string("reset")])
        _ = try await fixture(["action": .string("configure"), "native": .bool(true)])
        let client = try HermesClient(address: address, credentials: Credentials(accessToken: "expired", refreshToken: "refresh-token", provider: "fixture", expiresAt: 0))
        defer {
            client.disconnect()
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.hermes.mac.credentials", kSecAttrAccount as String: client.service] as CFDictionary)
        }
        try await client.connect()
        XCTAssertTrue(client.isConnected)
        let profiles = try await client.rest("/api/profiles")
        XCTAssertEqual(profiles["profiles"].array.count, 2)
        let stats = try await fixture(["action": .string("stats")])
        XCTAssertEqual(stats["refreshes"].number, 1)
        XCTAssertEqual(stats["tickets"].number, 1)
        XCTAssertEqual(stats["requests"].array.first?["method"].string, "client.capabilities")
        client.disconnect()
        let restarted = try HermesClient(address: address)
        defer { restarted.disconnect() }
        try await restarted.connect()
        XCTAssertTrue(restarted.isConnected)
        let afterRestart = try await fixture(["action": .string("stats")])
        XCTAssertEqual(afterRestart["refreshes"].number, 1)
        XCTAssertEqual(afterRestart["tickets"].number, 2)

    }

    func testDraftEditedDuringSessionCreationMigratesToCreatedSession() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        _ = try await fixture(["action": .string("configure"), "create_delay": .number(0.25)])
        store.draft = "submitted question"
        let sending = Task { await store.send() }
        try await eventually { store.profileBusy("a") }
        XCTAssertNil(store.selectedSession)
        store.draft = "next 中文 draft"
        await sending.value
        let c = try XCTUnwrap(store.current)
        XCTAssertEqual(c.messages.first?.text, "submitted question")
        XCTAssertEqual(store.draft, "next 中文 draft")
        let persistedKey = LocalState.draftKey(profile: "a", session: c.key.storedID)
        XCTAssertEqual(store.local.state(store.service).drafts[persistedKey], "next 中文 draft")
        await store.selectProfile("b")
        await store.selectProfile("a")
        XCTAssertEqual(store.current?.key, c.key)
        XCTAssertEqual(store.draft, "next 中文 draft")
    }

    func testInvalidServiceAddressPreservesConnectionAndBackgroundEvents() async throws {
        let (store, client, defaults, name) = try await prepare()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        store.draft = "background A"
        await store.send()
        let a = try XCTUnwrap(store.current)
        await store.selectProfile("b")
        store.draft = "B draft"
        let service = store.service
        await store.connect(address: "invalid-service-address")
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.connected)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(store.service, service)
        XCTAssertEqual(store.selectedProfile, "b")
        XCTAssertEqual(store.draft, "B draft")
        try await emit(a.key.storedID, type: "message.delta", text: "still streaming")
        try await eventually { a.messages.last?.text == "still streaming" }
        try await emit(a.key.storedID, type: "message.complete", text: "still completes")
        try await eventually { store.profileUnread("a") }
        XCTAssertEqual(a.messages.last?.text, "still completes")
        XCTAssertFalse(a.generating)
    }

}
