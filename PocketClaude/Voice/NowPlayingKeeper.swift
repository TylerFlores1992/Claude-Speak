import AVFoundation

/// Holds the Now Playing slot by playing silence on a loop.
///
/// **Why this exists.** An AirPod stem press is delivered to exactly one app:
/// whichever currently holds the Now Playing slot. iOS gives third-party apps
/// no API for AirPods gestures, so borrowing that slot is the only route.
///
/// Claiming it once isn't enough. A slot is held by *ongoing playback*, and
/// Music keeps it even while paused — so a brief silent utterance took the slot
/// for a moment and handed it straight back, which is why the first squeeze
/// still went to Music. Continuous playback is what actually holds it.
///
/// **The cost, stated plainly.** While this is running you cannot listen to
/// music or a podcast through the same device: taking the slot interrupts them,
/// and if they take it back the stem stops reaching us. Only one app can own
/// the stem, so this is a genuine either/or rather than something clever
/// enough code could avoid. It also keeps the audio session active, which uses
/// battery. Both are why it runs only while "AirPod stem press" is switched on.
@MainActor
final class NowPlayingKeeper {
    private var player: AVAudioPlayer?

    var isRunning: Bool { player != nil }

    /// Begin holding the slot. Safe to call repeatedly.
    func start() {
        guard player == nil else { return resumeIfNeeded() }
        try? AudioSessionController.configureForHoldingNowPlaying()
        guard let player = try? AVAudioPlayer(data: NowPlayingKeeper.silentWAV()) else { return }
        // -1 loops forever. Volume 0 because nobody wants to hear this; the
        // slot is held by the fact that playback is running, not by its level.
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        player.play()
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
    }

    /// Switching the session to `.playAndRecord` for the microphone, or an
    /// interruption, can stop the loop. Call this whenever the app returns to
    /// rest so the slot isn't quietly lost after the first question.
    /// Stop the loop for a moment without giving up the slot.
    ///
    /// Switching the session to `.playAndRecord` while this is playing makes
    /// CoreAudio renegotiate the route underneath us, and the microphone's
    /// format reads back empty during that window — which used to abort the
    /// process inside `installTapOnBus:`. Pausing across the switch removes the
    /// contention; `resume(reassertCategory: false)` starts it again once the
    /// microphone is live, so the slot is still held while you talk.
    func suspend() {
        player?.pause()
    }

    /// Start the loop again.
    ///
    /// `reassertCategory` must be false while the microphone is live —
    /// re-applying the playback category there would tear down the recording
    /// session mid-sentence.
    func resume(reassertCategory: Bool) {
        guard let player else { return }
        if reassertCategory {
            try? AudioSessionController.configureForHoldingNowPlaying()
        }
        if !player.isPlaying { player.play() }
    }

    func resumeIfNeeded() {
        guard let player else { return }
        // Re-assert the category even when the loop is still running. Speaking
        // an answer switches the session to a ducking configuration, and a
        // ducking session hands the Now Playing slot straight back to Music —
        // so the stem would work for exactly one question and then stop.
        try? AudioSessionController.configureForHoldingNowPlaying()
        if !player.isPlaying { player.play() }
    }

    // MARK: - Silence

    /// A half second of 8 kHz mono silence, built in memory.
    ///
    /// Generated rather than bundled so there's no binary asset in the repo to
    /// take on trust — the whole file is 44 bytes of header and zeroes.
    /// `nonisolated` because it touches no actor state — it just builds bytes.
    /// Without it the whole class's `@MainActor` would apply, and the tests
    /// could not call it from a synchronous context.
    nonisolated static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let frameCount: UInt32 = sampleRate / 2
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = frameCount * UInt32(blockAlign)

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))            // PCM header length
        append(UInt16(1))             // format: PCM
        append(channels)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)

        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
