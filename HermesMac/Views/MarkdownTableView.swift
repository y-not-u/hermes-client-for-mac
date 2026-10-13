import SwiftUI
import AppKit

struct MarkdownTableView: View {
    let table: MarkdownTable
    let fontSize: CGFloat

    private var columnWidths: [CGFloat] {
        table.headers.indices.map { column in
            let values = [table.headers[column]] + table.rows.map { $0[column] }
            let width = values.enumerated().map { index, value in
                let content = (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
                let measured = NSMutableAttributedString(attributedString: NSAttributedString(content))
                measured.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize, weight: index == 0 ? .semibold : .regular), range: NSRange(location: 0, length: measured.length))
                return ceil(measured.size().width)
            }.max() ?? 0
            return min(320, max(64, width + 4))
        }
    }

    var body: some View {
        let widths = columnWidths
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                row(table.headers, widths: widths, header: true)
                    .background(Color.secondary.opacity(0.09))
                ForEach(table.rows.indices, id: \.self) { index in
                    row(table.rows[index], widths: widths, header: false)
                        .background(Color.secondary.opacity(index.isMultiple(of: 2) ? 0.025 : 0.055))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.bottom, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private func alignment(for column: Int) -> SwiftUI.Alignment {
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(for column: Int) -> TextAlignment {
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func row(_ values: [String], widths: [CGFloat], header: Bool) -> some View {
        GridRow {
            ForEach(table.headers.indices, id: \.self) { column in
                Text((try? AttributedString(markdown: values[column], options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(values[column]))
                    .font(.system(size: fontSize, weight: header ? .semibold : .regular))
                    .multilineTextAlignment(textAlignment(for: column))
                    .frame(width: widths[column], alignment: alignment(for: column))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(header ? 0.65 : 0.3))
                .frame(height: 0.5)
        }
    }
}
