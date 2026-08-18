import Foundation
import WatchConnectivity

/// Sends a question to the phone and waits for the answer.
///
/// `sendMessage` is used rather than `transferUserInfo` because it can wake the
/// iOS app in the background and deliver a reply — which is exactly the shape
/// of this: ask, wait, hear. The trade is that it needs the phone reachable,
/// so failures are reported rather than queued silently.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    @Published private(set) var status = "Tap Ask, then speak."
    @Published private(set) var isBusy = false
    @Published private(set) var isError = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard WCSession.default.isReachable else {
            fail("iPhone isn't reachable. Is it nearby and unlocked at least once since restart?")
            return
        }

        isBusy = true
        isError = false
        status = "Asking…"

        WCSession.default.sendMessage(
            ["question": trimmed],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    guard let self else { return }
                    self.isBusy = false
                    if let answer = reply["answer"] as? String, !answer.isEmpty {
                        self.isError = false
                        // The phone speaks the full answer through your earbud.
                        // This is only so the wrist shows something happened.
                        self.status = answer
                    } else {
                        self.fail(reply["error"] as? String ?? "No answer came back.")
                    }
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.isBusy = false
                    self?.fail(error.localizedDescription)
                }
            }
        )
    }

    private func fail(_ message: String) {
        isError = true
        isBusy = false
        status = message
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.fail("Couldn't reach the phone: \(error.localizedDescription)")
        }
    }
}
