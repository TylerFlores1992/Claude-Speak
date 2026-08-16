import Foundation
import MediaPlayer

/// AirPod stem press → start/stop recording, as far as iOS allows.
///
/// **Honest limits** (see PHASE1_RESEARCH.md): iOS gives third-party apps no API
/// for AirPods gestures. A stem press is an HID event the system turns into a
/// media transport command, and the only app that receives it is the current
/// "Now Playing" app. So the workaround is:
///
///   1. Become the Now Playing app by actually playing audio (our TTS does this)
///      and publishing `MPNowPlayingInfoCenter` metadata.
///   2. Register `togglePlayPause` / `play` / `pause` handlers on
///      `MPRemoteCommandCenter` and treat any of them as "the person squeezed
///      the stem".
///
/// This works, but it is a borrowed channel, not a dedicated one: if you start
/// Spotify, Spotify becomes the Now Playing app and the stem stops reaching us
/// until this app plays audio again. There is no way around that from an app.
@MainActor
final class RemoteCommandController {
    /// Called on a stem press (or a play/pause from the Lock Screen or a car).
    var onTogglePressed: (() -> Void)?

    private var isEnabled = false

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true

        let center = MPRemoteCommandCenter.shared()
        // All three map to the same intent — different accessories send
        // different commands for the same physical press.
        for command in [
            center.togglePlayPauseCommand,
            center.playCommand,
            center.pauseCommand,
        ] {
            command.isEnabled = true
            // The handler runs outside the main actor, so hop back before
            // touching any of our state.
            _ = command.addTarget { [weak self] _ in
                Task { @MainActor in self?.onTogglePressed?() }
                return .success
            }
        }

        // Commands we explicitly don't want, so a stray swipe doesn't do
        // something surprising.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false

        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = false
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Publishing this is what makes us the Now Playing app, and what the Lock
    /// Screen shows while an answer is being read out.
    func publishNowPlaying(title: String, isPlaying: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "PocketClaude",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}
