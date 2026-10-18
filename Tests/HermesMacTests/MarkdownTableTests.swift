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

    func testStreamedTableReusesCompletedCellsAndInvalidatesTypography() {
        let cache = MarkdownTableLayoutCache()
        let original = MarkdownTable(headers: ["景点", "我的取舍"], alignments: [.leading, .leading], rows: [["大峡谷", "**主角**，优先留给晴天。"], ["七星寨", "正在生成"]])
        let first = cache.layout(for: original, fontSize: 13.5)
        let repeated = cache.layout(for: original, fontSize: 13.5)
        XCTAssertTrue(first.cells[1][1] === repeated.cells[1][1])
        let streamed = MarkdownTable(headers: original.headers, alignments: original.alignments, rows: [original.rows[0], ["七星寨", "正在生成更多文字"]])
        let updated = cache.layout(for: streamed, fontSize: 13.5)
        XCTAssertTrue(first.cells[0][0] === updated.cells[0][0])
        XCTAssertTrue(first.cells[1][1] === updated.cells[1][1])
        XCTAssertFalse(first.cells[2][1] === updated.cells[2][1])
        let enlarged = cache.layout(for: streamed, fontSize: 22)
        XCTAssertFalse(updated.cells[1][1] === enlarged.cells[1][1])
        XCTAssertGreaterThan(enlarged.height, updated.height)
    }

    func testLongChineseTableHasBoundedHeightAndUnclippedCells() {
        _ = NSApplication.shared
        let source = String(repeating: "**主角，优先留给晴天。** 索道上、扶梯下，中间仍有不少步行和台阶，单独留一天最稳妥。", count: 3)
        let table = MarkdownTable(headers: ["景点", "我的取舍"], alignments: [.leading, .leading], rows: (0..<12).map { ["景点 \($0)", source] })
        let cache = MarkdownTableLayoutCache()
        for fontSize: CGFloat in [13.5, 22, 28] {
            let layout = cache.layout(for: table, fontSize: fontSize)
            for column in table.headers.indices {
                let cell = NSHostingView(rootView: Text(layout.cells[1][column].content)
                    .font(.system(size: fontSize))
                    .frame(width: layout.widths[column])
                    .fixedSize(horizontal: false, vertical: true))
                XCTAssertLessThanOrEqual(cell.fittingSize.height + 16, layout.rowHeights[1], "Explicit row height must fit wrapped text")
            }
            let hosting = NSHostingView(rootView: MarkdownTableView(table: table, fontSize: fontSize))
            for width: CGFloat in [240, 900, 320] {
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: 600)
                hosting.layoutSubtreeIfNeeded()
                XCTAssertEqual(hosting.fittingSize.height, layout.height + 4, accuracy: 1)
            }
        }
    }

    func testLongTableInScrollingTranscriptSettlesDuringStreamingAndResize() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let rows = (0..<12).map { "| 景点 \($0) | **主角，优先留给晴天。** 索道上、扶梯下，中间仍有不少步行和台阶，单独留一天最稳妥。 |" }.joined(separator: "\n")
        let prefix = "| 景点 | 我的取舍 |\n|---|---|\n" + rows + "\n| 备选 | "
        func transcript(_ suffix: String) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("前文")
                    MarkdownView(text: prefix + suffix)
                    Text("后文").id("bottom")
                }
                .padding(24)
            }
        }
        let hosting = NSHostingView(rootView: transcript(""))
        window.contentView = hosting
        let start = Date()
        for index in 0..<24 {
            hosting.frame = NSRect(x: 0, y: 0, width: index.isMultiple(of: 2) ? 320 : 900, height: 600)
            hosting.rootView = transcript(String(repeating: "继续生成中文内容", count: index))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(hosting.fittingSize.height.isFinite)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "Nested table layout must settle during streaming and resize")
    }

    func testUnchangedCodeRetainsSelectionAndRespondsToTypographyChanges() async throws {
        let suite = "HermesMarkdown-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ChatTypography.defaultSize, forKey: ChatTypography.key)
        let text = "```swift\nlet value = 1\n```\nstreaming"
        let hosting = NSHostingView(rootView: MarkdownView(text: text).defaultAppStorage(defaults))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        hosting.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let code = try XCTUnwrap(editor(in: hosting))
        let selection = NSRange(location: 4, length: 5)
        code.setSelectedRange(selection)
        hosting.rootView = MarkdownView(text: text + " suffix").defaultAppStorage(defaults)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor(in: hosting) === code)
        XCTAssertEqual(code.selectedRange(), selection)
        defaults.set(22.0, forKey: ChatTypography.key)
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(code.font).pointSize, ChatTypography.scaled(12.5, for: 22), accuracy: 0.01)
        hosting.rootView = MarkdownView(text: "```swift\nlet value = 2\n```\nfinished").defaultAppStorage(defaults)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(code.string, "let value = 2")
    }
}
