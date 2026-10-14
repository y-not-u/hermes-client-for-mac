import XCTest
import Security
import SwiftUI
import AppKit
@testable import HermesMac

@MainActor final class StateTests: XCTestCase {
    func testConversationCacheProtectsStateAndRetriesPreviouslyProtectedEntries() throws {
        let name = "HermesMemory-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStore(local: LocalState(defaults: defaults))
        store.selectedProfile = "a"
        let protected = (0..<8).map { index -> Conversation in
            let c = Conversation(key: ConversationKey(service: store.service, profile: "a", storedID: "protected-\(index)"))
            store.conversations[c.key] = c
            return c
        }
        store.selectedSession = protected[0].key.storedID
        protected[1].generating = true
        protected[2].uncertain = true
        protected[3].loading = true
        protected[4].queryingStatus = true
        protected[5].unread = true
        protected[6].approvals = [Approval(id: "approval", params: .object([:]))]
        protected[7].submittingApprovals = ["approval"]
        for index in 0..<30 {
            let key = ConversationKey(service: store.service, profile: "a", storedID: "idle-\(index)")
            store.conversations[key] = Conversation(key: key)
        }
        store.pruneConversationCache()
        XCTAssertEqual(store.conversations.count, 20)
        for c in protected { XCTAssertTrue(store.conversations[c.key] === c) }
        // All protected entries may exceed the soft limit without losing state.
        for c in store.conversations.values { c.generating = true }
        for index in 0..<5 {
            let key = ConversationKey(service: store.service, profile: "a", storedID: "active-\(index)")
            let c = Conversation(key: key); c.generating = true; store.conversations[key] = c
        }
        store.pruneConversationCache()
        XCTAssertEqual(store.conversations.count, 25)
        for c in store.conversations.values { c.generating = false }
        store.pruneConversationCache()
        XCTAssertEqual(store.conversations.count, 20, "Skipped entries must remain eviction candidates")
        XCTAssertTrue(store.current === protected[0])
    }

    func testReplyNotificationsOnlyForSuccessfulBackgroundCompletion() {
        var active = true
        var replies: [(ConversationKey, String, String)] = []
        let store = AppStore(isAppActive: { active }, onReplyCompleted: { replies.append(($0, $1, $2)) })
        let c = Conversation(key: ConversationKey(service: "local", profile: "a", storedID: "stored"))
        c.begin("foreground")
        store.applyEvent(type: "message.complete", payload: .object(["text": .string("foreground answer")]), to: c)
        XCTAssertTrue(replies.isEmpty)

        active = false
        c.begin("background")
        store.applyEvent(type: "message.delta", payload: .object(["text": .string("partial")]), to: c)
        XCTAssertTrue(replies.isEmpty)
        let completed = JSON.object(["text": .string("background answer")])
        store.applyEvent(type: "message.complete", payload: completed, to: c)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.0, c.key)
        XCTAssertEqual(replies.first?.1, "a")
        XCTAssertEqual(replies.first?.2, "background answer")
        XCTAssertTrue(c.unread)
        store.applyEvent(type: "message.complete", payload: completed, to: c)
        XCTAssertEqual(replies.count, 1, "Duplicate completions must not notify again")

