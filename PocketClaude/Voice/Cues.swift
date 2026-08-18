import AVFoundation

/// Short tones marking the start and end of a take.
///
/// With the phone pocketed there is nothing to look at, and opening the
/// microphone is not instant — the audio route needs a moment to settle after
/// the switch to recording. Without a cue you are guessing whether it heard
/// you, and the usual reaction is to start talking too early and lose the first
/// word.
///
/// **Why not `AudioServicesPlaySystemSound`.** That was the first attempt and
/// it was silent on device. System sounds play on their own path, which iOS
/// suppresses or routes elsewhere while an app holds a non-mixing
/// `.playAndRecord` session — exactly the state these are meant to announce.
/// Playing a generated tone through our own session puts it on the same route
/// as everything else, which on AirPods means it lands in your ear.
@MainActor
enum Cues {
    /// Held strongly: `AVAudioPlayer` stops if it is deallocated mid-play, and
    /// these are short enough that a local would be gone before you heard it.
    private static var player: AVAudioPlayer?

    /// Played once the microphone is genuinely open — not when the button is
    /// pressed. That distinction is the whole point: it says "talk now".
    static func listening() {
        play(hz: 880)
    }

    /// Played when the take ends and the question is on its way. Lower than the
    /// start tone so the two are distinguishable without looking.
    static func stoppedListening() {
        play(hz: 587)
    }

    private static func play(hz: Double) {
        guard let player = try? AVAudioPlayer(data: tone(hz: hz)) else { return }
        player.volume = 0.35
        player.prepareToPlay()
        player.play()
        Cues.player = player
    }

    // MARK: - Tone

    /// A 120ms sine tone as a WAV, built in memory.
    ///
    /// Generated rather than bundled so there is no binary asset to take on
    /// trust, and so the pitch is a parameter rather than two more files.
    /// Internal rather than private so the tests can check the bytes.
    static func tone(
        hz: Double,
        seconds: Double = 0.12,
        sampleRate: Double = 44_100
    ) -> Data {
        let frameCount = Int(seconds * sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(frameCount) * UInt32(blockAlign)

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * UInt32(blockAlign))
        append(blockAlign)
        append(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)

        // A linear fade at each end. A tone that starts and stops at full
        // amplitude clicks, and a click is what a broken app sounds like.
        let fade = Double(frameCount) * 0.15
        for frame in 0..<frameCount {
            let position = Double(frame)
            let envelope = min(1, min(position / fade, (Double(frameCount) - position) / fade))
            let value = sin(2 * .pi * hz * position / sampleRate) * envelope
            append(Int16(value * 32_000))
        }
        return data
    }
}
