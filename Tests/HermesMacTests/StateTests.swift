import XCTest
import Security
import SwiftUI
import AppKit
@testable import HermesMac

@MainActor final class StateTests: XCTestCase {
    func testRefusedCorrectionKeepsOriginalReplyStream() {
        let c = Conversation(key: ConversationKey(service: "local", profile: "a", storedID: "stored"))
        c.begin("question"); c.appendStream("partial")
        let id = c.appendFollowUp("correction", splitReply: true)
        c.setDelivery(id, "提交失败", preserveReply: true)
        c.apply(type: "message.complete", payload: .object(["text": .string("original answer")]), visible: true)
        XCTAssertEqual(c.messages.map(\.text), ["question", "original answer", "correction"])
    }

    func testResumeRebuildsInflightCorrectionsWithoutDuplicatingLocalInput() {
        let c = Conversation(key: ConversationKey(service: "local", profile: "a", storedID: "stored"))
        c.begin("question")
        _ = c.appendFollowUp("correction", splitReply: true)
        c.snapshot(.object(["session_id": .string("runtime"), "messages_omitted": .bool(true), "running": .bool(true),
            "inflight": .object(["user": .string("question"), "assistant": .string("partial"), "corrections": .array([.string("correction"), .string("another note")])])]))
        XCTAssertEqual(c.messages.map(\.text), ["question", "partial", "correction", "another note"])
        c.appendStream("continued")
        XCTAssertEqual(c.messages.last?.text, "continued")
    }

    func testCodeViewportHasFiniteHeightIndependentOfLineWidth() {
        let short = CodeContentView.viewportHeight(for: "x")
        let wide = CodeContentView.viewportHeight(for: String(repeating: "x", count: 20_000))
        XCTAssertEqual(short, wide)
        XCTAssertGreaterThan(short, 24)
        XCTAssertEqual(CodeContentView.contentHeight(for: "a\r\nb"), CodeContentView.contentHeight(for: "a\nb"))
        XCTAssertEqual(CodeContentView.viewportHeight(for: String(repeating: "line\n", count: 500)), 360)
    }

    func testLazyTranscriptLayoutWithWideCodeAndStreamingFences() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let longLine = String(repeating: "let long_name = 123; ", count: 300)
        let blocks = "Before\n```swift\n" + longLine + "\n" + String(repeating: "line\n", count: 80) + "```\nAfter\n```sh\necho ok\n```"
        func transcript(_ text: String) -> some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(0..<3) { _ in
                        HStack(alignment: .top, spacing: 10) {
                            Color.clear.frame(width: 28, height: 28)
                            MarkdownView(text: text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .cleanScrollBars()
        }
        let hosting = NSHostingView(rootView: transcript(blocks))
        window.contentView = hosting
        let start = Date()
        for index in 0..<12 {
            let width: CGFloat = index.isMultiple(of: 2) ? 320 : 900
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            hosting.rootView = transcript(blocks + "\n```python\n" + String(repeating: "x", count: index * 100))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(hosting.fittingSize.height.isFinite)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "Lazy layout should settle promptly during resize and streaming")
        var codeScrolls: [NSScrollView] = []
        func collect(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { codeScrolls.append(scroll) }
            view.subviews.forEach(collect)
        }
        collect(hosting)
        XCTAssertFalse(codeScrolls.isEmpty, "Code should use native scroll views")
        XCTAssertTrue(codeScrolls.contains { ($0.documentView?.frame.width ?? 0) > 900 })
        XCTAssertTrue(codeScrolls.allSatisfy { $0.frame.height <= 360 })
        XCTAssertTrue(codeScrolls.allSatisfy { ($0.documentView as? NSTextView)?.isSelectable == true })
    }

    func testAutomaticRetryOnlyHandlesTransientConnectionErrors() {
        XCTAssertTrue(HermesClient.isTransientConnectionError(URLError(.notConnectedToInternet)))
        XCTAssertTrue(HermesClient.isTransientConnectionError(URLError(.cannotConnectToHost)))
        XCTAssertTrue(HermesClient.isTransientConnectionError(ClientError(message: "socket unavailable", retryable: true)))
        XCTAssertFalse(HermesClient.isTransientConnectionError(URLError(.cancelled)))
        XCTAssertFalse(HermesClient.isTransientConnectionError(ClientError(message: "认证已失效")))
        XCTAssertFalse(HermesClient.isTransientConnectionError(KeychainError(message: "Keychain locked")))
    }

    func testKeychainReadFailuresAreNotTreatedAsMissingCredentials() throws {
        XCTAssertEqual(try Keychain.decode(status: errSecItemNotFound, data: nil).accessToken, "")
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            XCTAssertThrowsError(try Keychain.decode(status: status, data: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains(String(status)))
            }
        }
        XCTAssertThrowsError(try Keychain.decode(status: errSecSuccess, data: Data("invalid".utf8)))
        let value = Credentials(accessToken: "test-access", refreshToken: "test-refresh")
        let restored = try Keychain.decode(status: errSecSuccess, data: JSONEncoder().encode(value))
        XCTAssertEqual(restored.accessToken, value.accessToken)
        XCTAssertEqual(restored.refreshToken, value.refreshToken)
    }

