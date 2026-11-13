import XCTest
@testable import HermesMac

final class MarkdownLinkTargetTests: XCTestCase {
    private func temporaryFile(named name: String = "shot.png") throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-link-\(UUID().uuidString)-\(name)")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    // MARK: - MarkdownLinkTarget

    func testBareAbsolutePathWithoutFileIsUnsupported() {
        // Regression: this destination reached LaunchServices, which answered paramErr (-50)
        // and made CoreServicesUIAgent show "应用程序无法打开。".
        let missing = "/var/folders/nj/_1k4dxj13l364q5n587v4jmr0000gn/T/missing-\(UUID().uuidString).png"
        let url = URL(string: missing)!
        XCTAssertNil(url.scheme)
        XCTAssertEqual(MarkdownLinkTarget.resolve(url), .unsupported)
        XCTAssertNil(MarkdownLinkTarget.linkURL(for: url))
    }

    func testExistingAbsolutePathBecomesLocalFile() throws {
        let file = try temporaryFile()
        XCTAssertEqual(MarkdownLinkTarget.resolve(URL(string: file.path)!), .localFile(file))
        XCTAssertEqual(MarkdownLinkTarget.resolve(file), .localFile(file))
        XCTAssertEqual(MarkdownLinkTarget.linkURL(for: file), file)
    }

    func testWebLinksKeepTheirScheme() {
        let https = URL(string: "https://example.com/a.png")!
        let service = URL(string: "http://192.168.123.61:9119/api")!
        XCTAssertEqual(MarkdownLinkTarget.resolve(https), .system(https))
        XCTAssertEqual(MarkdownLinkTarget.resolve(service), .system(service))
    }

    func testBareHostGetsHTTPSPrefix() {
        XCTAssertEqual(
            MarkdownLinkTarget.resolve(URL(string: "example.com/docs")!),
            .system(URL(string: "https://example.com/docs")!)
        )
    }

    func testRelativeAndEmptyDestinationsAreUnsupported() {
        XCTAssertEqual(MarkdownLinkTarget.resolve(URL(string: "images/shot.png")!), .unsupported)
        XCTAssertEqual(MarkdownLinkTarget.resolve(URL(string: "../shot.png")!), .unsupported)
        XCTAssertEqual(MarkdownLinkTarget.resolve(URL(string: "shot")!), .unsupported)
    }

    // MARK: - InlineMarkdown normalisation

    func testParsedLinkDropsUnopenablePath() {
        let result = InlineMarkdown.parse("见 [截图](/var/folders/nj/_1k4dxj13l364q5n587v4jmr0000gn/T/gone.png) 这里")
        XCTAssertFalse(result.runs.contains { $0.link != nil })
        XCTAssertEqual(String(result.characters), "见 截图 这里")
    }

    func testParsedLinkPointsAtExistingLocalFile() throws {
        let file = try temporaryFile()
        let result = InlineMarkdown.parse("见 [截图](\(file.path)) 这里")
        let links = result.runs.compactMap(\.link)
        XCTAssertEqual(links, [file])
    }

    func testParsedBareHostLinkGainsScheme() {
        let result = InlineMarkdown.parse("参考 [example.com/docs](example.com/docs)")
        let links = result.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.com/docs")!])
    }

    func testParsedStrongLinkKeepsResolutionAfterMarkerRemoval() throws {
        let file = try temporaryFile()
        let result = InlineMarkdown.parse("**重点：**[截图](\(file.path))")
        XCTAssertTrue(result.runs.contains { $0.link == file })
        XCTAssertEqual(String(result.characters), "重点：截图")
    }
}
