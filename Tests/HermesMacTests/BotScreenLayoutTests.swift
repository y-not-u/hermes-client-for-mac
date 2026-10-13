import XCTest
import SwiftUI
import AppKit
@testable import HermesMac

/// Renders the production split in a real NSHostingView. A viewer must survive
/// expansion: recreating it would disconnect the WebSocket and reuse its ticket.
@MainActor final class BotScreenLayoutTests: XCTestCase {
    func testExpansionRestoresSplitAndPreservesViewerAtNarrowWindowWidth() async throws {
        _ = NSApplication.shared
        let state = SplitLayoutState()
        let probes = SplitLayoutProbes()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Hermes split layout test"
        window.contentView = NSHostingView(rootView: SplitLayoutRoot(state: state, probes: probes))
        // Rendering requires a real window; orderBack avoids stealing the user's focus.
        window.orderBack(nil)
        defer { window.close() }

        try await waitForLayout(window) {
            (probes.chat?.bounds.width ?? 0) > 250 && (probes.computer?.bounds.width ?? 0) > 250
        }
        let chat = try XCTUnwrap(probes.chat)
        let computer = try XCTUnwrap(probes.computer)
        let originalChatWidth = chat.bounds.width
        let originalComputerWidth = computer.bounds.width
        XCTAssertEqual(originalChatWidth + originalComputerWidth, 799, accuracy: 1)
        XCTAssertEqual(probes.computerCreationCount, 1)

        state.expanded = true
        try await waitForLayout(window) { chat.bounds.width == 0 && computer.bounds.width >= 799 }
        XCTAssertEqual(chat.bounds.width, 0, accuracy: 0.5)
        XCTAssertEqual(computer.bounds.width, 800, accuracy: 0.5,
                       "Expanding must consume the chat's space, not leave an invisible split column")
        XCTAssertTrue(probes.computer === computer)
        XCTAssertEqual(probes.computerCreationCount, 1, "Expansion must not recreate the desktop viewer")

        state.expanded = false
        try await waitForLayout(window) { abs(chat.bounds.width - originalChatWidth) < 1 }
        XCTAssertEqual(chat.bounds.width, originalChatWidth, accuracy: 0.5)
        XCTAssertEqual(computer.bounds.width, originalComputerWidth, accuracy: 0.5)
        XCTAssertTrue(probes.computer === computer)

        // The minimum main window leaves roughly 510 points for chat and desktop.
        window.setContentSize(NSSize(width: 510, height: 600))
        try await waitForLayout(window) { chat.bounds.width < 300 && computer.bounds.width < 300 }
        XCTAssertGreaterThanOrEqual(chat.bounds.width, 250)
        XCTAssertGreaterThanOrEqual(computer.bounds.width, 250)
        XCTAssertEqual(chat.bounds.width + computer.bounds.width, 509, accuracy: 1)
        XCTAssertTrue(probes.computer === computer)
        XCTAssertEqual(probes.computerCreationCount, 1)
    }

    private func waitForLayout(_ window: NSWindow, matching predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native split layout did not reach the expected rendered widths")
        throw NSError(domain: "BotScreenLayoutTests", code: 1)
    }
}

@MainActor private final class SplitLayoutState: ObservableObject {
    @Published var expanded = false
}

@MainActor private final class SplitLayoutProbes {
    var chat: NSView?
    var computer: NSView?
    var computerCreationCount = 0
}

@MainActor private struct SplitLayoutProbe: NSViewRepresentable {
    let computer: Bool
    let probes: SplitLayoutProbes

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        if computer {
            probes.computer = view
            probes.computerCreationCount += 1
        } else {
            probes.chat = view
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor private struct SplitLayoutRoot: View {
    @ObservedObject var state: SplitLayoutState
    let probes: SplitLayoutProbes

    var body: some View {
        ChatComputerSplit(isOpen: true, expanded: state.expanded) {
            SplitLayoutProbe(computer: false, probes: probes)
        } computer: {
            SplitLayoutProbe(computer: true, probes: probes)
        }
    }
}
