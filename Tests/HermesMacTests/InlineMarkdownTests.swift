import XCTest
@testable import HermesMac

final class InlineMarkdownTests: XCTestCase {
    private func strongText(_ value: AttributedString) -> String {
        value.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(value[$0.range].characters) }.joined()
    }

    func testChinesePunctuationFromReportedMessage() {
        for phrase in ["适合怎么放：", "“大场面”", "中途这一站，我首推黄石国家矿山公园；备选潜山的山谷流泉。"] {
            let result = InlineMarkdown.parse("前文**\(phrase)**若去程经过黄石。")
            XCTAssertEqual(String(result.characters), "前文\(phrase)若去程经过黄石。")
            XCTAssertEqual(strongText(result), phrase)
        }
    }

    func testMultipleStrongSpansAndNestedFormatting() {
        let result = InlineMarkdown.parse("**建议留两小时左右，**看**核心矿坑**。**还有 *重点* 和 [链接](https://example.com)**")
        XCTAssertEqual(String(result.characters), "建议留两小时左右，看核心矿坑。还有 重点 和 链接")
        XCTAssertEqual(strongText(result), "建议留两小时左右，核心矿坑还有 重点 和 链接")
        XCTAssertTrue(result.runs.contains { $0.link?.absoluteString == "https://example.com" })
        XCTAssertTrue(result.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    }

    func testLiteralStarsCodeAndLinksRemainNative() throws {
        for source in [#"\*\*原样：\*\*后文"#, "`**代码：**原样`", "``a ` **代码**``", "[链接](https://example.com/**path**) 后文", "<https://example.com/**path**>", "**bold** and *italic*", "**outer *inner* end**", "**outer `code` end**", "** 未加粗 **", "***重点***", "***", "**未闭合", "正文 **正在生成："] {
            let native = try AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            XCTAssertEqual(InlineMarkdown.parse(source), native, source)
        }
    }

    func testProtectedSyntaxAlongsideChineseStrongText() {
        let result = InlineMarkdown.parse(#"`**代码：**` \*\*原样\*\* [站点](https://example.com/**path**) **适合怎么放：**若经过黄石"#)
        XCTAssertEqual(String(result.characters), "**代码：** **原样** 站点 适合怎么放：若经过黄石")
        XCTAssertEqual(strongText(result), "适合怎么放：")
        XCTAssertTrue(result.runs.contains { $0.link?.absoluteString == "https://example.com/**path**" })
        XCTAssertTrue(result.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testStreamedCompletionAndMarkerCollision() {
        let source = "HermesStrongBoundary **适合怎么放：**若经过黄石"
        for length in 0...source.count {
            let prefix = String(source.prefix(length))
            let result = InlineMarkdown.parse(prefix)
            XCTAssertFalse(String(result.characters).contains("HermesStrongBoundaryX"))
        }
        XCTAssertEqual(String(InlineMarkdown.parse(source).characters), "HermesStrongBoundary 适合怎么放：若经过黄石")
    }

    @MainActor func testTableCellUsesSameStrongParsing() {
        let cell = MarkdownTableLayoutCache.Cell(source: "**适合怎么放：**若经过黄石", header: false, fontSize: 14)
        XCTAssertEqual(String(cell.content.characters), "适合怎么放：若经过黄石")
        XCTAssertEqual(strongText(cell.content), "适合怎么放：")
    }
}
