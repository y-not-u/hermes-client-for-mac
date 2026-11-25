import Foundation

enum MarkdownSegment: Equatable {
    case text(String)
    case code(String, language: String)
    case image(String)
    /// Non-image `MEDIA:` path: no inline preview, only a user-initiated download.
    case file(String)
}

/// One parse per source revision, owned by a single mounted Markdown view.
/// Retain only the latest revision so streamed prefixes cannot fill a global cache.
final class MarkdownSegmentCache {
    private var source: String?
    private var rendersMedia = false
    private var value: [MarkdownSegment] = []

    func segments(for text: String, renderMedia: Bool) -> [MarkdownSegment] {
        if source != text || rendersMedia != renderMedia {
            value = MediaDirective.segments(text, renderMedia: renderMedia)
            source = text
            rendersMedia = renderMedia
        }
        return value
    }
}

enum MediaDirective {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
    private static let tags = try! NSRegularExpression(
        pattern: #"(?<!\S)MEDIA:\s*(?:"([^"]+)"|'([^']+)'|`([^`]+)`|((?:/|~/)[^\s`<>"']+))"#
            + #"|!\[(?:\\.|[^\[\]\\]|\[(?:\\.|[^\[\]\\])*\])*\]\(\s*"#
            + #"(?:<((?:/|~/)(?:\\.|[^<>\\])+)>|((?:/|~/)(?:\\.|[^\s()\\<>]|\((?:\\.|[^\s()\\])*\))+))"#
            + #"(?:\s+(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\((?:\\.|[^()\\])*\)))?\s*\)"#
    )
    private static let markdownEscape = try! NSRegularExpression(pattern: #"\\([\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E])"#)
    private static let inlineCode = try! NSRegularExpression(pattern: #"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)"#)

    /// Only assistant media references are promoted. Code and quoted examples stay text.
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
            guard source.range(of: "MEDIA:", options: .literal).location != NSNotFound
                    || source.range(of: "![", options: .literal).location != NSNotFound else {
                buffer.append(line); continue
            }
            let fullRange = NSRange(location: 0, length: source.length)
            let codeRanges = inlineCode.matches(in: line, range: fullRange).map(\.range)
            var cursor = 0
            for match in tags.matches(in: line, range: fullRange) {
                guard !codeRanges.contains(where: {
                    NSIntersectionRange($0, match.range).length > 0 && !NSEqualRanges(NSIntersectionRange($0, match.range), $0)
                }) else { continue }
                guard let group = (1...6).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
                let isMarkdownImage = group >= 5
                var path = source.substring(with: match.range(at: group))
                if isMarkdownImage {
                    var start = match.range.location
                    while start > 0, source.character(at: start - 1) == 0x5C { start -= 1 }
                    guard (match.range.location - start).isMultiple(of: 2) else { continue }
                    path = markdownEscape.stringByReplacingMatches(in: path, range: NSRange(path.startIndex..., in: path), withTemplate: "$1")
                    path = path.removingPercentEncoding ?? path
                }
                let isImage = imageExtensions.contains((path as NSString).pathExtension.lowercased())
                guard path.hasPrefix("/") || path.hasPrefix("~/"),
                      !(path as NSString).lastPathComponent.isEmpty,
                      !isMarkdownImage || (isImage && !path.hasPrefix("//")) else { continue }
                let before = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if !before.trimmingCharacters(in: .whitespaces).isEmpty { buffer.append(before) }
                flush()
                if seen.insert(path).inserted {
                    result.append(isImage ? .image(path) : .file(path))
                }
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

/// Identity of one non-image `MEDIA:` attachment. Downloads are not cached: the
/// user may save the same path twice after the service rewrites it.
struct RemoteFileRequest: Hashable, Sendable {
    let conversation: ConversationKey
    let messageID: String
    let path: String
    var filename: String { (path as NSString).lastPathComponent }
}
