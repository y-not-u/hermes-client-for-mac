import SwiftUI
import AppKit

// MARK: - Dedicated Transparent Overlay Scroller

/// An NSScroller subclass that forces overlay appearance and completely transparent track.
public final class TransparentOverlayScroller: NSScroller {
    public override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        self.scrollerStyle = .overlay
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.scrollerStyle = .overlay
    }

    public override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Keep track slot 100% transparent.
    }

    public override func draw(_ dirtyRect: NSRect) {
        self.drawKnob()
    }
}

// MARK: - SwiftUI ScrollView Introspection & Modifier

public struct CleanScrollBarsModifier: ViewModifier {
    var preferOverlay: Bool = true

    public func body(content: Content) -> some View {
        content
            .background(ScrollViewConfigurator(preferOverlay: preferOverlay))
    }
}

private struct ScrollViewConfigurator: NSViewRepresentable {
    let preferOverlay: Bool

    @MainActor final class Coordinator {
        private var pending: (() -> Void)?
        private var scheduled = false
        private var disposed = false

        func schedule(_ action: @escaping () -> Void) {
            guard !disposed else { return }
            pending = action
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.disposed else { return }
                self.scheduled = false
                let action = self.pending
                self.pending = nil
                action?()
            }
        }

        func dispose() { disposed = true; pending = nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.schedule { [weak view] in
            if let view { configure(from: view) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.schedule { [weak nsView] in
            if let nsView { configure(from: nsView) }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dispose()
    }

    private func configure(from view: NSView) {
        guard let scrollView = findEnclosingScrollView(from: view) else { return }
        CleanScrollViewStyle.configure(scrollView, preferOverlay: preferOverlay)
    }

    private func findEnclosingScrollView(from view: NSView) -> NSScrollView? {
        // Prefer the actual enclosing scroll view over nested code/tool scroll views.
        var current = view.superview
        while let ancestor = current {
            if let scroll = ancestor as? NSScrollView { return scroll }
            current = ancestor.superview
        }
        // A SwiftUI background can be a sibling of its ScrollView rather than its child.
        current = view
        while let v = current {
            if let superview = v.superview {
                for sibling in superview.subviews where sibling !== v {
                    if let scroll = findScrollViewInHierarchy(sibling) { return scroll }
                }
            }
            current = v.superview
        }
        return nil
    }

    private func findScrollViewInHierarchy(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView {
            return scroll
        }
        for sub in view.subviews {
            if let scroll = findScrollViewInHierarchy(sub) {
                return scroll
            }
        }
        return nil
    }
}

/// Changes only the explicitly selected scroll view using public AppKit APIs.
@MainActor enum CleanScrollViewStyle {
    static func configure(_ scrollView: NSScrollView, preferOverlay: Bool = true) {
        // Setting these on every SwiftUI update can invalidate layout again.
        if scrollView.drawsBackground { scrollView.drawsBackground = false }
        if scrollView.backgroundColor != .clear { scrollView.backgroundColor = .clear }
        if scrollView.contentView.drawsBackground { scrollView.contentView.drawsBackground = false }
        if scrollView.contentView.backgroundColor != .clear { scrollView.contentView.backgroundColor = .clear }
        if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
        if preferOverlay && scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if let vertical = scrollView.verticalScroller {
            if preferOverlay && vertical.scrollerStyle != .overlay {
                vertical.scrollerStyle = .overlay
            }
        }
        if let horizontal = scrollView.horizontalScroller {
            if preferOverlay && horizontal.scrollerStyle != .overlay {
                horizontal.scrollerStyle = .overlay
            }
        }
    }
}

public extension View {
    /// Configures the enclosing ScrollView with transparent view backgrounds,
    /// with autohiding and overlay style scrollers.
    func cleanScrollBars(preferOverlay: Bool = true) -> some View {
        modifier(CleanScrollBarsModifier(preferOverlay: preferOverlay))
    }
}
