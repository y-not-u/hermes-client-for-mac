import Foundation

/// Foundation follows CommonMark's punctuation flanking rules, which leave
/// Chinese phrases such as **适合怎么放：**若… literal. Add temporary letters
/// inside paired strong delimiters so those boundaries parse consistently.
enum InlineMarkdown {
    static func parse(_ source: String) -> AttributedString {
        let characters = Array(source)
        var boundaries: [Int] = []
        var opener: Int?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == "`" {
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                let count = index - start
                var cursor = index
                var end: Int?
                while cursor < characters.count {
                    if characters[cursor] != "`" { cursor += 1; continue }
                    let runStart = cursor
                    while cursor < characters.count, characters[cursor] == "`" { cursor += 1 }
                    if cursor - runStart == count { end = cursor; break }
                }
                if let end { index = end }
                continue
            }
            // Link destinations (including nested parentheses) and autolinks
            // contain literal stars, not emphasis delimiters.
            if character == "(", index > 0, characters[index - 1] == "]" {
                var depth = 1
                index += 1
                while index < characters.count, depth > 0 {
                    if characters[index] == "\\" { index += 2; continue }
                    if characters[index] == "(" { depth += 1 }
                    if characters[index] == ")" { depth -= 1 }
                    index += 1
                }
                continue
            }
            if character == "<", let end = characters[index...].firstIndex(of: ">") {
                index = end + 1
                continue
            }
            guard character == "*" else { index += 1; continue }
            let start = index
            while index < characters.count, characters[index] == "*" { index += 1 }
            // Leave single/triple emphasis and thematic breaks to Foundation.
            guard index - start == 2 else { continue }
            if let opening = opener, start > opening + 2,
               !characters[start - 1].isWhitespace {
                boundaries.append(opening + 2)
                boundaries.append(start)
                opener = nil
            } else if index < characters.count, !characters[index].isWhitespace {
                opener = start
            }
        }

        guard !boundaries.isEmpty else { return nativeParse(source) }
        var marker = "HermesStrongBoundary"
        while source.contains(marker) { marker += "X" }
        var normalized = ""
        var boundaryIndex = 0
        for index in characters.indices {
            if boundaryIndex < boundaries.count, boundaries[boundaryIndex] == index {
                normalized += marker
                boundaryIndex += 1
            }
            normalized.append(characters[index])
        }
        var result = nativeParse(normalized)
        // Removing the temporary letters from the attributed result preserves
        // native links, nested emphasis and code attributes, without hidden text.
        while let range = result.range(of: marker) {
            result.removeSubrange(range)
        }
        return result
    }

    private static func nativeParse(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }
}
