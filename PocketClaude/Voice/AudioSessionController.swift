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
            // Just `.allowBluetooth`.
            //
            // `.defaultToSpeaker` was here and is actively wrong with an AirPod
            // connected: it demands the output move to the phone's built-in
            // speaker at the same moment the microphone is being acquired, so
            // the route is renegotiated exactly when it needs to be stable.
            // `.duckOthers` means mixing, which is a second negotiation over
            // the same route. Starting the engine failed with CoreAudio's
            // generic 'what' error while the screen was locked, where there is
            // less slack for that to settle in.
            //
            // Nothing needs either option: the Now Playing loop already holds
            // the route, so there is nothing to duck, and the whole point is to
            // stay on the headset rather than fall back to the speaker.
            options: [.allowBluetooth]
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
