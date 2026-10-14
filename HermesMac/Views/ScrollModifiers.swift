import SwiftUI
import AppKit

// MARK: - Global NSScrollView & NSScroller Background Optimization

extension NSScrollView {
    private static let swizzleScrollViewOnce: Void = {
        if let origDrawsBg = class_getInstanceMethod(NSScrollView.self, #selector(getter: drawsBackground)),
           let swizDrawsBg = class_getInstanceMethod(NSScrollView.self, #selector(hermes_drawsBackground)) {
            method_exchangeImplementations(origDrawsBg, swizDrawsBg)
        }

        if let origBgColor = class_getInstanceMethod(NSScrollView.self, #selector(getter: backgroundColor)),
           let swizBgColor = class_getInstanceMethod(NSScrollView.self, #selector(hermes_backgroundColor)) {
            method_exchangeImplementations(origBgColor, swizBgColor)
        }
    }()

    public static func enableCleanScrollViews() {
        _ = swizzleScrollViewOnce
    }

    @objc dynamic func hermes_drawsBackground() -> Bool {
        return false
    }

    @objc dynamic func hermes_backgroundColor() -> NSColor {
        return .clear
    }
}

extension NSClipView {
    private static let swizzleClipViewOnce: Void = {
        if let origDrawsBg = class_getInstanceMethod(NSClipView.self, #selector(getter: drawsBackground)),
           let swizDrawsBg = class_getInstanceMethod(NSClipView.self, #selector(hermes_clip_drawsBackground)) {
            method_exchangeImplementations(origDrawsBg, swizDrawsBg)
        }
        if let origBgColor = class_getInstanceMethod(NSClipView.self, #selector(getter: backgroundColor)),
           let swizBgColor = class_getInstanceMethod(NSClipView.self, #selector(hermes_clip_backgroundColor)) {
            method_exchangeImplementations(origBgColor, swizBgColor)
        }
    }()

    public static func enableCleanClipViews() {
        _ = swizzleClipViewOnce
    }

    @objc dynamic func hermes_clip_drawsBackground() -> Bool {
        return false
    }

    @objc dynamic func hermes_clip_backgroundColor() -> NSColor {
        return .clear
    }
}

// MARK: - NSScrollerImp Swizzle (Modern Layer-Backed Scrollers)

extension NSObject {
    @objc func hermes_scrollerImp_displayLayer(_ layer: CALayer) {
        if let trackLayer = self.value(forKey: "trackLayer") as? CALayer, layer == trackLayer {
            layer.contents = nil
            layer.backgroundColor = nil
            layer.opacity = 0
            layer.isHidden = true
            return
        }
        self.hermes_scrollerImp_displayLayer(layer)
    }
}

extension NSScroller {
    private static let swizzleScrollerOnce: Void = {
        // 1. Swizzle NSScrollerImp displayLayer: so CALayer track backing never renders CoreUI gray/white background
        if let impCls = NSClassFromString("NSScrollerImp") {
            let displaySel = NSSelectorFromString("displayLayer:")
            let swizDisplaySel = #selector(NSObject.hermes_scrollerImp_displayLayer(_:))
            if let orig = class_getInstanceMethod(impCls, displaySel),
               let swiz = class_getInstanceMethod(NSObject.self, swizDisplaySel) {
                class_addMethod(impCls, swizDisplaySel, method_getImplementation(swiz), method_getTypeEncoding(swiz))
                if let newSwiz = class_getInstanceMethod(impCls, swizDisplaySel) {
                    method_exchangeImplementations(orig, newSwiz)
                }
            }
        }

        // 2. Swizzle drawKnobSlot(in:highlight:) for legacy non-layer-backed drawing
        let originalSlotSel = #selector(drawKnobSlot(in:highlight:))
        let swizzledSlotSel = #selector(hermes_drawKnobSlot(in:highlight:))
        if let origSlot = class_getInstanceMethod(NSScroller.self, originalSlotSel),
           let swizSlot = class_getInstanceMethod(NSScroller.self, swizzledSlotSel) {
            method_exchangeImplementations(origSlot, swizSlot)
        }

        // 3. Swizzle draw(_:) to only paint the knob and never paint the track slot
        let origDrawSel = #selector(draw(_:))
        let swizDrawSel = #selector(hermes_drawRect(_:))
        if let origDraw = class_getInstanceMethod(NSScroller.self, origDrawSel),
           let swizDraw = class_getInstanceMethod(NSScroller.self, swizDrawSel) {
            method_exchangeImplementations(origDraw, swizDraw)
        }
    }()

    /// Enable transparent scrollbar track and view backgrounds globally so that all
    /// scroller backgrounds seamlessly inherit the parent container's background color without white/gray bands.
    public static func enableCleanTrackBackground() {
        _ = swizzleScrollerOnce
        NSScrollView.enableCleanScrollViews()
        NSClipView.enableCleanClipViews()
    }

    @objc dynamic func hermes_drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Do not draw any track background!
    }

    @objc dynamic func hermes_drawRect(_ dirtyRect: NSRect) {
        // Only draw the knob, skipping track background drawing completely.
        self.drawKnob()
    }
}

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
            cleanScrollerLayers(vertical)
        }
        if let horizontal = scrollView.horizontalScroller {
            if preferOverlay && horizontal.scrollerStyle != .overlay {
                horizontal.scrollerStyle = .overlay
            }
            cleanScrollerLayers(horizontal)
        }
    }

    private func cleanScrollerLayers(_ scroller: NSScroller) {
        if let imp = scroller.value(forKey: "scrollerImp") as? NSObject,
           let trackLayer = imp.value(forKey: "trackLayer") as? CALayer {
            if trackLayer.contents != nil { trackLayer.contents = nil }
            if trackLayer.backgroundColor != nil { trackLayer.backgroundColor = nil }
            if trackLayer.opacity != 0 { trackLayer.opacity = 0 }
            if !trackLayer.isHidden { trackLayer.isHidden = true }
        }
    }

    private func findEnclosingScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let v = current {
            if let scroll = v as? NSScrollView {
                return scroll
            }
            if let superview = v.superview {
                for sibling in superview.subviews {
                    if let scroll = findScrollViewInHierarchy(sibling) {
                        return scroll
                    }
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

public extension View {
    /// Configures the enclosing ScrollView to have transparent track backgrounds matching its parent container,
    /// with autohiding and overlay style scrollers.
    func cleanScrollBars(preferOverlay: Bool = true) -> some View {
        modifier(CleanScrollBarsModifier(preferOverlay: preferOverlay))
    }
}
