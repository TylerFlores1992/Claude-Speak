import Foundation
import WatchConnectivity

/// The phone's side of the watch button.
///
/// The watch captures the question with Apple's dictation and hands it here.
/// The phone owns the relay connection — it is the device on the tailnet — and
/// it owns the earbud, so it answers and speaks the reply.
///
/// `sendMessage` from the watch can wake this app in the background, which is
/// what makes the wrist button work with the phone pocketed and locked. The
/// microphone is never involved on this side, so none of the audio-session
/// constraints that stop a locked phone starting its own take apply.
@MainActor
final class PhoneLink: NSObject, ObservableObject {
    /// Set by the app so a question from the wrist runs through exactly the
    /// same path as one asked on screen — same relay, same transcript, same
    /// spoken answer.
    var onQuestion: ((String) async -> String)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so switching watches doesn't quietly break the button.
        WCSession.default.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let question = message["question"] as? String else {
            replyHandler(["error": "No question in the message."])
            return
        }

        Task { @MainActor in
            guard let handler = onQuestion else {
                replyHandler(["error": "The app wasn't ready."])
                return
            }
            let answer = await handler(question)
            replyHandler(answer.isEmpty ? ["error": "No answer came back."] : ["answer": answer])
        }
    }
}
