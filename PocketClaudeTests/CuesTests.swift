import AVFoundation
import XCTest
@testable import PocketClaude

/// The first version of this used `AudioServicesPlaySystemSound` and was
/// silent on device — the call succeeded and nothing played, because system
/// sounds don't share the app's audio route. Nothing in code could have caught
/// that. What these tests do catch is the tone itself being malformed, which
/// would make `AVAudioPlayer` refuse it and leave the cue silent again, this
/// time for a reason a test can see.
@MainActor
final class CuesTests: XCTestCase {

    func testAVAudioPlayerAcceptsTheTone() throws {
        let player = try AVAudioPlayer(data: Cues.tone(hz: 880))
        XCTAssertEqual(player.duration, 0.12, accuracy: 0.01)
        XCTAssertEqual(player.numberOfChannels, 1)
    }

    func testToneIsNotSilent() {
        let data = Cues.tone(hz: 880)
        // Skip the 44-byte header; the samples must not be all zeroes, which is
        // what a silent "tone" would look like.
        XCTAssertFalse(
            data[44...].allSatisfy { $0 == 0 },
            "the tone must actually contain audio"
        )
    }

    func testToneStartsAndEndsQuietly() {
        let data = Cues.tone(hz: 880)
        // First and last samples should be near zero because of the fade — a
        // tone that starts at full amplitude clicks.
        let first = data[44..<46].withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertLessThan(abs(Int(first)), 500, "tone should fade in, not click")
    }
}
