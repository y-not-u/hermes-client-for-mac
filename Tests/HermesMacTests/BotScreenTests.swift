import XCTest
@testable import HermesMac

/// Exercises the actual JSON-RPC socket against a strict, transport-scoped display fixture.
@MainActor final class BotScreenTests: XCTestCase {
    private var address: String { ProcessInfo.processInfo.environment["HERMES_TEST_SERVER"] ?? "" }
    private func fixture(_ body: [String: JSON]) async throws -> JSON {
        var request = URLRequest(url: try XCTUnwrap(URL(string: address + "/__test")))
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(JSON.object(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(JSON.self, from: data)
    }
    private func prepare() async throws -> (BotScreenStore, HermesClient) {
        guard !address.isEmpty else { throw XCTSkip("Run script/test.sh for Bot Screen integration") }
        _ = try await fixture(["action": .string("reset")])
        let client = try HermesClient(address: address, credentials: Credentials(sessionToken: "fixture-token"))
        try await client.connect()
        let screen = BotScreenStore()
        client.onFrame = { [weak screen] frame in _ = screen?.receive(frame) }
        await screen.configure(client: client, profile: "a", connected: true)
        return (screen, client)
    }
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Display state did not settle")
    }

    func testStartObserveTakeOverHandBackAndStop() async throws {
        let (screen, client) = try await prepare()
        defer { client.disconnect(); screen.disconnected() }
        await screen.open()
        XCTAssertFalse(try XCTUnwrap(screen.status).running)
        XCTAssertNil(screen.viewer)
        await screen.start()
        let viewer = try XCTUnwrap(screen.viewer)
        XCTAssertEqual(viewer.websocketURL.path, "/api/display/ws")
        XCTAssertEqual(URLComponents(url: viewer.websocketURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "display_ticket")
        XCTAssertFalse(screen.hasControl)
        await screen.takeOver()
        XCTAssertTrue(screen.hasControl)
        await screen.handBack()
        XCTAssertFalse(screen.humanHasControl)
        await screen.stop()
        XCTAssertFalse(screen.status?.running == true)
        XCTAssertNil(screen.viewer)
        await screen.close()
    }

    func testClosingPanelReleasesOnlyOwnLeaseWithoutStoppingDesktop() async throws {
        let (screen, client) = try await prepare()
        defer { client.disconnect(); screen.disconnected() }
        await screen.open(); await screen.start(); await screen.takeOver()
        XCTAssertTrue(screen.hasControl)
        await screen.close()
        let report = try await fixture(["action": .string("inspect")])
        XCTAssertEqual(report["display_states"]["a"]["lease"]["holder"].string, "agent")
        XCTAssertTrue(report["display_states"]["a"]["running"].bool)
        XCTAssertFalse(screen.isOpen)
        XCTAssertNil(screen.viewer)
        await screen.open()
        XCTAssertFalse(screen.hasControl)
        await screen.takeOver()
        _ = try await fixture(["action": .string("configure"), "display_other_viewer": .bool(true)])
        try await eventually { !screen.hasControl && screen.humanHasControl }
        await screen.stop()
        XCTAssertNotNil(screen.error)
        await screen.close()
        let other = try await fixture(["action": .string("inspect")])
        XCTAssertEqual(other["display_states"]["a"]["lease"]["holder"].string, "human")
        XCTAssertTrue(other["display_states"]["a"]["running"].bool)
    }

    func testProfileChangeDoesNotReuseTicketOrControlAndIgnoresOldViewerEvents() async throws {
        let (screen, client) = try await prepare()
        defer { client.disconnect(); screen.disconnected() }
        await screen.open(); await screen.start(); await screen.takeOver()
        let oldViewer = try XCTUnwrap(screen.viewer)
        await screen.configure(client: client, profile: "b", connected: true)
        XCTAssertEqual(screen.profile, "b")
        XCTAssertFalse(screen.status?.running == true)
        XCTAssertFalse(screen.hasControl)
        screen.handleViewerEvent(.connected(oldViewer.id))
        XCTAssertFalse(screen.viewerConnected)
        await screen.start()
        XCTAssertNotEqual(screen.viewer?.id, oldViewer.id)
        let report = try await fixture(["action": .string("inspect")])
        XCTAssertEqual(report["display_states"]["a"]["lease"]["holder"].string, "agent")
        await screen.close()
    }

    func testRPCDisconnectKeepsServerLeaseAndReconnectRequiresNewViewerTakeover() async throws {
        let (screen, client) = try await prepare()
        defer { client.disconnect(); screen.disconnected() }
        await screen.open(); await screen.start(); await screen.takeOver()
        let first = try XCTUnwrap(screen.viewer)
        client.disconnect(); screen.disconnected()
        XCTAssertFalse(screen.hasControl)
        let report = try await fixture(["action": .string("inspect")])
        XCTAssertEqual(report["display_states"]["a"]["lease"]["holder"].string, "human")
        try await client.connect()
        await screen.configure(client: client, profile: "a", connected: true)
        XCTAssertNotEqual(screen.viewer?.id, first.id)
        XCTAssertTrue(screen.humanHasControl)
        XCTAssertFalse(screen.hasControl)
        await screen.takeOver()
        XCTAssertTrue(screen.hasControl)
        await screen.handBack(); await screen.close()
    }

    func testRFBReconnectRetainsIdentityAndLeaseOnSameRPCTransport() async throws {
        let (screen, client) = try await prepare()
        defer { client.disconnect(); screen.disconnected() }
        await screen.open(); await screen.start(); await screen.takeOver()
        let first = try XCTUnwrap(screen.viewer)
        await screen.reconnectViewer()
        XCTAssertNotEqual(screen.viewer?.id, first.id)
        XCTAssertTrue(screen.hasControl)
        let report = try await fixture(["action": .string("inspect")])
        let observers = report["requests"].array.filter { $0["method"].string == "display.observe" }
        XCTAssertFalse(try XCTUnwrap(observers.last)["params"]["viewer_id"].string.isEmpty)
        await screen.close()
    }

    func testLateObserveCannotReopenClosedPanel() async throws {
        let (screen, client) = try await prepare()
        defer { client.disconnect(); screen.disconnected() }
        await screen.open(); await screen.start()
        _ = try await fixture(["action": .string("configure"), "display_delay_method": .string("display.observe"), "display_delay": .number(0.25)])
        let pending = Task { await screen.reconnectViewer() }
        try await eventually { screen.viewer == nil }
        await screen.close(); await pending.value
        XCTAssertFalse(screen.isOpen)
        XCTAssertNil(screen.viewer)
    }

    func testLateTakeoverIsCompensatedAfterClose() async throws {
        let (screen, client) = try await prepare()
        defer { client.disconnect(); screen.disconnected() }
        await screen.open(); await screen.start()
        _ = try await fixture(["action": .string("configure"), "display_delay_method": .string("display.lease.acquire"), "display_delay": .number(0.25)])
        let pending = Task { await screen.takeOver() }
        try await eventually { screen.busy }
        await screen.close(); await pending.value
        let report = try await fixture(["action": .string("inspect")])
        XCTAssertEqual(report["display_states"]["a"]["lease"]["holder"].string, "agent")
        XCTAssertFalse(screen.isOpen)
    }

    func testOldServerMissingPackagesAndRefusedMutationRemainReviewable() async throws {
        let (screen, client) = try await prepare()
        defer { client.disconnect(); screen.disconnected() }
        _ = try await fixture(["action": .string("configure"), "display_unknown_method": .bool(true)])
        await screen.open()
        XCTAssertTrue(screen.unsupported)
        XCTAssertNil(screen.viewer)
        _ = try await fixture(["action": .string("configure"), "display_unknown_method": .bool(false), "display_installed": .bool(false)])
        await screen.refresh()
        XCTAssertFalse(screen.unsupported)
        XCTAssertFalse(screen.status?.installed == true)
        XCTAssertEqual(screen.status?.missing, ["Xvnc", "xfwm4"])
        _ = try await fixture(["action": .string("configure"), "display_installed": .bool(true), "display_error_method": .string("display.start")])
        await screen.refresh(); await screen.start()
        XCTAssertTrue(screen.error?.contains("refused") == true, "Refreshing after failure must preserve the action error")
        await screen.close()
    }

    func testObserveRejectsForeignEndpointAndKeepsReverseProxyPrefix() async throws {
        let good: JSON = .object(["ticket": .string("one-shot/+?&"), "viewer_id": .string("viewer"), "path": .string("/api/display/ws")])
        let made = try BotScreenViewerConnection.make(baseURL: URL(string: "https://host.test/hermes/")!, observe: good)
        XCTAssertEqual(made.websocketURL.scheme, "wss")
        XCTAssertEqual(made.websocketURL.path, "/hermes/api/display/ws")
        XCTAssertEqual(URLComponents(url: made.websocketURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "one-shot/+?&")
        let (screen, client) = try await prepare()
        defer { client.disconnect(); screen.disconnected() }
        _ = try await fixture(["action": .string("configure"), "display_observe_path": .string("https://evil.test/api/display/ws")])
        await screen.open(); await screen.start()
        XCTAssertNil(screen.viewer)
        XCTAssertNotNil(screen.error)
        await screen.close()
    }

    func testFailedCloseReleaseNoticeSurvivesStatusRefresh() async throws {
        let (screen, client) = try await prepare()
        defer { client.disconnect(); screen.disconnected() }
        await screen.open(); await screen.start(); await screen.takeOver()
        _ = try await fixture(["action": .string("configure"), "display_error_method": .string("display.lease.release")])
        await screen.close()
        XCTAssertNotNil(screen.notice)
        await screen.open()
        XCTAssertNotNil(screen.notice, "A successful status read must not hide a failed release")
        XCTAssertTrue(screen.humanHasControl)
        _ = try await fixture(["action": .string("configure"), "display_error_method": .string("")])
        await screen.handBack(); await screen.close()
        screen.dismissNotice()
        XCTAssertNil(screen.notice)
    }

    func testMalformedStatusIsAnErrorRatherThanAnUnsupportedHost() async throws {
        let client = try HermesClient(address: "http://127.0.0.1:9119", credentials: Credentials())
        let screen = BotScreenStore(request: { _, _ in .object([:]) })
        await screen.configure(client: client, profile: "a", connected: true)
        await screen.open()
        XCTAssertNil(screen.status)
        XCTAssertFalse(screen.unsupported)
        XCTAssertTrue(screen.error?.contains("无效桌面状态") == true)
        await screen.close(); screen.disconnected()
    }
}
