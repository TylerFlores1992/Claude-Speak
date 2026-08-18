import AVFoundation

/// Owns the shared `AVAudioSession`.
///
/// Two modes, because they want different categories:
///
/// - **Recording** needs `.playAndRecord` so the microphone is live. On AirPods
///   this routes input to the AirPod mic and output to the AirPod.
/// - **Speaking** uses `.playback`, which is the category iOS honours when the
///   screen is off and the phone is in your pocket. Combined with the `audio`
///   background mode in Info.plist, TTS keeps playing while locked.
///
/// We deliberately switch between them rather than staying in `.playAndRecord`
/// the whole time: `.playAndRecord` on a Bluetooth headset forces the low-quality
/// HFP path, so every spoken answer would sound like a phone call.
enum AudioSessionController {
    static func configureForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            // Deliberately the same options as
            // `configureForHoldingNowPlayingWithMic`. When stem press is on the
            // session is already in exactly this configuration, so this call
            // changes nothing and there is no route renegotiation to race with
            // — which is the entire point. `.duckOthers` is gone because the
            // Now Playing loop has already taken the audio route; there is
            // nothing left to duck.
            options: [.allowBluetooth, .defaultToSpeaker]
        )
        try session.setActive(true, options: [])
    }

    static func configureForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            // `.spokenAudio` tells iOS this is speech, so it pauses rather than
            // ducks other audio and behaves well with CarPlay.
            mode: .spokenAudio,
            options: [.allowBluetoothA2DP, .duckOthers]
        )
        try session.setActive(true, options: [])
    }

    /// For holding the Now Playing slot *while the microphone must stay
    /// reachable* — that is, whenever stem-press control is on.
    ///
    /// `.playAndRecord` rather than `.playback`, even though nothing is being
    /// recorded yet. A backgrounded app on a locked device cannot newly acquire
    /// the microphone: switching into `.playAndRecord` at press time failed
    /// with CoreAudio's `'what'` error (2003329396) every time the screen was
    /// locked, while the identical code worked in the foreground. Being in a
    /// record-capable category already means there is no acquisition to make.
    ///
    /// The cost is real: `.playAndRecord` on a Bluetooth headset forces the
    /// low-quality HFP path, so answers spoken while this is active sound like
    /// a phone call. `configureForPlayback` is still used for speaking, which
    /// switches back to the good path for the part you actually listen to.
    static func configureForHoldingNowPlayingWithMic() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .defaultToSpeaker]
        )
        try session.setActive(true, options: [])
    }

    /// For holding the Now Playing slot with `NowPlayingKeeper`.
    ///
    /// Deliberately *not* `.duckOthers`. Ducking means mixing — our audio plays
    /// alongside Music with Music turned down — and a mixing app never becomes
    /// the Now Playing app. That was the bug: the silent loop politely ducked
    /// Music while Music kept the slot, and the stem press with it. Taking the
    /// slot requires interrupting other audio, which is what the default
    /// (non-mixing) `.playback` behaviour does.
    ///
    /// `.default` rather than `.spokenAudio` for the same reason: `.spokenAudio`
    /// is tuned to yield politely around other players, which is right for
    /// reading an answer and wrong for holding a slot.
    static func configureForHoldingNowPlaying() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.allowBluetoothA2DP]
        )
        try session.setActive(true, options: [])
    }

    /// Hand the audio route back to whatever was playing before us.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}