        c.begin("failed")
        store.applyEvent(type: "message.complete", payload: .object(["error": .string("failed")]), to: c)
        XCTAssertEqual(replies.count, 1)
        c.begin("stream failed")
        store.applyEvent(type: "error", payload: .object(["message": .string("failed")]), to: c)
        XCTAssertEqual(replies.count, 1)
    }

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

    func testCodeFontChangeUpdatesExistingNativeViewAndMeasurements() throws {
        let code = String(repeating: "let answer = 42; ", count: 20) + "\nprint(answer)"
        let hosting = NSHostingView(rootView: CodeContentView(code: code, fontSize: 12.5))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 200)
        hosting.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let text = try XCTUnwrap(editor(in: hosting))
        let oldWidth = text.frame.width
        let oldHeight = text.frame.height
        hosting.rootView = CodeContentView(code: code, fontSize: 22)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor(in: hosting) === text)
        XCTAssertEqual(text.font?.pointSize, 22)
        XCTAssertEqual(text.string, code)
        XCTAssertGreaterThan(text.frame.width, oldWidth)
        XCTAssertGreaterThan(text.frame.height, oldHeight)
        XCTAssertEqual(CodeContentView.viewportHeight(for: String(repeating: "line\n", count: 500), fontSize: 22), 360)
    }

    func testComposerFontChangePreservesDraftAndSelection() throws {
        let draft = "中文草稿，继续编辑"
        let hosting = NSHostingView(rootView: ComposerTextView(text: .constant(draft), enabled: true, fontSize: 13.5, onSubmit: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        hosting.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> SubmitTextView? {
            if let text = view as? SubmitTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let text = try XCTUnwrap(editor(in: hosting))
        let selection = NSRange(location: 2, length: 2)
        text.setSelectedRange(selection)
        hosting.rootView = ComposerTextView(text: .constant(draft), enabled: true, fontSize: 24, onSubmit: {})
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor(in: hosting) === text)
        XCTAssertEqual(text.font?.pointSize, 24)
        XCTAssertEqual(text.string, draft)
        XCTAssertEqual(text.selectedRange(), selection)
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

    func testToolLogLayoutRemainsBoundedDuringResizeAndCollapse() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let details = String(repeating: "long log entry ", count: 1_000) + "\n" + String(repeating: "line\n", count: 500)
        func row(_ expanded: Bool, revision: Int) -> some View {
            ToolCallRow(title: "terminal", isComplete: true, details: details,
                        isExpanded: expanded).id(revision)
        }
        let hosting = NSHostingView(rootView: row(true, revision: 0))
        window.contentView = hosting
        func logs(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).flatMap { $0.documentView is NSTextView ? $0 : nil }
            return (own.map { [$0] } ?? []) + view.subviews.flatMap { logs(in: $0) }
        }
        let start = Date()
        for revision in 0..<12 {
            let expanded = revision.isMultiple(of: 2)
            hosting.frame = NSRect(x: 0, y: 0, width: expanded ? 320 : 900, height: 600)
            hosting.rootView = row(expanded, revision: revision)
            hosting.layoutSubtreeIfNeeded()
            let visibleLogs = logs(in: hosting)
            if expanded {
                XCTAssertEqual(visibleLogs.count, 1)
                XCTAssertLessThanOrEqual(visibleLogs.first?.frame.height ?? .infinity, 360)
                XCTAssertTrue((visibleLogs.first?.documentView?.frame.width ?? 0) > 900)
            } else {
                XCTAssertTrue(visibleLogs.isEmpty, "Collapsing must remove the log viewport")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
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
    func testUnconfirmedMessageCannotBeRecoveredWhileServerIsRunning() {
        let c = Conversation(key: ConversationKey(service: "local", profile: "a", storedID: "stored"))
        c.begin("unconfirmed"); c.uncertain = true
        c.snapshot(.object(["session_id": .string("runtime"), "running": .bool(true)]), history: [])
        XCTAssertTrue(c.uncertain)
        XCTAssertNil(c.recoverableMessageID)
        XCTAssertNil(c.recoverUnconfirmedMessage())
    }

    func testUnconfirmedMessageRequiresAuthoritativeHistoryForRecovery() {
        let c = Conversation(key: ConversationKey(service: "local", profile: "a", storedID: "stored"))
        c.begin("unconfirmed"); c.uncertain = true
        c.snapshot(.object(["session_id": .string("runtime"), "messages": .array([])]))
        XCTAssertTrue(c.uncertain)
        XCTAssertNil(c.recoverableMessageID)
        XCTAssertNil(c.recoverUnconfirmedMessage())
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        var found: NSScrollView?
        func traverse(_ v: NSView) {
            if let s = v as? NSScrollView { found = s; return }
            for sub in v.subviews { traverse(sub) }
        }
        traverse(hosting)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.drawsBackground, false)
        XCTAssertEqual(found?.contentView.drawsBackground, false)
        XCTAssertEqual(found?.scrollerStyle, .overlay)
    }

    func testCleanScrollStyleOnlyChangesTheSelectedScrollView() {
        let unrelated = NSScrollView()
        unrelated.drawsBackground = true; unrelated.backgroundColor = .red
        unrelated.contentView.drawsBackground = true; unrelated.contentView.backgroundColor = .blue
        unrelated.scrollerStyle = .legacy
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        CleanScrollViewStyle.configure(scroll)
        XCTAssertTrue(unrelated.drawsBackground)
        XCTAssertEqual(unrelated.backgroundColor, .blue)
        XCTAssertTrue(unrelated.contentView.drawsBackground)
        XCTAssertEqual(unrelated.contentView.backgroundColor, .blue)
        XCTAssertEqual(unrelated.scrollerStyle, .legacy)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertFalse(scroll.drawsBackground)
        XCTAssertEqual(scroll.backgroundColor, .clear)
        XCTAssertFalse(scroll.contentView.drawsBackground)
        XCTAssertEqual(scroll.contentView.backgroundColor, .clear)
    }
}

