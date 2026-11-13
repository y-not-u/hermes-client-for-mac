import Foundation

/// Classifies a markdown link destination before SwiftUI hands it to LaunchServices.
///
/// Foundation keeps `[text](/var/folders/…/shot.png)` as a URL without a scheme, and
/// passing that straight to the system makes `LSOpenStuffCallLocal` answer paramErr
/// (-50), which surfaces as the CoreServicesUIAgent alert "应用程序无法打开。".
/// Destinations are therefore normalised into a proper URL, or dropped as plain text.
enum MarkdownLinkTarget: Equatable {
    /// Well-formed URL opened by the system (`https`, `mailto`, any real scheme).
    case system(URL)
    /// Existing local file; opened directly so the image or document shows up.
    case localFile(URL)
    /// Bare or relative path with nothing to open; the text stays unlinked.
    case unsupported

    static func resolve(_ url: URL) -> MarkdownLinkTarget {
        if url.isFileURL {
            return localFile(for: url.path)
        }
        if let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            return .system(url)
        }
        guard let raw = url.absoluteString.removingPercentEncoding, !raw.isEmpty else {
            return .unsupported
        }
        if raw.hasPrefix("/") || raw.hasPrefix("~/") {
            return localFile(for: (raw as NSString).expandingTildeInPath)
        }
        // Only a bare host such as `example.com/docs` becomes a web link; a relative
        // path like `images/shot.png` must not be guessed into `https://images/...`.
        let head = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw
        if head.contains("."), !head.contains(" "), !head.hasPrefix("."),
           let web = URL(string: "https://" + raw) {
            return .system(web)
        }
        return .unsupported
    }

    /// URL to attach to the attributed link, or `nil` to leave the text unlinked.
    static func linkURL(for url: URL) -> URL? {
        switch resolve(url) {
        case .system(let url): return url
        case .localFile(let url): return url
        case .unsupported: return nil
        }
    }

    private static func localFile(for path: String) -> MarkdownLinkTarget {
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .unsupported
        }
        return .localFile(fileURL)
    }
}
