import Foundation
import WatchConnectivity

/// Sends a recording to the phone and waits for the answer.
///
/// The watch captures audio; the phone transcribes it, asks Claude, and speaks
/// the reply into your earbud. The phone is the device on the tailnet and the
/// one holding the earbud, so that split is not a choice so much as the only
/// arrangement that works.
///
/// `transferFile` rather than `sendMessage`: a recording is too big for a
/// message, and file transfer is queued and retried by the system, so walking
/// out of Bluetooth range delays a question instead of losing it. The answer
/// comes back as a separate message, since a transfer has no reply channel.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    @Published private(set) var status = "Tap Ask, then speak."
    @Published private(set) var isBusy = false
    @Published private(set) var isError = false

    /// Clears `isBusy` if nothing comes back. Without it, one lost message
    /// leaves the Ask button greyed out for the life of the app - which is
    /// exactly what happened when the phone dropped answers to an unreachable
    /// watch.
    private var watchdog: Task<Void, Never>?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func ask(recording url: URL) {
        isBusy = true
        isError = false
        status = "Sending…"
        WCSession.default.transferFile(url, metadata: ["kind": "question"])

        // Generous: a real agent turn can take minutes, and cutting it short
        // would say "no answer" while one was still being written. This is a
        // stuck-button guard, not a deadline.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.isBusy else { return }
            self.fail("No answer came back. Tap Ask to try again.")
        }
    }

    private func fail(_ message: String) {
        watchdog?.cancel()
        watchdog = nil
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

    /// The phone reports the transfer landed, or why it did not.
    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        // The queued copy is ours to clean up either way; leaving them behind
        // fills the watch with recordings nobody will ever hear.
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.fail("Couldn't send that: \(error.localizedDescription)")
        }
    }

    /// The answer, sent back separately because a file transfer has no reply.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in self?.handle(message) }
    }

    /// The same payload, queued rather than sent live. This is the route an
    /// answer takes when the watch was asleep when it was ready.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor [weak self] in self?.handle(userInfo) }
    }

    /// One place both delivery routes land, so a live message and a queued one
    /// cannot drift apart in how they are handled.
    @MainActor
    private func handle(_ message: [String: Any]) {
        if let answer = message["answer"] as? String, !answer.isEmpty {
            watchdog?.cancel()
            watchdog = nil
            isBusy = false
            isError = false
            // The phone speaks the full answer through your earbud. This is
            // only so the wrist shows something happened.
            status = answer
        } else if let heard = message["heard"] as? String, !heard.isEmpty {
            // Still working. Stays busy on purpose: this only confirms what was
            // understood, and clearing the spinner here would claim the
            // question was answered when it has not been asked yet.
            status = "\u{201C}\(heard)\u{201D}"
        } else if let problem = message["error"] as? String {
            fail(problem)
        }
    }
}
