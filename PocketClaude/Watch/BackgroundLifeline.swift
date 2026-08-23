import AVFoundation
import UIKit

/// Keeps the app running while it answers a question asked from the watch.
///
/// **Why this exists.** A recording from the wrist launches this app in the
/// background. iOS gives a backgrounded app a few seconds and then suspends it
/// — and an agent turn takes far longer than that. Suspended mid-request, the
/// connection to the relay dies and the error that surfaces is
/// "The network connection was lost", which reads like a Tailscale or Wi-Fi
/// problem and is nothing of the kind. The network was fine; the app was
/// stopped.
///
/// Two things hold it open, because one is not enough:
///
/// 1. A **background task assertion** buys roughly thirty seconds of
///    guaranteed runtime. Enough for a short question, not for a real turn.
/// 2. **Silent playback** keeps the app alive for as long as it lasts, which
///    is what the `audio` background mode is for. This is the same trick
///    `NowPlayingKeeper` uses to hold the AirPod stem, and the reason the app
///    declares that mode at all.
///
/// The cost is honest: while this runs, other audio is interrupted. That is
/// already true a moment later when the answer is spoken aloud, so the window
/// where it matters is the wait rather than anything new.
@MainActor
final class BackgroundLifeline {
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var player: AVAudioPlayer?
    /// Whether this started the silence. Something else may already be holding
    /// the slot — the stem-press keeper — and stopping that on the way out
    /// would take the stem away with it.
    private var startedSilence = false

    func begin() {
        if task == .invalid {
            task = UIApplication.shared.beginBackgroundTask(withName: "Answering from the watch") {
                // Fires when iOS runs out of patience. Ending it here is
                // mandatory: an assertion left open is a termination.
                self.end()
            }
        }

        guard player == nil else { return }
        try? AudioSessionController.configureForHoldingNowPlaying()
        guard let silence = try? AVAudioPlayer(data: NowPlayingKeeper.silentWAV()) else { return }
        silence.numberOfLoops = -1
        silence.volume = 0
        silence.prepareToPlay()
        silence.play()
        player = silence
        startedSilence = true
    }

    func end() {
        if startedSilence {
            player?.stop()
            startedSilence = false
        }
        player = nil
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }
}
