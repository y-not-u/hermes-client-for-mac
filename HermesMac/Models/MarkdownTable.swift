import Foundation

enum MarkdownTextBlockContent: Equatable {
    case line(String)
    case table(MarkdownTable)
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }
    let headers: [String]
    let alignments: [Alignment]
    let rows: [[String]]

    /// Called only on text segments, after fenced code has been extracted.
    static func blocks(in text: String) -> [MarkdownTextBlockContent] {
        let lines = text.components(separatedBy: "\n")
        var result: [MarkdownTextBlockContent] = []
        var index = 0
        while index < lines.count {
            guard index + 1 < lines.count,
                  let headers = cells(in: lines[index]),
                  let separators = cells(in: lines[index + 1]),
                  headers.count == separators.count,
                  let alignments = alignments(for: separators) else {
                result.append(.line(lines[index]))
                index += 1
                continue
            }
            index += 2
            var rows: [[String]] = []
            while index < lines.count, let values = cells(in: lines[index]) {
                // GFM pads missing cells and ignores cells beyond the header.
                rows.append(Array((values + Array(repeating: "", count: headers.count)).prefix(headers.count)))
                index += 1
            }
            result.append(.table(MarkdownTable(headers: headers, alignments: alignments, rows: rows)))
        }
        return result
    }

    private static func alignments(for cells: [String]) -> [Alignment]? {
        var result: [Alignment] = []
        for cell in cells {
            var marker = cell[...]
            let left = marker.first == ":"
            let right = marker.last == ":"
            if left { marker = marker.dropFirst() }
            if right && !marker.isEmpty { marker = marker.dropLast() }
            guard !marker.isEmpty, marker.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : right ? .trailing : .leading)
        }
        return result
    }

    private static func cells(in line: String) -> [String]? {
        let source = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !line.hasPrefix("    "), !line.hasPrefix("\t") else { return nil }
        var cells: [String] = []
        var value = ""
        var escaped = false
        var hasDelimiter = false
        for character in source {
            if escaped {
                // Keep Markdown escapes except for escaped table delimiters.
                if character != "|" { value.append("\\") }
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(value.trimmingCharacters(in: .whitespaces))
                value = ""
                hasDelimiter = true
            } else {
                value.append(character)
            }
        }
        if escaped { value.append("\\") }
        cells.append(value.trimmingCharacters(in: .whitespaces))
        guard hasDelimiter else { return nil }
        if source.first == "|" { cells.removeFirst() }
        if cells.last == "", source.last == "|", !escaped {
            // An escaped trailing pipe is part of the last nonempty cell.
            cells.removeLast()
        }
        return cells.isEmpty ? nil : cells
    }
}
