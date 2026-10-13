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
    @AppStorage(ChatTypography.key) private var fontSize = ChatTypography.defaultSize
    let code: String
    let language: String

    var displayLanguage: String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "CODE" : trimmed.uppercased()
    }

    var body: some View {
        let content = CodeContentView(code: code, fontSize: ChatTypography.scaled(12.5, for: fontSize))
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
            content
                .frame(height: content.viewportHeight)
                .frame(maxWidth: .infinity)
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

// A lazy transcript must receive a finite height without asking a nested SwiftUI
// ScrollView to derive its ideal size from unwrapped text. AppKit owns scrolling;
// SwiftUI only measures the bounded viewport, independent of code line width.
struct CodeContentView: NSViewRepresentable {
    let code: String
    let fontSize: CGFloat
    let documentHeight: CGFloat
    var viewportHeight: CGFloat { min(Self.maximumHeight, documentHeight) }
    init(code: String, fontSize: CGFloat = 12.5) {
        self.code = code
        self.fontSize = fontSize
        documentHeight = Self.contentHeight(for: code, fontSize: fontSize)
    }
    static let lineSpacing: CGFloat = 3.5
    static let inset: CGFloat = 12
    static let maximumHeight: CGFloat = 360

    static func contentHeight(for code: String, fontSize: CGFloat = 12.5) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let lines = code.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return CGFloat(lines) * (lineHeight + lineSpacing) + inset * 2
    }

    static func viewportHeight(for code: String, fontSize: CGFloat = 12.5) -> CGFloat {
        min(maximumHeight, contentHeight(for: code, fontSize: fontSize))
    }

    // NSScrollView resizes NSTextView to its clip width while tiling. Keep the
    // measured unwrapped width so long lines remain reachable after resizing.
    final class UnwrappedTextView: NSTextView {
        var contentWidth: CGFloat = 0
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(NSSize(width: max(newSize.width, contentWidth), height: newSize.height))
        }
    }

    final class Coordinator {
        var renderedCode: String?
        var renderedFontSize: CGFloat?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScroller = TransparentOverlayScroller()
        scroll.verticalScroller = TransparentOverlayScroller()
        let text = UnwrappedTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.autoresizingMask = []
        text.drawsBackground = false
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.textContainerInset = NSSize(width: Self.inset, height: Self.inset)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.heightTracksTextView = false
        scroll.documentView = text
        scroll.setAccessibilityLabel("代码，可选择和滚动")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.renderedCode != code || context.coordinator.renderedFontSize != fontSize,
              let text = scroll.documentView as? UnwrappedTextView else { return }
        context.coordinator.renderedCode = code
        context.coordinator.renderedFontSize = fontSize
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Self.lineSpacing
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .paragraphStyle: paragraph,
            .foregroundColor: NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.96, alpha: 1)
        ]
        let content = NSAttributedString(string: code, attributes: attributes)
        // Measure when content or typography changes, never during SwiftUI size proposals.
        let width = ceil(content.size().width) + Self.inset * 2
        let height = documentHeight
        text.textContainer?.containerSize = NSSize(width: max(1, width - Self.inset * 2), height: CGFloat.greatestFiniteMagnitude)
        text.contentWidth = max(1, width)
        text.textStorage?.setAttributedString(content)
        text.frame = NSRect(x: 0, y: 0, width: max(1, width), height: height)
        scroll.hasVerticalScroller = height > Self.maximumHeight
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        return CGSize(width: width, height: viewportHeight)
    }
}

// MARK: - Markdown Text Block

private struct MarkdownTextBlock: View {
    @AppStorage(ChatTypography.key) private var fontSize = ChatTypography.defaultSize
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownTable.blocks(in: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .table(let table):
                    MarkdownTableView(table: table, fontSize: ChatTypography.scaled(13.5, for: fontSize))
                case .line(let line):
                    lineView(line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func lineView(_ line: String) -> some View {
        if line.hasPrefix("### ") {
            inline(String(line.dropFirst(4)))
                .font(.system(size: ChatTypography.scaled(14, for: fontSize), weight: .bold))
                .padding(.top, 6)
        } else if line.hasPrefix("## ") {
            inline(String(line.dropFirst(3)))
                .font(.system(size: ChatTypography.scaled(16, for: fontSize), weight: .bold))
                .padding(.top, 8)
        } else if line.hasPrefix("# ") {
            inline(String(line.dropFirst(2)))
                .font(.system(size: ChatTypography.scaled(18, for: fontSize), weight: .bold))
                .padding(.top, 10)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 4.5, height: 4.5)
                    .offset(y: -1)
                inline(String(line.dropFirst(2)))
                    .font(.system(size: ChatTypography.scaled(13.5, for: fontSize)))
            }
            .padding(.leading, 8)
        } else if line.hasPrefix("> ") {
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 3)
                inline(String(line.dropFirst(2)))
                    .font(.system(size: ChatTypography.scaled(13.5, for: fontSize)))
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
                .font(.system(size: ChatTypography.scaled(13.5, for: fontSize)))
                .lineSpacing(2.5)
        }
    }

    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}
