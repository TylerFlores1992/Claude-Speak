import Foundation
import SwiftUI

/// The glue: microphone → Claude → GitHub tools → AirPod.
///
/// Swift note: `@MainActor` on the class means every property and method is
/// hopped onto the main thread automatically, which is what SwiftUI needs. The
/// slow work (`AgentRunner`) is `async` and runs off-main between suspensions.
@MainActor
final class ConversationViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case working(String)
        case awaitingConfirmation(String)
        case speaking

        var isBusy: Bool {
            switch self {
            case .idle, .listening: return false
            case .working, .awaitingConfirmation, .speaking: return true
            }
        }
    }

    // MARK: - Published state

    @Published private(set) var state: State = .idle
    @Published private(set) var session: Session
    @Published private(set) var liveTranscript: String = ""
    @Published var errorMessage: String?
    @Published var isShowingSettings = false

    // MARK: - Collaborators

    let settings: AppSettings
    let recognizer: SpeechRecognizerService
    let speech: SpeechService
    private let remoteCommands = RemoteCommandController()

    private let store: SessionStore
    private var anthropic = AnthropicClient()
    private var github = GitHubClient()
    private var executor: ToolExecutor?
    private var executorRepoSlug: String?

    /// Resumed by `resolveConfirmation` when the person approves or declines.
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    /// Non-nil exactly while a write is waiting on the person. Doubles as the
    /// flag that routes the microphone to a yes/no answer instead of a question.
    private var pendingConfirmationPrompt: String?

    private var handsFreeTask: Task<Void, Never>?

    /// Swift note: `recognizer` and `speech` take `nil` defaults and are built in
    /// the body rather than as default argument values. A default argument
    /// expression is evaluated at the *call site* in a nonisolated context, so
    /// `SpeechService()` there is "call to main actor-isolated initializer in a
    /// synchronous nonisolated context" — even though this whole class is
    /// `@MainActor`. The init body, by contrast, is main-actor isolated, so
    /// constructing them here is fine. Tests can still inject their own.
    init(
        settings: AppSettings = AppSettings(),
        recognizer: SpeechRecognizerService? = nil,
        speech: SpeechService? = nil,
        store: SessionStore = SessionStore()
    ) {
        self.settings = settings
        self.recognizer = recognizer ?? SpeechRecognizerService()
        self.speech = speech ?? SpeechService()
        self.store = store
        self.session = store.load() ?? Session(model: settings.model.rawValue)
    }

    // MARK: - Permissions

    func prepare() async {
        applyStemPressSetting()
        do {
            try await recognizer.requestPermissions()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - AirPod stem press

    /// Wires (or unwires) media transport commands to the talk button. See
    /// RemoteCommandController for what iOS does and does not allow here.
    func applyStemPressSetting() {
        guard settings.stemPressControl else {
            remoteCommands.disable()
            return
        }
        remoteCommands.onTogglePressed = { [weak self] in
            guard let self else { return }
            switch self.state {
            case .listening: self.endListening()
            // Awaiting a confirmation also opens the mic — that's how you say
            // "confirm" without taking the phone out.
            case .idle, .awaitingConfirmation: self.beginListening()
            case .speaking: self.speech.stop()
            case .working: break
            }
        }
        remoteCommands.enable()
    }

    // MARK: - Push to talk

    func beginListening() {
        // Two entry points: idle (a new question) and awaiting confirmation
        // (answering "confirm" / "cancel" by voice). Everything else is busy.
        switch state {
        case .idle, .awaitingConfirmation:
            break
        case .listening, .working, .speaking:
            return
        }

        // Talking over the agent cancels its answer — that's the point of a
        // push-to-talk loop you can interrupt.
        speech.stop()
        do {
            try recognizer.start(preferOnDevice: settings.preferOnDeviceRecognition)
            state = .listening
            observeLiveTranscript()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Don't drop a pending confirmation on the floor if the mic failed.
            state = pendingConfirmationPrompt.map(State.awaitingConfirmation) ?? .idle
        }
    }

    func endListening() {
        guard case .listening = state else { return }
        Task {
            let text = await recognizer.stopAndAwaitTranscript()
            liveTranscript = ""

            // A pending confirmation turns the mic into a yes/no answer.
            if pendingConfirmationPrompt != nil {
                handleSpokenConfirmation(text)
                return
            }

            guard !text.isEmpty else {
                state = .idle
                return
            }
            await send(text)
        }
    }

    func cancelListening() {
        recognizer.cancel()
        liveTranscript = ""
        if case .listening = state {
            state = pendingConfirmationPrompt.map(State.awaitingConfirmation) ?? .idle
        }
    }

    /// Mirrors the recognizer's live transcript into our own published property
    /// so the view has one source of truth to bind to.
    private func observeLiveTranscript() {
        Task { [weak self] in
            guard let self else { return }
            while self.recognizer.isRecording {
                self.liveTranscript = self.recognizer.transcript
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            self.liveTranscript = ""
        }
    }

    // MARK: - Hands-free mode

    /// Keeps the recognizer running and sends when the end keyword is heard.
    /// Foreground only — iOS will not keep a microphone tap alive in the
    /// background for an app like this. See DECISIONS.md.
    func startHandsFree() {
        guard handsFreeTask == nil else { return }
        handsFreeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.settings.handsFreeMode {
                if self.state == .idle {
                    self.beginListening()
                    await self.waitForEndKeyword()
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stopHandsFree() {
        handsFreeTask?.cancel()
        handsFreeTask = nil
        cancelListening()
    }

    private func waitForEndKeyword() async {
        let keyword = settings.handsFreeEndKeyword.lowercased()
        while recognizer.isRecording && !Task.isCancelled {
            let heard = recognizer.transcript.lowercased()
            if heard.hasSuffix(keyword) || heard.hasSuffix("\(keyword).") {
                endListening()
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Sending a turn

    func send(_ text: String) async {
        guard !text.isEmpty else { return }
        guard let repository = settings.repository else {
            errorMessage = "Set your repository (owner/repo) in Settings first."
            state = .idle
            isShowingSettings = true
            return
        }
        guard KeychainStore.has(.anthropicAPIKey) else {
            errorMessage = AnthropicError.missingAPIKey.errorDescription
            state = .idle
            isShowingSettings = true
            return
        }
        guard KeychainStore.has(.githubToken) else {
            errorMessage = GitHubError.missingToken.errorDescription
            state = .idle
            isShowingSettings = true
            return
        }

        append(.init(kind: .user, text: text))
        session.messages.append(.userText(text))
        session.model = settings.model.rawValue
        state = .working("Thinking")

        let repo = RepositoryRef(owner: repository.owner, name: repository.name)
        let toolExecutor = makeExecutor(for: repo)

        // Fetching the default branch up front lets the system prompt name it,
        // which measurably reduces "which branch?" round trips.
        let defaultBranch = try? await toolExecutor.defaultBranch()

        let configuration = AnthropicClient.Configuration(
            model: settings.model.rawValue,
            maxTokens: settings.maxTokens,
            effort: settings.effort.rawValue,
            system: SystemPrompt.build(
                owner: repo.owner,
                repository: repo.name,
                defaultBranch: defaultBranch,
                allowWrites: settings.allowWriteTools
            ),
            tools: ToolCatalog.tools(allowWrites: settings.allowWriteTools),
            useStructuredOutput: settings.useStructuredOutput,
            supportsAdaptiveThinking: settings.model.supportsAdaptiveThinking
        )

        let runner = AgentRunner(
            anthropic: anthropic,
            executor: toolExecutor,
            allowWrites: settings.allowWriteTools
        )

        do {
            var messages = session.messages
            let result = try await runner.run(
                messages: &messages,
                configuration: configuration,
                onEvent: { [weak self] event in self?.handle(event) },
                confirm: { [weak self] call in
                    guard let self else { return false }
                    return await self.requestConfirmation(for: call)
                }
            )

            session.messages = messages
            session.usage = session.usage + result.usage
            session.model = result.model
            append(.init(
                kind: .assistant,
                text: result.response.spoken,
                detail: result.response.detail
            ))
            persist()

            state = .speaking
            if settings.stemPressControl {
                remoteCommands.publishNowPlaying(title: result.response.spoken, isPlaying: true)
            }
            speech.speak(
                result.response.spoken,
                engine: settings.voiceEngine,
                voiceIdentifier: settings.systemVoiceIdentifier,
                elevenLabsVoiceID: settings.elevenLabsVoiceID,
                rate: settings.speechRate
            )
            await waitForSpeechToFinish()
            // Only go idle if we're still the ones holding the state — the
            // person may have interrupted by starting a new question.
            if case .speaking = state { state = .idle }
        } catch {
            // Roll the failed user turn back out of the API history so the next
            // request isn't rejected for ending on an unanswered user message.
            session.messages = Array(session.messages.dropLast())
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            append(.init(kind: .error, text: message))
            persist()
            state = .idle
            speech.speak(
                "Something went wrong. Check the screen.",
                engine: .system,
                voiceIdentifier: settings.systemVoiceIdentifier,
                elevenLabsVoiceID: "",
                rate: settings.speechRate
            )
        }
    }

    private func waitForSpeechToFinish() async {
        // Give the synthesizer a beat to start before we watch for it to stop.
        try? await Task.sleep(nanoseconds: 200_000_000)
        while speech.isSpeaking {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // MARK: - Agent events

    private func handle(_ event: AgentEvent) {
        switch event {
        case .thinking:
            state = .working("Thinking")
        case .toolStarted(let name, let detail):
            let label = name.replacingOccurrences(of: "_", with: " ")
            state = .working(detail.isEmpty ? label : "\(label): \(detail)")
            append(.init(kind: .tool, text: detail.isEmpty ? label : "\(label) — \(detail)"))
        case .toolFinished(let name, let succeeded):
            if !succeeded {
                append(.init(kind: .status, text: "\(name) failed; Claude will adapt."))
            }
        case .awaitingConfirmation(let prompt):
            state = .awaitingConfirmation(prompt)
        case .confirmationDeclined(let name):
            append(.init(kind: .status, text: "Declined \(name)."))
        }
    }

    // MARK: - Write confirmation

    private func requestConfirmation(for call: ToolCall) async -> Bool {
        let prompt = ToolCatalog.confirmationPrompt(for: call)
        pendingConfirmationPrompt = prompt
        state = .awaitingConfirmation(prompt)
        append(.init(kind: .status, text: prompt))

        if settings.speakConfirmations {
            speech.speak(
                prompt,
                engine: settings.voiceEngine,
                voiceIdentifier: settings.systemVoiceIdentifier,
                elevenLabsVoiceID: settings.elevenLabsVoiceID,
                rate: settings.speechRate
            )
        }

        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
        }
    }

    /// Called by the Confirm / Cancel buttons.
    func resolveConfirmation(_ approved: Bool) {
        speech.stop()
        pendingConfirmationPrompt = nil
        guard let continuation = confirmationContinuation else { return }
        confirmationContinuation = nil
        state = .working(approved ? "Applying" : "Cancelling")
        continuation.resume(returning: approved)
    }

    /// Called when the person answers a confirmation by voice.
    private func handleSpokenConfirmation(_ text: String) {
        let normalized = text.lowercased()
        let approvals = ["confirm", "yes", "do it", "go ahead", "approve", "yep", "sure"]
        let rejections = ["no", "cancel", "stop", "don't", "do not", "nope", "abort"]

        if rejections.contains(where: { normalized.contains($0) }) {
            resolveConfirmation(false)
        } else if approvals.contains(where: { normalized.contains($0) }) {
            resolveConfirmation(true)
        } else {
            // Ambiguous — ask once more rather than guessing on a write.
            if let prompt = pendingConfirmationPrompt {
                state = .awaitingConfirmation(prompt)
            }
            speech.speak(
                "I didn't catch that. Say confirm or cancel.",
                engine: settings.voiceEngine,
                voiceIdentifier: settings.systemVoiceIdentifier,
                elevenLabsVoiceID: settings.elevenLabsVoiceID,
                rate: settings.speechRate
            )
        }
    }

    // MARK: - Session management

    func newSession() {
        speech.stop()
        cancelListening()
        // A dangling confirmation would leak its continuation forever.
        if confirmationContinuation != nil { resolveConfirmation(false) }
        session = Session(model: settings.model.rawValue)
        store.clear()
        state = .idle
        errorMessage = nil
    }

    func repeatLastAnswer() {
        guard let last = session.transcript.last(where: { $0.kind == .assistant }) else { return }
        state = .speaking
        speech.speak(
            last.text,
            engine: settings.voiceEngine,
            voiceIdentifier: settings.systemVoiceIdentifier,
            elevenLabsVoiceID: settings.elevenLabsVoiceID,
            rate: settings.speechRate
        )
        Task {
            await waitForSpeechToFinish()
            if case .speaking = state { state = .idle }
        }
    }

    /// Text entry fallback — useful for long repo names and when you can't talk.
    func sendTyped(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !state.isBusy else { return }
        Task { await send(trimmed) }
    }

    // MARK: - Internals

    private func makeExecutor(for repo: RepositoryRef) -> ToolExecutor {
        if let executor, executorRepoSlug == repo.slug { return executor }
        let fresh = ToolExecutor(client: github, repo: repo)
        executor = fresh
        executorRepoSlug = repo.slug
        return fresh
    }

    private func append(_ entry: TranscriptEntry) {
        session.transcript.append(entry)
    }

    private func persist() {
        store.save(session)
    }
}
