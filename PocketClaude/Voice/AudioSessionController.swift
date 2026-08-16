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
            options: [.allowBluetooth, .duckOthers, .defaultToSpeaker]
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

    /// Hand the audio route back to whatever was playing before us.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}
