import SwiftUI

/// Emoji badge picker for a profile. Icons are a local preference, so the
/// caller persists the result through `AppStore.setProfileIcon`.
struct ProfileIconPicker: View {
    let title: String
    let current: String?
    let onApply: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    @FocusState private var customFocused: Bool

    private static let choices: [String] = [
        "🤖", "🧠", "🦊", "🐱", "🐶", "🐼", "🐯", "🦁",
        "🐵", "🐰", "🦉", "🐧", "🐙", "🐳", "🦄", "🐝",
        "🦋", "🌸", "🌻", "🌵", "🍀", "🌙", "⭐️", "🔥",
        "⚡️", "💧", "🌈", "🍎", "🍇", "🍩", "☕️", "🎯",
        "🎨", "🎵", "📚", "✏️", "🧩", "🛠", "🚀", "🛰",
        "🧪", "🔭", "💡", "🧭", "🎲", "🕹", "🍄", "🪐"
    ]

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("为「\(title)」选择图标")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            TextField("输入任意 emoji", text: $custom)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($customFocused)
                .onSubmit(applyCustom)
                .onChange(of: custom) { _, value in
                    // Keep a single grapheme so the badge never grows.
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count > 1 || trimmed != value { custom = trimmed.isEmpty ? "" : String(trimmed.prefix(1)) }
                }

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Self.choices, id: \.self) { emoji in
                    Button {
                        onApply(emoji)
                        dismiss()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 17))
                            .frame(width: 30, height: 30)
                            .background(
                                current == emoji ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(emoji)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("使用默认") {
                    onApply(nil)
                    dismiss()
                }
                Spacer()
                Button("应用输入") { applyCustom() }
                    .disabled(custom.first(where: { $0.isEmojiGlyph }) == nil)
                Button("取消") { dismiss() }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 288)
    }

    private func applyCustom() {
        guard let emoji = custom.first(where: { $0.isEmojiGlyph }) else { return }
        custom = String(emoji)
        onApply(String(emoji))
        dismiss()
    }
}

private extension Character {
    /// ASCII digits and `#`/`*` also report `isEmoji`, so require a symbol or a
    /// variation-selector presentation before accepting a character as an icon.
    var isEmojiGlyph: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0x2000)
        }
    }
}
