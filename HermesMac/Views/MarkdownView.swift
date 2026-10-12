import SwiftUI
import AppKit

struct MarkdownView: View {
    let text: String
    var media: MediaPresentation? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MediaDirective.segments(text, renderMedia: media != nil).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                case .text(let text):
                    MarkdownTextBlock(text: text)
                        .textSelection(.enabled)
                case .image(let path):
                    if let media {
                        let request = RemoteImageRequest(conversation: media.conversation, messageID: media.messageID, path: path)
                        RemoteImageView(request: request, store: media.store, preview: media.preview)
                            .id(request)
                    }
                }
            }
        }
    }
}

struct MediaPresentation {
    let conversation: ConversationKey
    let messageID: String
    let store: AppStore
    let preview: (RemoteImageFile, String) -> Void
}

// MARK: - Modern Developer Code Block

private struct CodeBlockView: View {
    let code: String
    let language: String

    var displayLanguage: String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "CODE" : trimmed.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 0.65, green: 0.70, blue: 0.78))

                    Text(displayLanguage)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.75, green: 0.80, blue: 0.88))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                Spacer()

                CopyButton(text: code, labelText: "复制", isDark: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 0.15, green: 0.16, blue: 0.19))

            // Code Content
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(3.5)
                    .foregroundStyle(Color(red: 0.92, green: 0.94, blue: 0.96))
                    .padding(12)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
            }
            .cleanScrollBars()
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.10, green: 0.11, blue: 0.13))
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1.5)
    }
}

// MARK: - Markdown Text Block

private struct MarkdownTextBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") {
                    inline(String(line.dropFirst(4)))
                        .font(.system(size: 14, weight: .bold))
                        .padding(.top, 6)
                } else if line.hasPrefix("## ") {
                    inline(String(line.dropFirst(3)))
                        .font(.system(size: 16, weight: .bold))
                        .padding(.top, 8)
                } else if line.hasPrefix("# ") {
                    inline(String(line.dropFirst(2)))
                        .font(.system(size: 18, weight: .bold))
                        .padding(.top, 10)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(Color.primary.opacity(0.6))
                            .frame(width: 4.5, height: 4.5)
                            .offset(y: -1)
                        inline(String(line.dropFirst(2)))
                            .font(.system(size: 13.5))
                    }
                    .padding(.leading, 8)
                } else if line.hasPrefix("> ") {
                    HStack(alignment: .top, spacing: 10) {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: 3)
                        inline(String(line.dropFirst(2)))
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if line == "---" || line == "***" {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.5))
                        .frame(height: 1)
                        .padding(.vertical, 6)
                } else if line.isEmpty {
                    Color.clear.frame(height: 4)
                } else {
                    inline(line)
                        .font(.system(size: 13.5))
                        .lineSpacing(2.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}
