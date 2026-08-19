import Foundation
import Speech
import WatchConnectivity

/// The phone's side of the watch button.
///
/// The watch records audio and sends the file here. Transcription happens on
/// this side rather than the watch because steering watchOS's own dictation did
/// not work - the documented way to open it directly now opens Scribble - and
/// because the phone already has the speech stack this app depends on.
/// The phone owns the relay connection — it is the device on the tailnet — and
/// it owns the earbud, so it answers and speaks the reply.
///
/// A transfer from the watch can wake this app in the background, which is what
/// makes the wrist button work with the phone pocketed and locked. The phone's
/// microphone is never involved, so none of the audio-session constraints that
/// stop a locked phone starting its own take apply here — the audio was already
/// captured on the wrist.
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

    /// A recording from the wrist.
    ///
    /// The file lives in a system inbox that is deleted the moment this method
    /// returns, so it has to be copied before anything asynchronous happens -
    /// transcription included.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString).m4a")
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: copy)
        } catch {
            Self.reply(["error": "Couldn't read the recording."])
            return
        }

        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: copy) }

            let heard: String
            do {
                heard = try await PhoneLink.transcribe(copy)
            } catch {
                Self.reply(["error": "Couldn't make out any words."])
                return
            }
            guard !heard.isEmpty else {
                Self.reply(["error": "Couldn't make out any words."])
                return
            }

            // Show what was understood before the answer exists, so a
            // misheard question is obvious immediately rather than after a
            // minute of waiting for an answer to the wrong thing.
            Self.reply(["heard": heard])

            guard let handler = onQuestion else {
                Self.reply(["error": "The app wasn't ready."])
                return
            }
            let answer = await handler(heard)
            Self.reply(answer.isEmpty ? ["error": "No answer came back."] : ["answer": answer])
        }
    }

    /// Best-effort message back to the watch. A transfer has no reply channel,
    /// and the watch may have gone to sleep, so failing to deliver a status
    /// line is not worth surfacing anywhere.
    private nonisolated static func reply(_ payload: [String: Any]) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: { _ in })
    }

    /// Transcribes a recorded file.
    ///
    /// `SFSpeechURLRecognitionRequest` rather than the live audio path: the
    /// audio is already captured, and a file has none of the audio-session
    /// conflicts that make live capture fragile on a locked phone.
    private static func transcribe(_ url: URL) async throws -> String {
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw RecognitionError.unavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            // Guard against the double-resume that a recogniser reporting both
            // a final result and an error would otherwise cause - which traps.
            var settled = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !settled else { return }
                if let error {
                    settled = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                settled = true
                continuation.resume(
                    returning: result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    enum RecognitionError: Error { case unavailable }
}
