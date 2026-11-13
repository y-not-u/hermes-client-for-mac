import SwiftUI

/// Emoji picker for a profile. Icons are a local preference, so the caller
/// persists the result through `AppStore.setProfileIcon`.
///
/// The full catalog comes from `EmojiCatalog` (gemoji-derived); the top row is
/// a quick-access strip, below it a searchable, scrollable category grid.
struct ProfileIconPicker: View {
    let title: String
    let current: String?
    let onApply: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    @State private var query = ""
    @State private var category: String?
    @FocusState private var customFocused: Bool

    private static let recent: [String] = [
        "🤖", "🧠", "🦊", "🐱", "🐶", "🐼", "🚀", "⭐️",
        "🔥", "💡", "🎯", "🧩", "🎨", "🧪", "🪐", "🍄"
    ]

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 8)
    private static let categoryOrder = EmojiCatalog.categories

    private var searchResults: [EmojiCatalog.Entry] {
        EmojiCatalog.search(query)
    }

    private var visibleEntries: [EmojiCatalog.Entry] {
        let base = searchResults
        guard let category, query.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        return base.filter { $0.category == category }
    }

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

            TextField("筛选（如：猫、star、rocket）", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        grid(Self.recent, header: "常用")
                        Divider()
                    }

                    categoryBar

                    if visibleEntries.isEmpty {
                        Text("没有匹配的 emoji，可直接在上方输入框粘贴任意 emoji")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(Package.group(visibleEntries, by: Self.categoryOrder), id: \.category) { group in
                            grid(group.entries.map(\.emoji), header: group.category)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 330)

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

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Self.categoryOrder, id: \.self) { name in
                    Button {
                        category = (category == name) ? nil : name
                    } label: {
                        Text(name)
                            .font(.system(size: 11))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                category == name ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private func grid(_ emojis: [String], header: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(emojis, id: \.self) { emoji in
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
        }
    }

    private func applyCustom() {
        guard let emoji = custom.first(where: { $0.isEmojiGlyph }) else { return }
        custom = String(emoji)
        onApply(String(emoji))
        dismiss()
    }
}

private enum Package {
    /// Group entries by the fixed category order, preserving the catalog order
    /// inside each group.
    static func group(_ entries: [EmojiCatalog.Entry], by order: [String]) -> [(category: String, entries: [EmojiCatalog.Entry])] {
        var buckets: [String: [EmojiCatalog.Entry]] = [:]
        for entry in entries { buckets[entry.category, default: []].append(entry) }
        return order.compactMap { category in
            guard let list = buckets[category], !list.isEmpty else { return nil }
            return (category, list)
        }
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
