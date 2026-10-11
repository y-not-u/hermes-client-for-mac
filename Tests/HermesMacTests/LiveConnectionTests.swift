import XCTest
@testable import HermesMac

/// Opt-in only: creates clearly titled test chats on the explicitly selected real service.
/// Credentials are entered in the system browser, never passed through source or test logs.
@MainActor final class LiveConnectionTests: XCTestCase {
    func testNativeLoginAndRealService() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["HERMES_LIVE_SERVER"] else { throw XCTSkip("Set HERMES_LIVE_SERVER for authorized real-service verification") }
        let client = try HermesClient(address: address)
        defer { client.disconnect() }
        if let callbackFile = env["HERMES_LIVE_AUTH_URL_FILE"] {
            let login = NativeLogin(openBrowser: { url in
                do { try url.absoluteString.write(toFile: callbackFile, atomically: true, encoding: .utf8); return true }
                catch { return false }
            })
            try await login.signIn(client: client)
        }
        try await client.connect()
        let profiles = try await client.rest("/api/profiles")["profiles"].array
        XCTAssertFalse(profiles.isEmpty)
        let first = try XCTUnwrap(profiles.first?["name"].string)
        let list = try await client.rest("/api/sessions", query: [URLQueryItem(name: "profile", value: first), URLQueryItem(name: "limit", value: "5")])
        if let row = list["sessions"].array.first {
            let history = try await client.rest("/api/sessions/\(row["id"].string)/messages", query: [URLQueryItem(name: "profile", value: first), URLQueryItem(name: "limit", value: "5")])
            XCTAssertNotEqual(history["messages"], .null)
            let resumed = try await client.request("session.resume", ["profile": .string(first), "session_id": row["id"]])
            XCTAssertFalse(resumed["session_id"].string.isEmpty)
        }
        guard env["HERMES_LIVE_CHAT"] == "1" else { return }
        let defaultsName = "HermesMacLive-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let local = LocalState(defaults: defaults); local.address = address
        let store = AppStore(local: local)
        await store.connect(); XCTAssertTrue(store.connected, store.error ?? "Not connected")
        await store.selectProfile(first); store.newSession(); store.draft = "请只回复 HERMES_MAC_A_OK，不调用任何工具。"
        let aSend = Task { await store.send() }
        try await eventually { store.current != nil || store.error != nil }
        XCTAssertNil(store.error)
        let a = try XCTUnwrap(store.current)
        store.draft = "A live draft"
        if profiles.count > 1 {
            let second = profiles[1]["name"].string
            await store.selectProfile(second); store.newSession(); store.draft = "请只回复 HERMES_MAC_B_OK，不调用任何工具。"
            let bSend = Task { await store.send() }
            try await eventually { store.current != nil }
            let b = try XCTUnwrap(store.current)
            store.draft = "B live draft"
            await aSend.value; await bSend.value
            try await eventually(timeout: 120) { !a.generating && !b.generating }
            XCTAssertNil(a.error); XCTAssertNil(b.error)
            XCTAssertTrue(a.messages.contains { $0.role == "assistant" && $0.text.contains("HERMES_MAC_A_OK") })
            XCTAssertTrue(b.messages.contains { $0.role == "assistant" && $0.text.contains("HERMES_MAC_B_OK") })
            XCTAssertTrue(a.unread)
            await store.selectProfile(first); XCTAssertEqual(store.draft, "A live draft")
            await store.selectProfile(second); XCTAssertEqual(store.draft, "B live draft")
            await store.rename(SessionSummary(id: b.key.storedID, title: "test"), to: "HermesMac · connection test B")
        } else { await aSend.value; try await eventually(timeout: 120) { !a.generating } }
        await store.selectProfile(first)
        await store.rename(SessionSummary(id: a.key.storedID, title: "test"), to: "HermesMac · connection test A")
        await store.connect()
        XCTAssertTrue(store.connected)
        XCTAssertTrue(store.current?.messages.contains { $0.text.contains("HERMES_MAC_A_OK") } == true)
    }
    private func eventually(timeout: Double = 20, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(predicate(), "Real service did not reach expected state before timeout")
    }
}
