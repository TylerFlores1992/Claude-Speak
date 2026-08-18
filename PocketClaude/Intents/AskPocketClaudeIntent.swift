import AppIntents
import Foundation

/// "Hey Siri, ask PocketClaude what the hold lifecycle does."
///
/// **Why this exists.** Starting a take with our own microphone needs the screen
/// on: holding the AirPod stem-press channel requires a playback audio session,
/// capturing requires a recording one, and a backgrounded app on a locked phone
/// cannot acquire the microphone by switching between them. Those three don't
/// reconcile, so the pocket loop died at the lock screen.
///
/// Siri has none of those problems. Its speech recognition is a system service
/// that already works locked — that is its entire job — and it hands us a
/// finished string. No microphone of ours, no Now Playing slot, no audio route
/// to renegotiate. Siri also speaks the answer, so the text-to-speech path is
/// out of the picture too.
///
/// What it gives up: no live transcript on screen, no interrupting mid-answer,
/// and Siri's own limits on how long a spoken reply can be.
struct AskPocketClaudeIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask PocketClaude"
    static var description = IntentDescription(
        "Asks your Claude Code relay a question about your repository and reads the answer back."
    )

    /// False so the question can be answered without unlocking. Opening the app
    /// would require Face ID and defeat the point — a lock-screen button that
    /// makes you unlock is just a slower way to tap the icon.
    static var openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask PocketClaude \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "I didn't catch a question.")
        }

        let settings = AppSettings()
        guard let client = RelayClient.make(settings: settings) else {
            return .result(
                dialog: "The relay isn't set up. Open PocketClaude and add the relay address and token in Settings."
            )
        }

        do {
            // Resuming keeps "and how does that get tested?" meaning something.
            // Stored separately from the in-app conversation: a question asked
            // through Siri shouldn't silently rewrite the thread you have open
            // on screen.
            let previous = UserDefaults.standard.string(forKey: Self.sessionKey)
            let result = try await client.ask(text: trimmed, sessionID: previous) { _ in }

            if let id = result.sessionId {
                UserDefaults.standard.set(id, forKey: Self.sessionKey)
            }

            let answer = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !answer.isEmpty else {
                return .result(dialog: "The relay finished without an answer.")
            }
            // Markdown read aloud is noise — the same cleaning the in-app voice
            // path uses.
            let spoken = ResponseParser.sanitizeForSpeech(answer)
            return .result(dialog: IntentDialog(stringLiteral: spoken))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return .result(dialog: IntentDialog(stringLiteral: message))
        }
    }

    /// Deliberately not the in-app session. See `perform`.
    private static let sessionKey = "intent.relaySessionID"
}

/// Registers the spoken phrases, so this works without you building a Shortcut
/// by hand.
struct PocketClaudeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPocketClaudeIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "\(.applicationName) question",
            ],
            shortTitle: "Ask PocketClaude",
            systemImageName: "mic.circle"
        )
    }
}
