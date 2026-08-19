import XCTest
@testable import PocketClaude

/// Apple's recogniser punctuates and capitalises as it goes, so the same words
/// arrive in several shapes within one utterance. These are the shapes seen in
/// practice, not invented ones.
final class WakeWordDetectorTests: XCTestCase {
    private let detector = WakeWordDetector(phrase: "hey claude", endKeyword: "done")

    // MARK: - Finding the phrase

    func testFindsThePhraseRegardlessOfPunctuationAndCase() {
        for transcript in [
            "hey claude what time is it",
            "Hey, Claude, what time is it",
            "Hey Claude! What time is it?",
            "  HEY   CLAUDE   what time is it  ",
        ] {
            XCTAssertEqual(
                detector.pendingQuestion(in: transcript)?.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,!?")),
                "what time is it",
                "failed on \(transcript)"
            )
        }
    }

    func testReturnsNilBeforeThePhraseIsHeard() {
        XCTAssertNil(detector.pendingQuestion(in: ""))
        XCTAssertNil(detector.pendingQuestion(in: "what time is it"))
        // A near miss is a miss. Acting on "hey" alone would fire constantly.
        XCTAssertNil(detector.pendingQuestion(in: "hey there"))
    }

    func testKeepsTheOriginalWordingOfTheQuestion() {
        // The question is sent to Claude, so it must not arrive flattened.
        XCTAssertEqual(
            detector.pendingQuestion(in: "Hey Claude, does CampHawk's parser handle CSV?"),
            "does CampHawk's parser handle CSV?"
        )
    }

    func testAnEmptyQuestionIsAnEmptyStringNotNil() {
        // The phrase was heard; nothing has been said yet. The caller needs to
        // tell that apart from "not triggered", because it is what starts the
        // recording cue.
        XCTAssertEqual(detector.pendingQuestion(in: "Hey Claude"), "")
    }

    func testARepeatedPhraseStartsOver() {
        // Saying it again abandons the half-finished question rather than
        // appending to it.
        XCTAssertEqual(
            detector.pendingQuestion(in: "hey claude what is the wea— hey claude what time is it"),
            "what time is it"
        )
    }

    // MARK: - Knowing when to send

    func testCompleteOnlyWhenTheEndKeywordIsLast() {
        XCTAssertTrue(detector.isComplete("what time is it done"))
        XCTAssertTrue(detector.isComplete("what time is it, done."))
        XCTAssertTrue(detector.isComplete("done"))

        XCTAssertFalse(detector.isComplete("what time is it"))
        // The word inside a sentence is not the signal.
        XCTAssertFalse(detector.isComplete("are the tests done yet"))
        XCTAssertFalse(detector.isComplete(""))
    }

    func testStripsTheEndKeywordFromWhatIsSent() {
        XCTAssertEqual(detector.stripEndKeyword(from: "what time is it done"), "what time is it")
        XCTAssertEqual(detector.stripEndKeyword(from: "what time is it, done."), "what time is it")
        XCTAssertEqual(detector.stripEndKeyword(from: "done"), "")
    }

    func testLeavesAQuestionThatMerelyContainsTheWord() {
        XCTAssertEqual(
            detector.stripEndKeyword(from: "are the tests done yet"),
            "are the tests done yet"
        )
    }

    // MARK: - Configuration

    func testAnEmptyPhraseNeverTriggers() {
        // Otherwise clearing the field in Settings would make every sound a
        // wake word.
        let blank = WakeWordDetector(phrase: "", endKeyword: "done")
        XCTAssertNil(blank.pendingQuestion(in: "anything at all"))
    }

    func testAnEmptyEndKeywordIsNeverComplete() {
        let blank = WakeWordDetector(phrase: "hey claude", endKeyword: "")
        XCTAssertFalse(blank.isComplete("what time is it"))
        XCTAssertEqual(blank.stripEndKeyword(from: "what time is it"), "what time is it")
    }

    func testAMultiWordPhraseIsMatchedAsAWhole() {
        let detector = WakeWordDetector(phrase: "ok pocket claude", endKeyword: "done")
        XCTAssertNil(detector.pendingQuestion(in: "ok claude what time is it"))
        XCTAssertEqual(
            detector.pendingQuestion(in: "OK, Pocket Claude — what time is it"),
            "what time is it"
        )
    }
}
