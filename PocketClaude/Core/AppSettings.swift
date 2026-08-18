import Foundation
import Combine

/// Non-secret user preferences. Secrets never come near this type — they live in
/// `KeychainStore` and are read on demand.
///
/// Swift note: `@Published` + `ObservableObject` is roughly a Zustand/Redux store
/// that SwiftUI views subscribe to automatically via `@EnvironmentObject`.
final class AppSettings: ObservableObject {
    // MARK: - Model configuration

    /// Exact model IDs — never construct these by appending date suffixes.
    enum Model: String, CaseIterable, Identifiable {
        case opus5 = "claude-opus-5"
        case sonnet5 = "claude-sonnet-5"
        case haiku45 = "claude-haiku-4-5"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .opus5: return "Claude Opus 5 (default)"
            case .sonnet5: return "Claude Sonnet 5"
            case .haiku45: return "Claude Haiku 4.5"
            }
        }

        /// Adaptive thinking and the `effort` parameter arrived with Claude 4.6.
        /// Haiku 4.5 predates both and rejects them with a 400.
        var supportsAdaptiveThinking: Bool {
            switch self {
            case .opus5, .sonnet5: return true
            case .haiku45: return false
            }
        }
    }

    /// Where answers come from.
    ///
    /// `directAPI` calls Anthropic from the phone and is billed per token.
    /// `relay` calls your own machine, which runs the Claude Code CLI on your
    /// subscription — no per-question charge, and it can run your tests.
    enum Backend: String, CaseIterable, Identifiable {
        case directAPI
        case relay

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .directAPI: return "Direct API"
            case .relay: return "Relay (Claude Code)"
            }
        }
    }

    /// `output_config.effort` — controls how much thinking and tool work Claude
    /// does per turn. Higher costs more tokens and takes longer.
    /// Applies to the direct-API path only; the relay's model config lives on
    /// the server, where Claude Code owns it.
    enum Effort: String, CaseIterable, Identifiable {
        case low, medium, high, xhigh, max
        var id: String { rawValue }
    }

    enum VoiceEngine: String, CaseIterable, Identifiable {
        case system // AVSpeechSynthesizer — free, offline
        case elevenLabs
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "System voice (free)"
            case .elevenLabs: return "ElevenLabs"
            }
        }
    }

    @Published var backend: Backend {
        didSet { defaults.set(backend.rawValue, forKey: Keys.backend) }
    }
    /// e.g. `http://mini-pc:8787` — a Tailscale name keeps it off the internet.
    @Published var relayURLString: String {
        didSet { defaults.set(relayURLString, forKey: Keys.relayURLString) }
    }
    /// Speak each sentence as it streams in, rather than waiting for the end.
    @Published var speakIncrementally: Bool {
        didSet { defaults.set(speakIncrementally, forKey: Keys.speakIncrementally) }
    }

    @Published var model: Model {
        didSet { defaults.set(model.rawValue, forKey: Keys.model) }
    }
    @Published var effort: Effort {
        didSet { defaults.set(effort.rawValue, forKey: Keys.effort) }
    }
    @Published var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: Keys.maxTokens) }
    }
    /// `owner/repo`, e.g. `tylerflores1992/camphawk`.
    @Published var repositorySlug: String {
        didSet { defaults.set(repositorySlug, forKey: Keys.repositorySlug) }
    }
    /// When true, the agent may propose write actions (branch/commit/PR).
    /// Every write still requires an explicit confirmation at execution time.
    @Published var allowWriteTools: Bool {
        didSet { defaults.set(allowWriteTools, forKey: Keys.allowWriteTools) }
    }
    @Published var voiceEngine: VoiceEngine {
        didSet { defaults.set(voiceEngine.rawValue, forKey: Keys.voiceEngine) }
    }
    @Published var systemVoiceIdentifier: String {
        didSet { defaults.set(systemVoiceIdentifier, forKey: Keys.systemVoiceIdentifier) }
    }
    @Published var elevenLabsVoiceID: String {
        didSet { defaults.set(elevenLabsVoiceID, forKey: Keys.elevenLabsVoiceID) }
    }
    @Published var speechRate: Double {
        didSet { defaults.set(speechRate, forKey: Keys.speechRate) }
    }
    /// Prefer Apple's on-device recognizer when the locale supports it.
    @Published var preferOnDeviceRecognition: Bool {
        didSet { defaults.set(preferOnDeviceRecognition, forKey: Keys.preferOnDevice) }
    }
    /// Hands-free mode: keep the recognizer running and send on the end keyword.
    @Published var handsFreeMode: Bool {
        didSet { defaults.set(handsFreeMode, forKey: Keys.handsFreeMode) }
    }
    @Published var handsFreeEndKeyword: String {
        didSet { defaults.set(handsFreeEndKeyword, forKey: Keys.handsFreeEndKeyword) }
    }
    /// Ask the API to constrain the final answer to our JSON schema. Off by
    /// default — see DECISIONS.md ("Structured output is opt-in").
    @Published var useStructuredOutput: Bool {
        didSet { defaults.set(useStructuredOutput, forKey: Keys.useStructuredOutput) }
    }
    /// Treat an AirPod stem press (a media play/pause command) as the talk
    /// button. Only works while this app is the "Now Playing" app — see
    /// RemoteCommandController for why.
    @Published var stemPressControl: Bool {
        didSet { defaults.set(stemPressControl, forKey: Keys.stemPressControl) }
    }
    /// Speak the confirmation prompt for write actions out loud.
    @Published var speakConfirmations: Bool {
        didSet { defaults.set(speakConfirmations, forKey: Keys.speakConfirmations) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let backend = "settings.backend"
        static let relayURLString = "settings.relayURL"
        static let speakIncrementally = "settings.speakIncrementally"
        static let model = "settings.model"
        static let effort = "settings.effort"
        static let maxTokens = "settings.maxTokens"
        static let repositorySlug = "settings.repositorySlug"
        static let allowWriteTools = "settings.allowWriteTools"
        static let voiceEngine = "settings.voiceEngine"
        static let systemVoiceIdentifier = "settings.systemVoiceIdentifier"
        static let elevenLabsVoiceID = "settings.elevenLabsVoiceID"
        static let speechRate = "settings.speechRate"
        static let preferOnDevice = "settings.preferOnDeviceRecognition"
        static let handsFreeMode = "settings.handsFreeMode"
        static let handsFreeEndKeyword = "settings.handsFreeEndKeyword"
        static let useStructuredOutput = "settings.useStructuredOutput"
        static let speakConfirmations = "settings.speakConfirmations"
        static let stemPressControl = "settings.stemPressControl"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backend = Backend(rawValue: defaults.string(forKey: Keys.backend) ?? "") ?? .directAPI
        self.relayURLString = defaults.string(forKey: Keys.relayURLString) ?? ""
        self.speakIncrementally = defaults.object(forKey: Keys.speakIncrementally) as? Bool ?? true
        self.model = Model(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .opus5
        self.effort = Effort(rawValue: defaults.string(forKey: Keys.effort) ?? "") ?? .high
        let storedMaxTokens = defaults.integer(forKey: Keys.maxTokens)
        self.maxTokens = storedMaxTokens > 0 ? storedMaxTokens : 16_000
        self.repositorySlug = defaults.string(forKey: Keys.repositorySlug) ?? ""
        self.allowWriteTools = defaults.object(forKey: Keys.allowWriteTools) as? Bool ?? true
        self.voiceEngine = VoiceEngine(rawValue: defaults.string(forKey: Keys.voiceEngine) ?? "") ?? .system
        self.systemVoiceIdentifier = defaults.string(forKey: Keys.systemVoiceIdentifier) ?? ""
        self.elevenLabsVoiceID = defaults.string(forKey: Keys.elevenLabsVoiceID) ?? ""
        let storedRate = defaults.double(forKey: Keys.speechRate)
        self.speechRate = storedRate > 0 ? storedRate : 0.52
        // Off by default. On-device recognition keeps audio off Apple's
        // servers, which is the better property — but on device it reported
        // partial results and then finalised to an empty transcript, so the
        // words appeared, vanished, and the question was never sent. A default
        // that silently loses what you said is worse than one that transcribes
        // in the cloud. Turn it on if it works for you.
        self.preferOnDeviceRecognition = defaults.object(forKey: Keys.preferOnDevice) as? Bool ?? false
        self.handsFreeMode = defaults.bool(forKey: Keys.handsFreeMode)
        self.handsFreeEndKeyword = defaults.string(forKey: Keys.handsFreeEndKeyword) ?? "done"
        self.useStructuredOutput = defaults.bool(forKey: Keys.useStructuredOutput)
        self.speakConfirmations = defaults.object(forKey: Keys.speakConfirmations) as? Bool ?? true
        self.stemPressControl = defaults.bool(forKey: Keys.stemPressControl)
    }

    /// Split `owner/repo` into its parts. Returns nil when unset or malformed.
    var repository: (owner: String, name: String)? {
        let parts = repositorySlug
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// Whether the selected backend has everything it needs to answer a question.
    /// The two paths need entirely different things, so this switches on mode
    /// rather than demanding the union of both.
    var isConfigured: Bool {
        switch backend {
        case .directAPI:
            return KeychainStore.has(.anthropicAPIKey)
                && KeychainStore.has(.githubToken)
                && repository != nil
        case .relay:
            return isRelayConfigured
        }
    }

    /// The relay needs an address and a token; the repository lives on the
    /// server, so `repositorySlug` is irrelevant in this mode.
    var isRelayConfigured: Bool {
        let trimmed = relayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return false
        }
        return KeychainStore.has(.relayToken)
    }
}
