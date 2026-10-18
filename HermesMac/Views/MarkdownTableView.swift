import SwiftUI
import AppKit

// Keep parsed cells across streamed suffixes. The cache belongs to one table view
// and retains only its current cells, rather than every partial streamed value.
@MainActor final class MarkdownTableLayoutCache {
    struct CellKey: Hashable {
        let source: String
        let header: Bool
    }

    final class Cell {
        let content: AttributedString
        let measured: NSAttributedString
        let idealWidth: CGFloat
        private var heights: [CGFloat: CGFloat] = [:]

        init(source: String, header: Bool, fontSize: CGFloat) {
            content = InlineMarkdown.parse(source)
            let measured = NSMutableAttributedString(attributedString: NSAttributedString(content))
            for run in content.runs {
                let intent = run.inlinePresentationIntent ?? []
                let weight: NSFont.Weight = intent.contains(.stronglyEmphasized) ? .bold : header ? .semibold : .regular
                var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight) : NSFont.systemFont(ofSize: fontSize, weight: weight)
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                measured.addAttribute(.font, value: font, range: NSRange(run.range, in: content))
            }
            self.measured = measured
            idealWidth = ceil(measured.size().width)
        }

        func height(for width: CGFloat, fontSize: CGFloat) -> CGFloat {
            if let height = heights[width] { return height }
            let bounds = measured.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            let font = NSFont.systemFont(ofSize: fontSize)
            // Round up with a small allowance for SwiftUI's text baseline metrics.
            let height = ceil(max(bounds.height, font.ascender - font.descender + font.leading)) + 2
            heights = [width: height]
            return height
        }
    }

    struct Layout {
        let cells: [[Cell]]
        let widths: [CGFloat]
        let rowHeights: [CGFloat]
        var height: CGFloat { rowHeights.reduce(0, +) }
    }

    private var table: MarkdownTable?
    private var fontSize: CGFloat?
    private var cells: [CellKey: Cell] = [:]
    private var layout: Layout?

    func layout(for table: MarkdownTable, fontSize: CGFloat) -> Layout {
        if self.table == table, self.fontSize == fontSize, let layout { return layout }
        if self.fontSize != fontSize { cells.removeAll() }
        var retained: [CellKey: Cell] = [:]
        let rows = ([table.headers] + table.rows).enumerated().map { index, row in
            row.map { source in
                let key = CellKey(source: source, header: index == 0)
                let cell = retained[key] ?? cells[key] ?? Cell(source: source, header: index == 0, fontSize: fontSize)
                retained[key] = cell
                return cell
            }
        }
        let widths = table.headers.indices.map { column in
            min(320, max(64, (rows.map { $0[column].idealWidth }.max() ?? 0) + 4))
        }
        let heights = rows.map { row in
            (row.indices.map { row[$0].height(for: widths[$0], fontSize: fontSize) }.max() ?? 0) + 16
        }
        let layout = Layout(cells: rows, widths: widths, rowHeights: heights)
        self.table = table
        self.fontSize = fontSize
        self.cells = retained
        self.layout = layout
        return layout
    }
}

struct MarkdownTableView: View, Equatable {
    let table: MarkdownTable
    let fontSize: CGFloat
    @State private var cache = MarkdownTableLayoutCache()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.table == rhs.table && lhs.fontSize == rhs.fontSize
    }

    var body: some View {
        let layout = cache.layout(for: table, fontSize: fontSize)
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                ForEach(layout.cells.indices, id: \.self) { index in
                    row(layout.cells[index], widths: layout.widths, height: layout.rowHeights[index], header: index == 0)
                        .background(Color.secondary.opacity(index == 0 ? 0.09 : index.isMultiple(of: 2) ? 0.055 : 0.025))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        // A nested horizontal scroll view must not derive an unbounded ideal
        // height through Grid while the transcript is also laying out/scrolling.
        .frame(height: layout.height)
        .padding(.bottom, 4)
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

    private func row(_ cells: [MarkdownTableLayoutCache.Cell], widths: [CGFloat], height: CGFloat, header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(table.headers.indices, id: \.self) { column in
                Text(cells[column].content)
                    .modifier(MarkdownLinkCursor(enabled: cells[column].content.runs.contains { $0.link != nil }))
                    .font(.system(size: fontSize, weight: header ? .semibold : .regular))
                    .multilineTextAlignment(textAlignment(for: column))
                    .frame(width: widths[column], alignment: alignment(for: column))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .frame(height: height, alignment: .top)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(header ? 0.65 : 0.3))
                .frame(height: 0.5)
        }
    }
}
