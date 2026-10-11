import SwiftUI
import AppKit

struct ComposerView: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(spacing: 8) {
            ComposerTextView(text: $store.draft, enabled: store.connected && store.current?.readOnlyReason == nil) { store.submitDraft() }
                .frame(minHeight: 60, maxHeight: 130)
            HStack {
                Text("Enter 发送 · Shift+Enter 换行").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if store.current?.generating == true {
                    Button("停止", systemImage: "stop.fill") { store.stopCurrent() }.disabled(!store.connected)
                }
                Button("发送", systemImage: "arrow.up") { store.submitDraft() }.buttonStyle(.borderedProminent).disabled(!store.canSend)
            }
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(20)
    }
}
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let onSubmit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = SubmitTextView(); view.isRichText = false; view.drawsBackground = false; view.font = .systemFont(ofSize: 14)
        view.textContainerInset = NSSize(width: 4, height: 6); view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator; view.onSubmit = onSubmit; scroll.documentView = view; return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = view.documentView as? SubmitTextView else { return }
        // Never replace marked text while an IME owns the composition.
        if editor.string != text && !editor.hasMarkedText() { editor.string = text }
        editor.isEditable = enabled; editor.onSubmit = onSubmit
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { parent.text = editor.string } }
    }
}
final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) && !hasMarkedText() { onSubmit?(); return }
        super.keyDown(with: event)
    }
}
