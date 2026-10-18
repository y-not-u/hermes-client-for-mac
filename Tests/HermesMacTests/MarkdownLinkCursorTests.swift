import XCTest
import SwiftUI
import AppKit
@testable import HermesMac

@MainActor final class MarkdownLinkCursorTests: XCTestCase {
    func testLinkHitTestingTracksWrappedGlyphsAndUpdatedText() throws {
        let probe = MarkdownLinkCursorProbe()
        let source = "前文 [这是很长的链接文字用于检查换行后的手形光标](https://example.com) 后文"
        func content(_ text: String) -> AnyView {
            AnyView(Text(InlineMarkdown.parse(text))
                .font(.system(size: 14))
                .modifier(MarkdownLinkCursor(enabled: true, probe: probe))
                .textSelection(.enabled)
                .frame(width: 150, height: 150))
        }
        let hosting = NSHostingView(rootView: content(source))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 150, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        func field(in view: NSView) -> NSTextField? {
            if let value = view as? NSTextField { return value }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        let textField = try XCTUnwrap(field(in: hosting))
        let text = textField.attributedStringValue
        var linkLines = Set<CGFloat>()
        for index in 0..<text.length {
            let rect = textField.accessibilityFrame(for: NSRange(location: index, length: 1))
            let point = NSPoint(x: rect.midX, y: rect.midY)
            let linked = text.attribute(.link, at: index, effectiveRange: nil) != nil
            XCTAssertEqual(probe.isLink(at: point), linked, "Character \(index)")
            if linked { linkLines.insert(rect.minY) }
        }
        XCTAssertGreaterThan(linkLines.count, 1)
        XCTAssertFalse(probe.isLink(at: NSPoint(x: -1000, y: -1000)))

        hosting.rootView = content("更新后的普通文字")
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let updated = try XCTUnwrap(field(in: hosting))
        let rect = updated.accessibilityFrame(for: NSRange(location: 0, length: 1))
        XCTAssertFalse(probe.isLink(at: NSPoint(x: rect.midX, y: rect.midY)))
    }
}
