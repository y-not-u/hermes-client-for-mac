import XCTest
import AppKit
import WebKit
@testable import HermesMac

/// Real WebKit, bundled modules, WebSocket handshake, framebuffer pixels and input.
@MainActor final class BotScreenViewerIntegrationTests: XCTestCase {
    private var address: String { ProcessInfo.processInfo.environment["HERMES_TEST_SERVER"] ?? "" }
    private func fixture(_ body: [String: JSON]) async throws -> JSON {
        var request = URLRequest(url: try XCTUnwrap(URL(string: address + "/__test")))
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(JSON.object(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(JSON.self, from: data)
    }
    private func waitUntil(timeout: Double = 15, _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("WebKit / RFB state did not settle")
        throw ClientError(message: "WebKit integration timed out")
    }

    func testBundledWebKitViewerRendersRFBAndGatesKeyboardInput() async throws {
        guard !address.isEmpty else { throw XCTSkip("Run script/test.sh for WebKit/RFB integration") }
        _ = NSApplication.shared
        _ = try await fixture(["action": .string("reset")])
        let client = try HermesClient(address: address, credentials: Credentials(sessionToken: "fixture-token"))
        try await client.connect()
        let screen = BotScreenStore()
        client.onFrame = { [weak screen] in _ = screen?.receive($0) }
        await screen.configure(client: client, profile: "a", connected: true)
        await screen.open(); await screen.start()
        let connection = try XCTUnwrap(screen.viewer)
        let coordinator = BotScreenWebView.Coordinator()
        let webView = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFront(nil)
        var failure: String?
        coordinator.configure(id: connection.id, url: connection.websocketURL, hasControl: false) { event in
            screen.handleViewerEvent(event)
            if case .failed(_, let message) = event { failure = message }
        }
        defer { coordinator.dispose(); window.close(); client.disconnect(); screen.disconnected() }
        do { try await waitUntil { screen.viewerConnected || failure != nil } }
        catch {
            let diagnostics = try? await webView.evaluateJavaScript("JSON.stringify({url:location.origin, ready:!!window.hermesBotScreen, canvas:!!document.querySelector('canvas'), body:document.body?.innerText})")
            print("Viewer diagnostic (no tickets): \(diagnostics ?? "unavailable")")
            let report = try await fixture(["action": .string("inspect")])
            print("RFB handshakes: \(report["display_handshakes"].number), frames: \(report["display_frames"].number)")
            throw error
        }
        XCTAssertNil(failure)
        XCTAssertTrue(screen.viewerConnected)
        try await waitUntil {
            try await webView.evaluateJavaScript("document.querySelector('canvas')?.width === 640") as? Bool == true
        }
        try await waitUntil {
            let report = try await self.fixture(["action": .string("inspect")])
            return report["display_frames"].number > 0
        }
        // Inspect actual decoded canvas pixels, rather than accepting a handshake as a visible screen.
        try await waitUntil {
            try await webView.evaluateJavaScript("document.querySelector('canvas').getContext('2d').getImageData(100,100,1,1).data[0] === 65") as? Bool == true
        }
        // viewOnly must avoid the local cursor/mouse pipeline, not merely drop RFB output.
        _ = try await webView.callAsyncJavaScript("""
          const {default:RFB} = await import('./core/rfb.js');
          const original = RFB.prototype._handleMouseMove;
          window.watchMouseMoves = 0;
          RFB.prototype._handleMouseMove = function(...args) {
            window.watchMouseMoves++;
            return original.apply(this, args);
          };
          return true;
        """, arguments: [:], in: nil, contentWorld: .page)
        let hoverScript = """
        (() => {
          const canvas = document.querySelector('canvas');
          const rect = canvas.getBoundingClientRect();
          for (let i=0; i<120; i++) canvas.dispatchEvent(new MouseEvent('mousemove',
             {clientX:rect.x+20+i, clientY:rect.y+100, bubbles:true}));
          return window.watchMouseMoves;
        })()
        """
        let watchMoves = try await webView.evaluateJavaScript(hoverScript) as? Int
        XCTAssertEqual(watchMoves, 0, "Read-only hover must not invoke noVNC's mouse/cursor work")
        let watchCursor = try await webView.evaluateJavaScript("getComputedStyle(document.querySelector('canvas')).cursor") as? String
        XCTAssertEqual(watchCursor, "default")
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image = try await webView.takeSnapshot(configuration: configuration)
        XCTAssertGreaterThan(image.size.width, 0)
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/hermes-bot-screen-viewer-test.png"))
        }
        let keyScript = """
        (() => {
          const canvas = document.querySelector('canvas');
          canvas.focus();
          for (const type of ['keydown', 'keyup']) canvas.dispatchEvent(new KeyboardEvent(type,
             {key: 'a', code: 'KeyA', keyCode: 65, which: 65, bubbles: true}));
          return true;
        })()
        """
        let pointerScript = """
        (() => {
          const canvas = document.querySelector('canvas');
          const rect = canvas.getBoundingClientRect();
          canvas.dispatchEvent(new MouseEvent('mousedown', {clientX:rect.x+100, clientY:rect.y+100,
             button:0, buttons:1, bubbles:true}));
          canvas.dispatchEvent(new MouseEvent('mouseup', {clientX:rect.x+100, clientY:rect.y+100,
             button:0, buttons:0, bubbles:true}));
          return true;
        })()
        """
        _ = try await webView.evaluateJavaScript(keyScript)
        _ = try await webView.evaluateJavaScript(pointerScript)
        let syntheticPointerScript = pointerScript.replacingOccurrences(of: "buttons:1", with: "buttons:0")
        _ = try await webView.evaluateJavaScript(syntheticPointerScript)
        var report = try await fixture(["action": .string("inspect")])
        XCTAssertTrue(report["display_inputs"].array.isEmpty)
        await screen.takeOver()
        XCTAssertTrue(screen.hasControl)
        coordinator.configure(id: connection.id, url: connection.websocketURL, hasControl: screen.hasControl,
                              onEvent: screen.handleViewerEvent)
        // The native bridge updates JavaScript asynchronously; wait for its setter to finish.
        _ = try await webView.evaluateJavaScript("true")
        _ = try await webView.evaluateJavaScript(hoverScript)
        let controlledMoves = try await webView.evaluateJavaScript("window.watchMouseMoves") as? Int
        XCTAssertEqual(controlledMoves, 120,
                       "Taking control must restore the pointer pipeline")
        _ = try await webView.evaluateJavaScript(keyScript)
        _ = try await webView.evaluateJavaScript(pointerScript)
        _ = try await webView.evaluateJavaScript(syntheticPointerScript)
        try await waitUntil {
            let report = try await self.fixture(["action": .string("inspect")])
            return report["display_inputs"].array.count >= 6
        }
        report = try await fixture(["action": .string("inspect")])
        let inputCount = report["display_inputs"].array.count
        XCTAssertTrue(report["display_inputs"].array.allSatisfy { $0["profile"].string == "a" })
        XCTAssertGreaterThanOrEqual(report["display_inputs"].array.filter {
            $0["kind"].number == 5 && $0["hex"].string.hasPrefix("01")
        }.count, 2, "Both normal and WebKit synthesized presses must cross the noVNC/RFB boundary")
        await screen.handBack()
        coordinator.configure(id: connection.id, url: connection.websocketURL, hasControl: false,
                              onEvent: screen.handleViewerEvent)
        _ = try await webView.evaluateJavaScript("true")
        _ = try await webView.evaluateJavaScript(keyScript)
        _ = try await webView.evaluateJavaScript(pointerScript)
        _ = try await webView.evaluateJavaScript(syntheticPointerScript)
        let handBackMoves = try await webView.evaluateJavaScript(hoverScript) as? Int
        XCTAssertEqual(handBackMoves, 120, "Handing back must disable local pointer handling again")
        report = try await fixture(["action": .string("inspect")])
        XCTAssertEqual(report["display_inputs"].array.count, inputCount)
        XCTAssertEqual(report["display_handshakes"].number, 1)
        await screen.close()
    }
}
