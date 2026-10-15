import XCTest
@testable import HermesMac

final class BotScreenViewerSecurityTests: XCTestCase {
    @MainActor func testNativeViewerCanvasNeverDragsTheWindowAndAcceptsInputFocus() {
        let coordinator = BotScreenWebView.Coordinator()
        let view = coordinator.makeWebView()
        XCTAssertTrue(view is BotScreenNativeWebView)
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        coordinator.dispose()
    }

    @MainActor func testViewerRejectsLongLivedCredentialsAndNonWebSocketURLs() {
        XCTAssertTrue(BotScreenWebView.Coordinator.validSocketURL(URL(string: "wss://example.com/api/display/ws?display_ticket=short-lived")!))
        for value in ["https://example.com/api/display/ws", "wss://user:secret@example.com/api/display/ws", "wss://example.com/api/display/ws?access_token=secret", "wss://example.com/api/display/ws?TOKEN=secret", "wss://example.com/api/display/ws#secret"] {
            XCTAssertFalse(BotScreenWebView.Coordinator.validSocketURL(URL(string: value)!))
        }
    }
    @MainActor func testHandshakeTimeoutFailsOnceAndDoesNotRestartForViewUpdates() async throws {
        let coordinator = BotScreenWebView.Coordinator(handshakeTimeout: .milliseconds(30))
        let id = UUID()
        let url = URL(string: "ws://127.0.0.1/api/display/ws?display_ticket=one-shot")!
        var failedIDs: [UUID] = []
        let callback: (BotScreenViewerEvent) -> Void = { event in
            if case .failed(let failedID, _) = event { failedIDs.append(failedID) }
        }
        coordinator.configure(id: id, url: url, hasControl: false, onEvent: callback)
        try await waitUntil { failedIDs == [id] }
        coordinator.configure(id: id, url: url, hasControl: true, onEvent: callback)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(failedIDs, [id])
        coordinator.dispose()
    }

    @MainActor func testNewAttemptAndDisposeCancelPreviousTimeouts() async throws {
        let coordinator = BotScreenWebView.Coordinator(handshakeTimeout: .milliseconds(50))
        let oldID = UUID(), newID = UUID()
        let url = URL(string: "ws://127.0.0.1/api/display/ws?display_ticket=one-shot")!
        var failedIDs: [UUID] = []
        let callback: (BotScreenViewerEvent) -> Void = { event in
            if case .failed(let failedID, _) = event { failedIDs.append(failedID) }
        }
        coordinator.configure(id: oldID, url: url, hasControl: false, onEvent: callback)
        coordinator.configure(id: newID, url: url, hasControl: false, onEvent: callback)
        try await waitUntil { failedIDs == [newID] }
        coordinator.configure(id: UUID(), url: url, hasControl: false, onEvent: callback)
        coordinator.dispose()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(failedIDs, [newID])
    }

    @MainActor private func waitUntil(timeout: Duration = .seconds(2), _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() {
            if ContinuousClock.now >= deadline { XCTFail("Timed out waiting for viewer event"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAssetHandlerOnlyServesBundledViewerOrigin() {
        XCTAssertNotNil(BotScreenAssetHandler.assetURL(for: URL(string: "hermes-botscreen://viewer/core/rfb.js")!))
        for value in ["https://viewer/core/rfb.js", "hermes-botscreen://evil/index.html", "hermes-botscreen://viewer/%2E%2E/%2E%2E/Info.plist", "hermes-botscreen://viewer/index.html?token=secret", "hermes-botscreen://viewer/%5Cetc%5Cpasswd"] {
            XCTAssertNil(BotScreenAssetHandler.assetURL(for: URL(string: value)!))
        }
    }
    func testAllVendoredModuleImportsResolveOffline() throws {
        let root = try XCTUnwrap(BotScreenAssetHandler.resourceRoot)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(pattern: #"(?:import\s+(?:[^;]*?\s+from\s+)?|export\s+[^;]*?\s+from\s+)[\"']([^\"']+)[\"']"#)
        for case let file as URL in enumerator where file.pathExtension == "js" {
            let text = try String(contentsOf: file)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                let path = String(text[Range(match.range(at: 1), in: text)!])
                XCTAssertTrue(path.hasPrefix("."), "Unexpected remote import in \(file.lastPathComponent)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.path), "Missing module \(path)")
            }
        }
    }
}