    func testToolsAppearBeforeFinalReplyAndRemainInTheirTurn() {
        let c = Conversation(key: ConversationKey(service: "local", profile: "a", storedID: "stored"))
        c.begin("question")
        c.appendStream("checking")
        c.apply(type: "tool.start", payload: .object(["tool_id": .string("one"), "name": .string("search")]), visible: true)
        c.apply(type: "tool.complete", payload: .object(["tool_id": .string("one"), "result": .string("found")]), visible: true)
        c.apply(type: "tool.start", payload: .object(["tool_id": .string("two"), "name": .string("read")]), visible: true)
        c.apply(type: "tool.complete", payload: .object(["tool_id": .string("two"), "result": .string("read result")]), visible: true)
        c.appendStream("answer")
        c.apply(type: "message.complete", payload: .object(["text": .string("final answer")]), visible: true)

        XCTAssertEqual(c.messages.map(\.text), ["question", "checking", "final answer"])
        XCTAssertEqual(c.entries.count, 4)
        guard case .tools(let activity) = c.entries[2] else { return XCTFail("Tools must precede the final reply") }
        XCTAssertEqual(activity.tools.map(\.name), ["search", "read"])
        XCTAssertTrue(activity.tools.allSatisfy(\.complete))

        c.begin("next question")
        c.apply(type: "tool.start", payload: .object(["tool_id": .string("three"), "name": .string("terminal")]), visible: true)
        c.apply(type: "message.complete", payload: .object(["text": .string("next answer")]), visible: true)
        XCTAssertEqual(c.toolActivities.count, 2)
        guard case .tools(let previous) = c.entries[2], case .tools(let next) = c.entries[5],
              case .message(let reply) = c.entries[6] else { return XCTFail("Each turn must retain its tool group before its reply") }
        XCTAssertEqual(previous.id, activity.id)
        XCTAssertEqual(next.tools.map(\.name), ["terminal"])
        XCTAssertEqual(reply.text, "next answer")
    }

    func testToolGroupFollowsRestoredHistoryIDs() {
        let c = Conversation(key: ConversationKey(service: "local", profile: "a", storedID: "stored"))
        c.begin("question")
        c.apply(type: "tool.start", payload: .object(["tool_id": .string("one"), "name": .string("search")]), visible: true)
        c.apply(type: "message.complete", payload: .object(["text": .string("answer")]), visible: true)
        c.snapshot(.object(["session_id": .string("runtime")]), history: [
            Message(id: "server-user", role: "user", text: "question"),
            Message(id: "server-answer", role: "assistant", text: "answer")
        ])
        XCTAssertEqual(c.entries.count, 3)
        guard case .tools(let activity) = c.entries[1] else { return XCTFail("Restored tools must remain before the answer") }
        XCTAssertEqual(activity.afterMessageID, "server-user")
    }

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

    func testCleanScrollerOptimizationAndTransparentScroller() {
        // Test global track clean background enablement
        NSScroller.enableCleanTrackBackground()

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scroll.hasVerticalScroller = true
        let overlayScroller = TransparentOverlayScroller(frame: NSRect(x: 0, y: 0, width: 14, height: 100))
        scroll.verticalScroller = overlayScroller
        scroll.scrollerStyle = .overlay
        XCTAssertEqual(scroll.verticalScroller?.scrollerStyle, .overlay)

        // Verify drawing works cleanly without errors
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 14,
            pixelsHigh: 100,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return }
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        overlayScroller.draw(NSRect(x: 0, y: 0, width: 14, height: 100))
        NSGraphicsContext.restoreGraphicsState()
    }

    func testHostingCleanScrollBarsModifier() {
        let view = ScrollView {
            Text("Sample Content")
        }
        .cleanScrollBars()

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        hosting.layoutSubtreeIfNeeded()

        var found: NSScrollView?
        func traverse(_ v: NSView) {
            if let s = v as? NSScrollView { found = s; return }
            for sub in v.subviews { traverse(sub) }
        }
        traverse(hosting)
        XCTAssertNotNil(found)
    }

    func testCleanScrollerAndTransparentScrollView() {
        NSScroller.enableCleanTrackBackground()

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertFalse(scroll.drawsBackground)
        XCTAssertEqual(scroll.backgroundColor, .clear)
        XCTAssertFalse(scroll.contentView.drawsBackground)
        XCTAssertEqual(scroll.contentView.backgroundColor, .clear)
    }
}

