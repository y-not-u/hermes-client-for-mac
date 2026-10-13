import SwiftUI
import AppKit

struct ComposerView: View {
    @Bindable var store: AppStore
    @AppStorage(ChatTypography.key) private var fontSize = ChatTypography.defaultSize

    private var isEnabled: Bool {
        store.connected && store.current?.readOnlyReason == nil
    }

    private var isRunning: Bool { store.current?.generating == true }

    var body: some View {
        VStack(spacing: 8) {
            // Quick Command Chips
            if isEnabled && !isRunning {
                HStack(spacing: 8) {
                    QuickChip(title: "/status", description: "状态") {
                        store.draft = "/status"
                        store.submitDraft()
                    }
                    QuickChip(title: "/model", description: "模型") {
                        store.draft = "/model"
                        store.submitDraft()
                    }
                    QuickChip(title: "/profile", description: "角色") {
                        store.draft = "/profile"
                        store.submitDraft()
                    }
                    Spacer()
                }
                .padding(.horizontal, 2)
                // Keep the row's height stable while the user edits their draft.
                .opacity(store.draft.isEmpty ? 1 : 0)
                .allowsHitTesting(store.draft.isEmpty)
                .accessibilityHidden(!store.draft.isEmpty)
            }

            // Input Card
            VStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if store.draft.isEmpty {
                        Text(isEnabled ? (isRunning ? "补充要求或修改方向… (Enter 引导)" : "向 \(store.profileTitle) 发送消息… (Enter 发送)") : "当前连接不可用或处于只读状态")
                            .font(.system(size: ChatTypography.size(fontSize)))
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    ComposerTextView(text: $store.draft, enabled: isEnabled, fontSize: ChatTypography.size(fontSize)) {
                        store.submitDraft()
                    }
                    .frame(minHeight: max(38, ChatTypography.size(fontSize) + 18), maxHeight: 120)
                }

                // Bottom toolbar inside card
                HStack(alignment: .center) {
                    HStack(spacing: 5) {
                        KeyCap("Enter")
                        Text(isRunning ? "引导" : "发送")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        HStack(spacing: 2) {
                            KeyCap("Shift")
                            Text("+")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            KeyCap("Enter")
                        }
                        Text("换行")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    ModelPickerView(store: store)

                    if isRunning {
                        Button {
                            store.stopCurrent()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.88, green: 0.51, blue: 0.28))
                                    .frame(width: 28, height: 28)
                                    .shadow(color: Color(red: 0.88, green: 0.51, blue: 0.28).opacity(0.32), radius: 2.5, y: 1.2)

                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Color.white)
                                    .frame(width: 9, height: 9)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.connected)
                        .help("停止当前生成")
                    } else {
                        Button {
                            store.submitDraft()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(store.canSend ? Color.accentColor : Color.secondary.opacity(0.15))
                                    .frame(width: 28, height: 28)
                                    .shadow(color: store.canSend ? Color.accentColor.opacity(0.35) : Color.clear, radius: 3, y: 1.5)

                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(store.canSend ? Color.white : Color.secondary.opacity(0.6))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canSend)
                        .help(store.canSend ? "发送消息 (Enter)" : "无法发送")
                    }
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        !store.draft.isEmpty ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }
}

private struct QuickChip: View {
    let title: String
    let description: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                isHovered ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(isHovered ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    var fontSize: CGFloat = CGFloat(ChatTypography.defaultSize)
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller = TransparentOverlayScroller()
        scroll.drawsBackground = false

        let view = SubmitTextView()
        view.isRichText = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: fontSize)
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.onSubmit = onSubmit
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = view.documentView as? SubmitTextView else { return }
        view.autohidesScrollers = true
        view.scrollerStyle = .overlay
        view.drawsBackground = false
        // Never replace marked text while an IME owns the composition.
        if editor.string != text && !editor.hasMarkedText() {
            editor.string = text
        }
        if editor.font?.pointSize != fontSize {
            editor.font = .systemFont(ofSize: fontSize)
        }
        editor.isEditable = enabled
        editor.onSubmit = onSubmit
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView {
                parent.text = editor.string
            }
        }
    }
}

final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) && !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}
