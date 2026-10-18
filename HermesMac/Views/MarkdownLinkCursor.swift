import SwiftUI
import AppKit

/// Keep SwiftUI's selectable Text and native link actions; use its AppKit text
/// accessibility geometry to identify the actual link under the pointer.
@MainActor struct MarkdownLinkCursor: ViewModifier {
    let enabled: Bool
    @State private var probe: MarkdownLinkCursorProbe
    @State private var hoveringLink = false

    init(enabled: Bool, probe: MarkdownLinkCursorProbe? = nil) {
        self.enabled = enabled
        _probe = State(initialValue: probe ?? MarkdownLinkCursorProbe())
    }

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .background(MarkdownLinkCursorReader(probe: probe))
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        let isLink = probe.isLink(at: NSEvent.mouseLocation)
                        if isLink {
                            NSCursor.pointingHand.set()
                        } else if hoveringLink {
                            NSCursor.iBeam.set()
                        }
                        hoveringLink = isLink
                    case .ended:
                        if hoveringLink { NSCursor.arrow.set() }
                        hoveringLink = false
                    }
                }
        } else {
            content
        }
    }
}

@MainActor final class MarkdownLinkCursorProbe {
    weak var view: NSView?
    private weak var cachedField: NSTextField?
    private var cachedText: NSAttributedString?
    private var cachedBounds = NSRect.zero
    private var cachedLinkRects: [NSRect] = []

    func isLink(at screenPoint: NSPoint) -> Bool {
        guard let view, let window = view.window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = view.convert(windowPoint, from: nil)
        guard view.bounds.contains(localPoint) else { return false }
        // SwiftUI may add hosting containers. Stop at the nearest ancestor with
        // a selectable text field at this point, without depending on private types.
        var ancestor = view.superview
        while let container = ancestor {
            if let field = textField(in: container, at: windowPoint) {
                let point = field.convert(windowPoint, from: nil)
                return linkRects(in: field).contains { $0.contains(point) }
            }
            ancestor = container.superview
        }
        return false
    }

    private func linkRects(in field: NSTextField) -> [NSRect] {
        let text = field.attributedStringValue
        if cachedField === field, cachedBounds == field.bounds,
           let cachedText, text.isEqual(to: cachedText) { return cachedLinkRects }
        guard let window = field.window else { return [] }
        var rects: [NSRect] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { link, range, _ in
            guard link != nil else { return }
            // Per-character geometry handles wrapped links without turning the
            // empty area between lines into a clickable-looking region.
            for index in range.location..<NSMaxRange(range) {
                let screenRect = field.accessibilityFrame(for: NSRange(location: index, length: 1))
                guard !screenRect.isEmpty else { continue }
                rects.append(field.convert(window.convertFromScreen(screenRect), from: nil))
            }
        }
        cachedField = field
        cachedBounds = field.bounds
        cachedText = text.copy() as? NSAttributedString
        cachedLinkRects = rects
        return rects
    }

    private func textField(in view: NSView, at windowPoint: NSPoint) -> NSTextField? {
        guard !view.isHidden, view.bounds.contains(view.convert(windowPoint, from: nil)) else { return nil }
        if let field = view as? NSTextField { return field }
        for child in view.subviews.reversed() {
            if let field = textField(in: child, at: windowPoint) { return field }
        }
        return nil
    }
}

private struct MarkdownLinkCursorReader: NSViewRepresentable {
    let probe: MarkdownLinkCursorProbe

    func makeNSView(context: Context) -> NSView {
        let view = CursorProbeView()
        probe.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        probe.view = view
    }

    private final class CursorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
