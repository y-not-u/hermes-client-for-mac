import Foundation

enum MarkdownSegment: Equatable {
    case text(String)
    case code(String, language: String)
    case image(String)
}

enum MediaDirective {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
    private static let tags = try! NSRegularExpression(
        pattern: #"(?<!\S)MEDIA:\s*(?:"([^"]+)"|'([^']+)'|`([^`]+)`|((?:/|~/)[^\s`<>"']+))"#
    )
    private static let inlineCode = try! NSRegularExpression(pattern: #"`+[^`]*`+"#)

    /// Only outbound image directives are promoted. Code and quoted examples stay text.
    static func segments(_ text: String, renderMedia: Bool) -> [MarkdownSegment] {
        var result: [MarkdownSegment] = []
        var buffer: [String] = []
        var fence: String?
        var fenceLength = 0
        var language = ""
        var seen: Set<String> = []
        func flush() {
            guard !buffer.isEmpty else { return }
            let value = buffer.joined(separator: "\n")
            result.append(fence == nil ? .text(value) : .code(value, language: language))
            buffer.removeAll()
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.first.map(String.init) ?? ""
            let count = trimmed.prefix(while: { String($0) == marker }).count
            if (marker == "`" || marker == "~"), count >= 3 {
                if fence == nil {
                    flush(); fence = marker; fenceLength = count
                    language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                    continue
                } else if fence == marker, count >= fenceLength,
                          trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    flush(); fence = nil; language = ""; continue
                }
            }
            guard fence == nil, renderMedia, !trimmed.hasPrefix(">"), !line.hasPrefix("    "), !line.hasPrefix("\t") else {
                buffer.append(line); continue
            }
            let source = line as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            let codeRanges = inlineCode.matches(in: line, range: fullRange).map(\.range)
            var cursor = 0
            for match in tags.matches(in: line, range: fullRange) {
                guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                let path = (1...4).first(where: { match.range(at: $0).location != NSNotFound })
                    .map { source.substring(with: match.range(at: $0)) } ?? ""
                let ext = (path as NSString).pathExtension.lowercased()
                guard (path.hasPrefix("/") || path.hasPrefix("~/")), imageExtensions.contains(ext) else { continue }
                let before = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if !before.trimmingCharacters(in: .whitespaces).isEmpty { buffer.append(before) }
                flush()
                if seen.insert(path).inserted { result.append(.image(path)) }
                cursor = NSMaxRange(match.range)
            }
            let remainder = source.substring(from: cursor)
            if cursor == 0 || !remainder.trimmingCharacters(in: .whitespaces).isEmpty { buffer.append(remainder) }
        }
        flush()
        return result
    }
}

struct RemoteImageRequest: Hashable, Sendable {
    let conversation: ConversationKey
    let messageID: String
    let path: String
    var filename: String { (path as NSString).lastPathComponent }
}
