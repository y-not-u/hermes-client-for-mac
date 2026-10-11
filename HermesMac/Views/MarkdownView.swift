import SwiftUI
import AppKit
struct MarkdownView: View {
    let text: String
    private var segments: [Segment] {
        var result: [Segment] = []; var body = ""; var code = false; var language = ""
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if !body.isEmpty { result.append(Segment(text: body, code: code, language: language)); body = "" }
                code.toggle(); language = code ? String(line.dropFirst(3)) : ""
            } else { body += (body.isEmpty ? "" : "\n") + line }
        }
        if !body.isEmpty { result.append(Segment(text: body, code: code, language: language)) }; return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.code {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(segment.language.isEmpty ? "代码" : segment.language).font(.caption).foregroundStyle(.secondary); Spacer(); Button("复制", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(segment.text, forType: .string) }.buttonStyle(.borderless).font(.caption) }
                        ScrollView(.horizontal) { Text(segment.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
                    }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    MarkdownTextBlock(text: segment.text).textSelection(.enabled)
                }
            }
        }
    }
    private struct Segment { let text: String; let code: Bool; let language: String }
}

/// Block layout stays native SwiftUI; inline emphasis, links and inline code use Foundation Markdown.
private struct MarkdownTextBlock: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") { inline(String(line.dropFirst(4))).font(.headline).padding(.top, 6) }
                else if line.hasPrefix("## ") { inline(String(line.dropFirst(3))).font(.title3.weight(.semibold)).padding(.top, 8) }
                else if line.hasPrefix("# ") { inline(String(line.dropFirst(2))).font(.title2.weight(.semibold)).padding(.top, 10) }
                else if line.hasPrefix("- ") || line.hasPrefix("* ") { HStack(alignment: .top, spacing: 8) { Text("•"); inline(String(line.dropFirst(2))) }.padding(.leading, 8) }
                else if line.hasPrefix("> ") { HStack(alignment: .top, spacing: 10) { Rectangle().fill(.tertiary).frame(width: 3); inline(String(line.dropFirst(2))).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true) }
                else if line == "---" || line == "***" { Divider().padding(.vertical, 6) }
                else if line.isEmpty { Color.clear.frame(height: 4) }
                else { inline(line) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}
