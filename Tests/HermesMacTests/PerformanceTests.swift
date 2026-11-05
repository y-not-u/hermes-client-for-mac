import XCTest
import SwiftUI
import AppKit
@testable import HermesMac

@MainActor final class PerformanceTests: XCTestCase {
    func testTranscriptResizePreservesReadingPositionAndStreamingFollow() async throws {
        _ = NSApplication.shared
        let name = "HermesResizeTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStore(local: LocalState(defaults: defaults))
        store.selectedProfile = "fixture"
        store.selectedSession = "resize"
        let key = try XCTUnwrap(store.currentKey)
        let conversation = Conversation(key: key)
        conversation.messages = (0..<12).map { index in
            Message(id: "reply-\(index)", role: "assistant",
                    text: String(repeating: "调整窗口时保留阅读位置，回复正文应该正常换行。\n", count: 4))
        }
        store.conversations[key] = conversation
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChatView(store: store))
        window.orderBack(nil)
        defer { window.close() }
        await settle(window)
        let scroll = try XCTUnwrap(scrollViews(in: try XCTUnwrap(window.contentView))
            .max { $0.bounds.height < $1.bounds.height })
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.bounds.height * 2)
        XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 5)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(window)
        conversation.generating = true
        conversation.messages[11].text += "新增回复内容。\n"
        await settle(window)
        XCTAssertLessThan(scroll.documentVisibleRect.maxY, document.bounds.maxY - 100,
                          "Streaming must not pull a reader back to the bottom")

        window.setContentSize(NSSize(width: 540, height: 560))
        await settle(window)
        XCTAssertLessThan(scroll.documentVisibleRect.maxY, document.bounds.maxY - 100)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(window)
        conversation.messages[11].text += String(repeating: "继续跟随新回复。\n", count: 5)
        await settle(window)
        XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 5,
                       "Returning to the bottom must resume following streamed text")
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    func testLongTranscriptAssemblyPerformance() {
        let conversation = Conversation(key: ConversationKey(service: "fixture", profile: "a", storedID: "long"))
        for index in 0..<1_000 {
            let user = Message(id: "user-\(index)", role: "user", text: "Question \(index)")
            conversation.messages.append(user)
            conversation.messages.append(Message(id: "reply-\(index)", role: "assistant", text: "Answer \(index)"))
            conversation.toolActivities.append(ToolActivity(id: "activity-\(index)", afterMessageID: user.id,
                tools: [ToolCall(id: "tool-\(index)", name: "read", details: "result", complete: true)]))
        }
        measure {
            for _ in 0..<10 {
                XCTAssertEqual(conversation.entries.count, 3_000)
            }
        }
    }
}
