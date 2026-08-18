import XCTest
@testable import PocketClaude

/// The transcript showed literal `**` and `##` because the raw string went
/// straight to `Text`. These cover the block splitting; inline formatting is
/// `AttributedString`'s job and is not re-tested here.
final class MarkdownTests: XCTestCase {

    func testHeadingsBulletsAndParagraphs() {
        let blocks = MarkdownBlock.parse("""
        ## CampHawk

        A campsite alerting service.

        - Polls every 15 seconds
        - Alerts by SMS
        """)

        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "CampHawk"),
            .paragraph("A campsite alerting service."),
            .bullet("Polls every 15 seconds"),
            .bullet("Alerts by SMS"),
        ])
    }

    func testFencedCodeIsOneBlock() {
        let blocks = MarkdownBlock.parse("""
        Run it:

        ```bash
        node relay/server.mjs
        echo done
        ```

        That's all.
        """)

        XCTAssertEqual(blocks, [
            .paragraph("Run it:"),
            .code("node relay/server.mjs\necho done"),
            .paragraph("That's all."),
        ])
    }

    func testUnterminatedFenceStillShowsItsContents() {
        // A truncated answer must not swallow the code it was mid-way through.
        let blocks = MarkdownBlock.parse("Here:\n\n```\nnpm test")
        XCTAssertEqual(blocks, [.paragraph("Here:"), .code("npm test")])
    }

    func testNumberedLists() {
        let blocks = MarkdownBlock.parse("1. First\n2. Second")
        XCTAssertEqual(blocks, [
            .numbered(marker: "1", text: "First"),
            .numbered(marker: "2", text: "Second"),
        ])
    }

    func testEmphasisIsNotMistakenForABullet() {
        // "*emphasis*" starts with an asterisk but is not a list item; the
        // space after the marker is what distinguishes them.
        XCTAssertEqual(
            MarkdownBlock.parse("*emphasis* matters"),
            [.paragraph("*emphasis* matters")]
        )
    }

    func testAYearIsNotANumberedItem() {
        XCTAssertEqual(
            MarkdownBlock.parse("2026. What a year"),
            [.paragraph("2026. What a year")]
        )
    }

    func testWrappedLinesJoinIntoOneParagraph() {
        XCTAssertEqual(
            MarkdownBlock.parse("The poller runs\non Fly."),
            [.paragraph("The poller runs on Fly.")]
        )
    }

    func testNothingIsLost() {
        // The property that matters most: every non-empty line ends up
        // somewhere. Silently dropping part of an answer would be worse than
        // rendering it plainly.
        let source = """
        # Title
        Body text
        - a bullet
        > a quote we don't style
        | table | row |
        """
        let rendered = MarkdownBlock.parse(source).map { block -> String in
            switch block {
            case .heading(_, let t), .paragraph(let t), .bullet(let t), .code(let t): return t
            case .numbered(_, let t): return t
            }
        }.joined(separator: " ")

        for fragment in ["Title", "Body text", "a bullet", "a quote", "table"] {
            XCTAssertTrue(rendered.contains(fragment), "lost: \(fragment)")
        }
    }
}
