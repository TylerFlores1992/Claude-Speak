import AudioToolbox

/// Short tones marking the start and end of a take.
///
/// With the phone pocketed there is nothing to look at, and opening the
/// microphone is not instant — the audio route needs a moment to settle after
/// the switch to recording. Without a cue you are guessing whether it heard
/// you, and the usual reaction is to start talking too early and lose the first
/// word.
///
/// These are the system's own record-start and record-stop tones, the ones
/// Siri and Voice Memos use, so they already sound like "it's listening" rather
/// than like a notification.
enum Cues {
    /// Played once the microphone is genuinely open — not when the button is
    /// pressed. That distinction is the whole point: it says "talk now".
    static func listening() {
        AudioServicesPlaySystemSound(1113)
    }

    /// Played when the take ends and the question is on its way.
    static func stoppedListening() {
        AudioServicesPlaySystemSound(1114)
    }
}
