import XCTest
@testable import PocketClaude

/// The response-parsing layer decides what gets read into your ear. If it fails
/// open, you hear raw JSON — so every degradation step is covered here.
final class ResponseParserTests: XCTestCase {
    func testParsesCleanJSONObject() {
        let raw = #"{"spoken_summary": "The hold lifecycle has four states.", "detail": "See `lib/holds.ts`."}"#
        let result = ResponseParser.parse(raw)
        XCTAssertEqual(result.spoken, "The hold lifecycle has four states.")
        XCTAssertEqual(result.detail, "See `lib/holds.ts`.")
    }

    func testParsesJSONInsideFencedBlock() {
        let raw = """
        ```json
        {"spoken_summary": "Four states.", "detail": "Long detail here."}
        ```
        """
        let result = ResponseParser.parse(raw)
        XCTAssertEqual(result.spoken, "Four states.")
        XCTAssertEqual(result.detail, "Long detail here.")
    }

    func testParsesJSONEmbeddedInProse() {
        let raw = """
        Here is the answer you asked for:
        {"spoken_summary": "Two open TODOs.", "detail": "One in capacity.ts, one in decline.ts."}
        Hope that helps.
        """
        let result = ResponseParser.parse(raw)
        XCTAssertEqual(result.spoken, "Two open TODOs.")
        XCTAssertEqual(result.detail, "One in capacity.ts, one in decline.ts.")
    }

    func testBraceBalancingIgnoresBracesInsideStrings() {
        let raw = #"{"spoken_summary": "Uses a } brace", "detail": "and a { one too"}"#
        let result = ResponseParser.parse(raw)
        XCTAssertEqual(result.spoken, "Uses a } brace")
        XCTAssertEqual(result.detail, "and a { one too")
    }

    func testAcceptsAlternateKeySpellings() {
        let raw = #"{"spoken": "Short answer.", "body": "Longer answer."}"#
        let result = ResponseParser.parse(raw)
        XCTAssertEqual(result.spoken, "Short answer.")
        XCTAssertEqual(result.detail, "Longer answer.")
    }

    func testFallsBackToDetailEqualsSpokenWhenDetailMissing() {
        let raw = #"{"spoken_summary": "Only a summary."}"#
        let result = ResponseParser.parse(raw)
        XCTAssertEqual(result.spoken, "Only a summary.")
        XCTAssertEqual(result.detail, "Only a summary.")
    }

    func testParsesLabelledProse() {
        let raw = """
        Spoken: The decline path returns early when capacity is zero.

        The full detail lives in `lib/holds/decline.ts` at line 42.
        """
        let result = ResponseParser.parse(raw)
        XCTAssertEqual(result.spoken, "The decline path returns early when capacity is zero.")
        XCTAssertTrue(result.detail.contains("decline.ts"))
    }

    func testHeuristicSummaryTakesFirstSentencesAndDropsCode() {
        let raw = """
        The hold lifecycle moves through requested, offered, confirmed, and expired. \
        Each transition is guarded. Here is the code:

        ```ts
        export function decline(hold: Hold) { return hold; }
        ```

        And more prose after.
        """
        let result = ResponseParser.parse(raw)
        XCTAssertTrue(result.spoken.hasPrefix("The hold lifecycle moves through"))
        XCTAssertFalse(result.spoken.contains("export function"))
        // Detail keeps everything, including the code.
        XCTAssertTrue(result.detail.contains("export function"))
    }

    func testHeuristicSummaryStopsAtTwoSentences() {
        let raw = "One. Two. Three. Four."
        let result = ResponseParser.parse(raw)
        XCTAssertEqual(result.spoken, "One. Two.")
    }

    func testHeuristicSummaryTruncatesVeryLongSingleSentence() {
        let raw = String(repeating: "word ", count: 300)
        let result = ResponseParser.parse(raw)
        XCTAssertLessThanOrEqual(result.spoken.count, 421)
        XCTAssertTrue(result.spoken.hasSuffix("…"))
    }

    func testEmptyInputProducesSpeakableFallback() {
        let result = ResponseParser.parse("   \n  ")
        XCTAssertFalse(result.spoken.isEmpty)
    }

    func testMalformedJSONFallsThroughToHeuristic() {
        let raw = #"{"spoken_summary": "unterminated"#
        let result = ResponseParser.parse(raw)
        // The contract is "always produce something speakable", not "produce
        // something pretty" — truncated JSON is a model bug, and the transcript
        // shows the raw text so it's diagnosable.
        XCTAssertFalse(result.spoken.isEmpty)
        XCTAssertEqual(result.detail, raw)
    }

    func testSanitizeForSpeechStripsMarkdownNoise() {
        let sanitized = ResponseParser.sanitizeForSpeech("**Bold** and `code` and # heading")
        XCTAssertEqual(sanitized, "Bold and code and heading")
    }

    func testSanitizeForSpeechFlattensBulletLists() {
        let sanitized = ResponseParser.sanitizeForSpeech("- first\n- second")
        XCTAssertEqual(sanitized, "first second")
    }

    func testStripFencedCodeRemovesOnlyFencedRegions() {
        let text = "before\n```\ncode\n```\nafter"
        XCTAssertEqual(ResponseParser.stripFencedCode(text), "before\nafter")
    }
}
