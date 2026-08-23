import AVFoundation
import Combine
import Foundation

/// Non-secret user preferences. Secrets never come near this type — they live in
/// `KeychainStore` and are read on demand.
///
/// Swift note: `@Published` + `ObservableObject` is roughly a Zustand/Redux store
/// that SwiftUI views subscribe to automatically via `@EnvironmentObject`.
final class AppSettings: ObservableObject {
    // MARK: - Model configuration

    /// Exact model IDs — never construct these by appending date suffixes.
    /// Ordered most capable first, which is also roughly most expensive first.
    ///
    /// The relay allowlists these same ids before they reach a command line, so
    /// adding one here without adding it there gets the relay's default
    /// instead — silently, which is the worst way for a picker to fail.
    enum Model: String, CaseIterable, Identifiable {
        case fable5 = "claude-fable-5"
        case opus5 = "claude-opus-5"
        case opus48 = "claude-opus-4-8"
        case sonnet5 = "claude-sonnet-5"
        case haiku45 = "claude-haiku-4-5"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fable5: return "Claude Fable 5"
            case .opus5: return "Claude Opus 5 (default)"
            case .opus48: return "Claude Opus 4.8"
            case .sonnet5: return "Claude Sonnet 5"
            case .haiku45: return "Claude Haiku 4.5"
            }
        }

        /// For the composer chip, where "Claude Opus 5 (default)" does not fit
        /// beside the other controls.
        var shortName: String {
            switch self {
            case .fable5: return "Fable 5"
            case .opus5: return "Opus 5"
            case .opus48: return "Opus 4.8"
            case .sonnet5: return "Sonnet 5"
            case .haiku45: return "Haiku 4.5"
            }
        }

        /// Adaptive thinking and the `effort` parameter arrived with Claude 4.6.
        /// Haiku 4.5 predates both and rejects them with a 400.
        var supportsAdaptiveThinking: Bool {
            switch self {
            case .fable5, .opus5, .opus48, .sonnet5: return true
            case .haiku45: return false
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

        /// Shown on the composer chip. `xhigh` is the only one whose raw value
        /// doesn't read as English.
        var displayName: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .xhigh: return "Very high"
            case .max: return "Max"
            }
        }
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
    /// Treat an AirPod stem press (a media play/pause command) as the talk
    /// button. Only works while this app is the "Now Playing" app — see
    /// RemoteCommandController for why.
    @Published var stemPressControl: Bool {
        didSet { defaults.set(stemPressControl, forKey: Keys.stemPressControl) }
    }
    /// Listen continuously for a wake phrase, so a question can be asked with
    /// the phone pocketed and no button press at all.
    @Published var wakeWordEnabled: Bool {
        didSet { defaults.set(wakeWordEnabled, forKey: Keys.wakeWordEnabled) }
    }
    @Published var wakePhrase: String {
        didSet { defaults.set(wakePhrase, forKey: Keys.wakePhrase) }
    }

    /// Leave music and podcasts playing, turned down, instead of stopping them.
    @Published var keepOtherAudioPlaying: Bool {
        didSet {
            defaults.set(keepOtherAudioPlaying, forKey: Keys.keepOtherAudioPlaying)
            AudioSessionController.keepsOtherAudioPlaying = keepOtherAudioPlaying
        }
    }

    /// Speak the confirmation prompt for write actions out loud.
    @Published var speakConfirmations: Bool {
        didSet { defaults.set(speakConfirmations, forKey: Keys.speakConfirmations) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let relayURLString = "settings.relayURL"
        static let speakIncrementally = "settings.speakIncrementally"
        static let model = "settings.model"
        static let effort = "settings.effort"
        static let voiceEngine = "settings.voiceEngine"
        static let systemVoiceIdentifier = "settings.systemVoiceIdentifier"
        static let elevenLabsVoiceID = "settings.elevenLabsVoiceID"
        static let speechRate = "settings.speechRate"
        static let preferOnDevice = "settings.preferOnDeviceRecognition"
        static let handsFreeMode = "settings.handsFreeMode"
        static let handsFreeEndKeyword = "settings.handsFreeEndKeyword"
        static let speakConfirmations = "settings.speakConfirmations"
        static let stemPressControl = "settings.stemPressControl"
        static let wakeWordEnabled = "settings.wakeWordEnabled"
        static let wakePhrase = "settings.wakePhrase"
        static let keepOtherAudioPlaying = "settings.keepOtherAudioPlaying"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.relayURLString = defaults.string(forKey: Keys.relayURLString) ?? ""
        self.speakIncrementally = defaults.object(forKey: Keys.speakIncrementally) as? Bool ?? true
        self.model = Model(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .opus5
        self.effort = Effort(rawValue: defaults.string(forKey: Keys.effort) ?? "") ?? .high
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
        self.speakConfirmations = defaults.object(forKey: Keys.speakConfirmations) as? Bool ?? true
        self.stemPressControl = defaults.bool(forKey: Keys.stemPressControl)
        self.wakeWordEnabled = defaults.bool(forKey: Keys.wakeWordEnabled)
        // Two words, both common, and unlikely as a pair in ordinary speech —
        // a one-word phrase fires on the radio.
        self.wakePhrase = defaults.string(forKey: Keys.wakePhrase) ?? "hey claude"
        self.keepOtherAudioPlaying = defaults.bool(forKey: Keys.keepOtherAudioPlaying)
        // The session controller is a namespace, not an object, so it has to be
        // told at launch rather than reading settings itself.
        AudioSessionController.keepsOtherAudioPlaying = self.keepOtherAudioPlaying
    }

    /// Whether there is enough to answer a question: an address and a token.
    /// The repository lives on the relay, so nothing about it is needed here.
    var isConfigured: Bool { isRelayConfigured }

    var isRelayConfigured: Bool {
        let trimmed = relayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, RelayAddress.isUsable(trimmed) else {
            return false
        }
        return KeychainStore.has(.relayToken)
    }
}
