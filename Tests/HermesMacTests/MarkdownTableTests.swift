import XCTest
import SwiftUI
import AppKit
@testable import HermesMac

@MainActor final class MarkdownTableTests: XCTestCase {
    private let sample = """
    | 日期 | 输入＋回答 token | 单独记录的思考 token |
    |---|---:|---:|
    | 10 月 8 日 | 33.9 万 | 25.1 万 |
    | 10 月 9 日 | 34.0 万 | 31.0 万 |
    | 10 月 10 日 | 21.0 万 | 19.4 万 |
    | 10 月 11 日 | 15.9 万 | 11.7 万 |
    | 10 月 12 日 | 1.6 万 | 1.2 万 |
    """

    func testReportedTableAndSurroundingText() throws {
        let blocks = MarkdownTable.blocks(in: "前文\n" + sample + "\n\n后文")
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks.first, .line("前文"))
        guard case .table(let table) = blocks[1] else { return XCTFail("Expected a table") }
        XCTAssertEqual(table.headers, ["日期", "输入＋回答 token", "单独记录的思考 token"])
        XCTAssertEqual(table.alignments, [.leading, .trailing, .trailing])
        XCTAssertEqual(table.rows.count, 5)
        XCTAssertEqual(table.rows.last, ["10 月 12 日", "1.6 万", "1.2 万"])
        XCTAssertEqual(blocks.last, .line("后文"))
    }

    func testOptionalOuterPipesEscapesAndRaggedRows() {
        let source = #"""
        **名称** | `值` | 链接
        :--- | :---: | ---:
        a\|b | 2
        c | 3 | [站点](https://example.com) | ignored
        """#
        guard case .table(let table) = MarkdownTable.blocks(in: source).first else { return XCTFail("Expected a table") }
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(table.headers, ["**名称**", "`值`", "链接"])
        XCTAssertEqual(table.rows[0], ["a|b", "2", ""])
        XCTAssertEqual(table.rows[1], ["c", "3", "[站点](https://example.com)"])
    }

    func testPlainPipesAndIncompleteTablesStayText() {
        for source in ["a | b\n--- | nope", "a | b\n---", "a | b\n--- | --- | ---", "a | b", "    | a | b |\n    |---|---|"] {
            XCTAssertEqual(MarkdownTable.blocks(in: source), source.components(separatedBy: "\n").map(MarkdownTextBlockContent.line))
        }
        let fenced = "```\n" + sample + "\n```"
        XCTAssertEqual(MediaDirective.segments(fenced, renderMedia: false), [.code(sample, language: "")])
    }

    func testTableLayoutDuringResizeAndStreaming() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let hosting = NSHostingView(rootView: AnyView(MarkdownView(text: sample)))
        window.contentView = hosting
        for width: CGFloat in [320, 900, 240] {
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            hosting.layoutSubtreeIfNeeded()
            let height = hosting.fittingSize.height
            XCTAssertTrue(height.isFinite)
            XCTAssertGreaterThan(height, 150, "Table must display all six rows")
            XCTAssertLessThan(height, 500)
        }
        for lineCount in 1...sample.components(separatedBy: "\n").count {
            hosting.rootView = AnyView(MarkdownView(text: sample.components(separatedBy: "\n").prefix(lineCount).joined(separator: "\n")))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(hosting.fittingSize.height.isFinite)
        }
    }
}
