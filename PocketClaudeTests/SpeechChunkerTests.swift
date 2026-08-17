import XCTest
@testable import PocketClaude

/// The chunker decides what gets said out loud while an answer is still being
/// written, so its edge cases are audible: a wrong split stutters, a missed
/// fence reads a shell script aloud.
final class SpeechChunkerTests: XCTestCase {

    func testHoldsBackAnIncompleteSentence() {
        var chunker = SpeechChunker()
        XCTAssertEqual(chunker.append("The hold lifecycle "), [])
        XCTAssertEqual(chunker.append("starts in holds"), [])
    }

    func testEmitsOnceASentenceCompletes() {
        var chunker = SpeechChunker()
        _ = chunker.append("The hold lifecycle starts in holds.ts")
        let spoken = chunker.append(". Then it moves on.")
        XCTAssertEqual(spoken.first, "The hold lifecycle starts in holds.ts.")
    }

    func testSplitsMultipleSentencesInOneChunk() {
        var chunker = SpeechChunker()
        let spoken = chunker.append("First the reservation opens. Then a hold is offered. ")
        XCTAssertEqual(spoken, [
            "First the reservation opens.",
            "Then a hold is offered.",
        ])
    }

    func testDoesNotSplitOnANumberedListMarker() {
        // "1." must not end a sentence, or every list item becomes two.
        var chunker = SpeechChunker()
        let spoken = chunker.append("Steps: 1. open the hold and then confirm it. ")
        XCTAssertEqual(spoken.count, 1)
        XCTAssertEqual(spoken.first, "Steps: 1. open the hold and then confirm it.")
    }

    func testDoesNotSplitInsideADecimal() {
        var chunker = SpeechChunker()
        let spoken = chunker.append("The timeout is 3.5 seconds in production. ")
        XCTAssertEqual(spoken, ["The timeout is 3.5 seconds in production."])
    }

    func testSkipsFencedCode() {
        var chunker = SpeechChunker()
        var spoken = chunker.append("Here is the fix. ")
        spoken += chunker.append("```swift\nlet x = 1\nprint(x)\n```")
        spoken += chunker.append(" That resolves the crash. ")
        XCTAssertFalse(
            spoken.contains { $0.contains("let x") || $0.contains("print") },
            "code leaked into speech: \(spoken)"
        )
        XCTAssertTrue(spoken.contains { $0.contains("resolves the crash") })
    }

    func testHandlesAFenceSplitAcrossChunks() {
        // The three backticks can arrive one at a time; none may be spoken.
        var chunker = SpeechChunker()
        var spoken = chunker.append("Try this approach first. ")
        spoken += chunker.append("`")
        spoken += chunker.append("`")
        spoken += chunker.append("`\nrm -rf /tmp/cache\n```")
        spoken += chunker.flush()
        let all = spoken.joined(separator: " ")
        XCTAssertFalse(all.contains("rm -rf"), "code leaked: \(all)")
        XCTAssertFalse(all.contains("`"), "backticks leaked: \(all)")
    }

    func testFlushEmitsTheTrailingFragment() {
        var chunker = SpeechChunker()
        _ = chunker.append("No trailing punctuation here")
        let spoken = chunker.flush()
        XCTAssertEqual(spoken, ["No trailing punctuation here"])
    }

    func testFlushOnEmptyBufferSaysNothing() {
        var chunker = SpeechChunker()
        XCTAssertEqual(chunker.flush(), [])
    }

    func testNewlineEndsASentence() {
        var chunker = SpeechChunker()
        let spoken = chunker.append("The first finding is a race\nand more follows")
        XCTAssertEqual(spoken.first, "The first finding is a race")
    }

    func testStripsMarkdownEmphasis() {
        var chunker = SpeechChunker()
        let spoken = chunker.append("This is **important** and `inline` code here. ")
        XCTAssertEqual(spoken.first, "This is important and inline code here.")
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(
            SpeechChunker.clean("too    many\n\n spaces"),
            "too many spaces"
        )
    }

    func testConcatenationPreservesTheWholeAnswer() {
        // Whatever the chunk boundaries, the spoken words must match the text.
        var chunker = SpeechChunker()
        let fragments = ["The hold ", "lifecycle is in ", "holds.ts. It ", "then expires. "]
        var spoken: [String] = []
        for fragment in fragments {
            spoken += chunker.append(fragment)
        }
        spoken += chunker.flush()
        XCTAssertEqual(
            spoken.joined(separator: " "),
            "The hold lifecycle is in holds.ts. It then expires."
        )
    }
}
