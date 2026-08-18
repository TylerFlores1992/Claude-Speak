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

    @Published private(set) var state: State = .idle {
        didSet {
            // Recording switches the session to `.playAndRecord`, which stops
            // the silent loop — and losing it means the *next* squeeze goes to
            // Music instead of here. Restart whenever we come back to rest.
            if case .idle = state { nowPlaying.resumeIfNeeded() }
        }
    }
    @Published private(set) var session: Session
    @Published private(set) var liveTranscript: String = ""
    @Published var errorMessage: String?
    @Published var isShowingSettings = false

    // MARK: - Collaborators

    let settings: AppSettings
    let recognizer: SpeechRecognizerService
    let speech: SpeechService
    private let remoteCommands = RemoteCommandController()
    /// Keeps the Now Playing slot while stem control is on, so a squeeze
    /// reaches this app instead of Music.
    private let nowPlaying = NowPlayingKeeper()

    private let store: SessionStore
    private var anthropic = AnthropicClient()
    private var github = GitHubClient()
    private var executor: ToolExecutor?
    private var executorRepoSlug: String?

    /// The assistant transcript line currently being streamed into, so chunks
    /// update one entry instead of appending a line each.
    private var streamingEntryID: UUID?
    /// Text accumulated from relay chunks this turn.
    private var streamedSoFar = ""

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
        self.session = store.loadMostRecent() ?? Session(model: settings.model.rawValue)
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
            nowPlaying.stop()
            return
        }
        // Hold the Now Playing slot for as long as stem control is on. iOS
        // delivers the press only to the app holding that slot, and the slot
        // belongs to whoever is *playing* — Music keeps it even while paused,
        // so claiming it once and stopping handed it straight back.
        nowPlaying.start()
        remoteCommands.publishNowPlaying(title: "PocketClaude", isPlaying: true)

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
        // Pause the Now Playing loop across the switch to `.playAndRecord`.
        // Leaving it playing made CoreAudio renegotiate the route while the
        // microphone was being set up, and the input format read back empty —
        // which aborted the process inside `installTapOnBus:`. It restarts
        // below, once the microphone is live, so the slot is never given up.
        nowPlaying.suspend()
        // `.listening` immediately, before the microphone is actually open, so
        // a second squeeze arriving during the quarter-second the route needs
        // to settle doesn't start a second take on top of the first.
        state = .listening
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recognizer.start(
                    preferOnDevice: self.settings.preferOnDeviceRecognition
                )
                // The take may have been ended while the route was settling.
                // Without this the microphone would stay open with the app
                // showing idle.
                guard case .listening = self.state else {
                    self.recognizer.cancel()
                    self.nowPlaying.resume(reassertCategory: true)
                    return
                }
                self.nowPlaying.resume(reassertCategory: false)
                // Only now is the microphone actually open. Cueing on the
                // button press instead would be a lie you'd talk over.
                Cues.listening()
                self.observeLiveTranscript()
            } catch {
                self.nowPlaying.resume(reassertCategory: true)
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                // Don't drop a pending confirmation on the floor if the mic failed.
                self.state = self.pendingConfirmationPrompt.map(State.awaitingConfirmation) ?? .idle
            }
        }
    }

    func endListening() {
        guard case .listening = state else { return }
        Cues.stoppedListening()
        Task {
            let text = await recognizer.stopAndAwaitTranscript()
            liveTranscript = ""

            // A pending confirmation turns the mic into a yes/no answer.
            if pendingConfirmationPrompt != nil {
                handleSpokenConfirmation(text)
                return
            }

            guard !text.isEmpty else {
                // Never end a take in silence. Going idle with nothing to show
                // is indistinguishable from the app ignoring you, and that is
                // exactly what it looked like on device: the words appeared,
                // then vanished, then nothing.
                errorMessage = recognizer.lastError
                    ?? "Didn't catch that — the microphone stopped before anything was recognised."
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
    /// How long the transcript must stop growing before the take is sent.
    /// Long enough to think mid-sentence, short enough not to feel stuck.
    private static let silenceBeforeSending: TimeInterval = 1.6
    /// Give up on a take where nothing was ever said.
    private static let silenceBeforeGivingUp: TimeInterval = 8
    /// Absolute ceiling, so a stuck recogniser can't hold the microphone open.
    private static let longestTake: TimeInterval = 45

    /// Mirrors the live transcript, and ends the take when you stop talking.
    ///
    /// Ending on silence rather than on a second squeeze is deliberate. Opening
    /// the microphone switches the session to `.playAndRecord`, and a recording
    /// session is not a *playing* one — so iOS stops treating this as the Now
    /// Playing app and the second press has nowhere to be delivered. Waiting
    /// for it left the app listening forever. One squeeze to start, then just
    /// stop talking; a second squeeze still works when it does arrive.
    private func observeLiveTranscript() {
        Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var lastText = ""
            var lastChange = Date()

            while self.recognizer.isRecording {
                let current = self.recognizer.transcript
                self.liveTranscript = current
                if current != lastText {
                    lastText = current
                    lastChange = Date()
                }

                let quiet = Date().timeIntervalSince(lastChange)
                let elapsed = Date().timeIntervalSince(startedAt)
                let saidSomething = !current.trimmingCharacters(in: .whitespaces).isEmpty
                let done = (saidSomething && quiet >= Self.silenceBeforeSending)
                    || (!saidSomething && quiet >= Self.silenceBeforeGivingUp)
                    || elapsed >= Self.longestTake

                if done {
                    self.endListening()
                    break
                }
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
        switch settings.backend {
        case .relay:
            await sendViaRelay(text)
        case .directAPI:
            await sendViaDirectAPI(text)
        }
    }

    // MARK: - Relay backend

    /// Asks the relay on your own machine, which runs the Claude Code CLI
    /// against a real checkout. Nothing here is billed per token — see
    /// `relay/README.md`.
    private func sendViaRelay(_ text: String) async {
        guard let client = RelayClient.make(settings: settings) else {
            errorMessage = RelayError.notConfigured.errorDescription
            state = .idle
            isShowingSettings = true
            return
        }

        append(.init(kind: .user, text: text))
        state = .working("Asking Claude Code")

        // Speaking as it arrives is the whole reason the relay streams. When
        // it's off we behave like the direct path: wait, then read the answer.
        let streaming = settings.speakIncrementally
        if streaming {
            speech.beginStreaming(
                engine: settings.voiceEngine,
                voiceIdentifier: settings.systemVoiceIdentifier,
                elevenLabsVoiceID: settings.elevenLabsVoiceID,
                rate: settings.speechRate
            )
        }

        do {
            let result = try await client.ask(
                text: text,
                sessionID: session.relaySessionID
            ) { [weak self] event in
                self?.handleRelay(event, streaming: streaming)
            }

            if let id = result.sessionId { session.relaySessionID = id }

            // The `result` field is authoritative; the streamed chunks are a
            // preview and can be missing a tail if the stream was cut short.
            let answer = result.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = (answer?.isEmpty == false ? answer! : streamedSoFar)
            guard !spoken.isEmpty else { throw RelayError.emptyResponse }

            upsertStreamingEntry(text: spoken, final: true)
            persist()

            if streaming {
                state = .speaking
                speech.finishStreaming()
            } else {
                state = .speaking
                if settings.stemPressControl {
                    remoteCommands.publishNowPlaying(title: spoken, isPlaying: true)
                }
                speech.speak(
                    spoken,
                    engine: settings.voiceEngine,
                    voiceIdentifier: settings.systemVoiceIdentifier,
                    elevenLabsVoiceID: settings.elevenLabsVoiceID,
                    rate: settings.speechRate
                )
            }
            await waitForSpeechToFinish()
            if case .speaking = state { state = .idle }
        } catch {
            speech.stop()
            streamingEntryID = nil
            streamedSoFar = ""
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            errorMessage = message
            append(.init(kind: .error, text: message))
            persist()
            state = .idle
        }
    }

    private func handleRelay(_ event: RelayEvent, streaming: Bool) {
        switch event {
        case .session(let id):
            session.relaySessionID = id

        case .chunk(let text):
            streamedSoFar += text
            // Show the answer building on screen even when speech is off.
            upsertStreamingEntry(text: streamedSoFar, final: false)
            if streaming {
                if state != .speaking { state = .speaking }
                speech.appendStreaming(text)
            }

        case .tool(let names):
            let label = names
                .map { $0.replacingOccurrences(of: "_", with: " ") }
                .joined(separator: ", ")
            // Don't stomp the speaking state once the answer has started.
            if state != .speaking { state = .working(label) }

        case .status(let text):
            if state != .speaking { state = .working(text) }
        }
    }

    /// Keeps a single assistant entry updated as text streams in, rather than
    /// appending one line per fragment.
    private func upsertStreamingEntry(text: String, final: Bool) {
        if let id = streamingEntryID,
           let index = session.transcript.firstIndex(where: { $0.id == id }) {
            session.transcript[index].text = text
        } else {
            let entry = TranscriptEntry(kind: .assistant, text: text)
            streamingEntryID = entry.id
            session.transcript.append(entry)
        }
        if final {
            streamingEntryID = nil
            streamedSoFar = ""
        }
    }

    // MARK: - Direct API backend

    private func sendViaDirectAPI(_ text: String) async {
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
        streamingEntryID = nil
        streamedSoFar = ""
        // Keep the old conversation. This used to delete it, which meant a
        // mistapped toolbar button destroyed an hour of context with no undo.
        store.save(session)
        // A fresh Session carries no relaySessionID, so the next relay question
        // starts a new Claude Code conversation rather than resuming this one.
        session = Session(model: settings.model.rawValue)
        state = .idle
        errorMessage = nil
    }

    // MARK: - Session history

    /// Everything saved, newest first. Reads the session directory, so call it
    /// when the list is shown rather than keeping it live.
    func sessionSummaries() -> [SessionSummary] {
        // Include the open conversation, which may not be on disk yet.
        var summaries = store.summaries().filter { $0.id != session.id }
        if !session.isEmpty {
            summaries.insert(SessionSummary(session), at: 0)
        }
        return summaries.sorted(by: SessionSummary.newestFirst)
    }

    /// Opens a previous conversation, saving the current one first.
    func switchToSession(id: UUID) {
        guard id != session.id else { return }
        speech.stop()
        cancelListening()
        if confirmationContinuation != nil { resolveConfirmation(false) }
        streamingEntryID = nil
        streamedSoFar = ""

        store.save(session)
        guard let restored = store.load(id: id) else {
            errorMessage = "That conversation could not be opened."
            return
        }
        session = restored
        state = .idle
        errorMessage = nil
    }

    func deleteSession(id: UUID) {
        store.delete(id: id)
        // Deleting the conversation you're in leaves you on a blank one.
        if id == session.id {
            speech.stop()
            streamingEntryID = nil
            streamedSoFar = ""
            session = Session(model: settings.model.rawValue)
            state = .idle
        }
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
