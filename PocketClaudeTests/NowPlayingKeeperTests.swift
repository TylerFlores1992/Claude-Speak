import AVFoundation
import XCTest
@testable import PocketClaude

/// The silent loop is what holds the Now Playing slot, and the slot is what
/// makes an AirPod stem press reach this app at all. If the generated WAV is
/// malformed, `AVAudioPlayer` refuses it, the loop never starts, and the stem
/// silently goes to Music — with no error anywhere. Hence testing the bytes.
final class NowPlayingKeeperTests: XCTestCase {

    func testGeneratesAWellFormedWAVHeader() {
        let data = NowPlayingKeeper.silentWAV()

        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")

        // The RIFF size field counts everything after the first 8 bytes.
        XCTAssertEqual(readUInt32(data, at: 4), UInt32(data.count - 8))
        // 8 kHz mono 16-bit for half a second.
        XCTAssertEqual(readUInt32(data, at: 24), 8_000)
        XCTAssertEqual(readUInt32(data, at: 40), 8_000)
        XCTAssertEqual(data.count, 44 + 8_000)
    }

    func testTheAudioIsActuallySilent() {
        let data = NowPlayingKeeper.silentWAV()
        XCTAssertTrue(
            data[44...].allSatisfy { $0 == 0 },
            "the sample data must be zeroes — this plays on a loop forever"
        )
    }

    func testAVAudioPlayerAcceptsIt() throws {
        // The assertion that matters: the real decoder takes these bytes.
        let player = try AVAudioPlayer(data: NowPlayingKeeper.silentWAV())
        XCTAssertEqual(player.duration, 0.5, accuracy: 0.01)
        XCTAssertEqual(player.numberOfChannels, 1)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
