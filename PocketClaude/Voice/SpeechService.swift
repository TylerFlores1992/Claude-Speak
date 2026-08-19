import AVFoundation
import Foundation

/// Text-to-speech, with two interchangeable back ends.
///
/// Interruptibility is the point: speaking again always cancels whatever is
/// currently playing, so you can talk over a long answer and get on with it.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    /// Surfaced so the UI can fall back to the system voice visibly rather than
    /// going quiet when ElevenLabs fails.
    @Published private(set) var lastError: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var elevenLabs = ElevenLabsClient()
    /// Cancelling this aborts an in-flight ElevenLabs request.
    private var remoteTask: Task<Void, Never>?

    // Streaming state. `queuedUtterances` tracks how many utterances are still
    // in the synthesiser's queue, so `isSpeaking` only drops when the last one
    // finishes rather than the first.
    private var chunker = SpeechChunker()
    private var queuedUtterances = 0
    private var streamIsOpen = false
    private var streamedText = ""
    private var streamEngine: AppSettings.VoiceEngine = .system
    private var streamVoiceIdentifier = ""
    private var streamElevenLabsVoiceID = ""
    private var streamRate = 0.52

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speaking

    func speak(
        _ text: String,
        engine: AppSettings.VoiceEngine,
        voiceIdentifier: String,
        elevenLabsVoiceID: String,
        rate: Double
    ) {
        let cleaned = ResponseParser.sanitizeForSpeech(text)
        guard !cleaned.isEmpty else { return }

        stop()
        lastError = nil
        try? AudioSessionController.configureForPlayback()

        switch engine {
        case .system:
            speakWithSystemVoice(cleaned, voiceIdentifier: voiceIdentifier, rate: rate)
        case .elevenLabs:
            remoteTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await self.elevenLabs.synthesize(
                        text: cleaned,
                        voiceID: elevenLabsVoiceID
                    )
                    guard !Task.isCancelled else { return }
                    try self.play(data)
                } catch {
                    guard !Task.isCancelled else { return }
                    // Never leave the person in silence because a paid API failed.
                    self.lastError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    self.speakWithSystemVoice(cleaned, voiceIdentifier: voiceIdentifier, rate: rate)
                }
            }
        }
    }

    // MARK: - Streaming

    /// Opens a streaming turn: text can be fed in as it arrives and is spoken
    /// sentence by sentence, so the answer starts playing while it's still
    /// being written.
    ///
    /// Only the system voice streams. ElevenLabs bills per character and
    /// synthesises a whole clip per request, so streaming it would mean one
    /// paid HTTP round trip per sentence and audible gaps between them — that
    /// engine buffers and speaks once at `finishStreaming`.
    func beginStreaming(
        engine: AppSettings.VoiceEngine,
        voiceIdentifier: String,
        elevenLabsVoiceID: String,
        rate: Double
    ) {
        stop()
        lastError = nil
        try? AudioSessionController.configureForPlayback()

        chunker = SpeechChunker()
        streamedText = ""
        streamIsOpen = true
        streamEngine = engine
        streamVoiceIdentifier = voiceIdentifier
        streamElevenLabsVoiceID = elevenLabsVoiceID
        streamRate = rate
        // Held true for the whole turn so the caller's "wait until it stops"
        // loop doesn't exit in the gap before the first sentence completes.
        isSpeaking = true
    }

    /// Feeds one fragment into the open stream.
    func appendStreaming(_ text: String) {
        guard streamIsOpen else { return }
        streamedText += text
        guard streamEngine == .system else { return } // ElevenLabs speaks at the end.

        for utterance in chunker.append(text) {
            enqueue(utterance)
        }
    }

    /// Closes the stream and says whatever is left.
    func finishStreaming() {
        guard streamIsOpen else { return }
        streamIsOpen = false

        switch streamEngine {
        case .system:
            for utterance in chunker.flush() {
                enqueue(utterance)
            }
            // Nothing was queued and nothing is playing — the turn is silent.
            if queuedUtterances == 0 && !synthesizer.isSpeaking {
                isSpeaking = false
            }
        case .elevenLabs:
            let text = streamedText
            streamedText = ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                isSpeaking = false
                return
            }
            speak(
                text,
                engine: .elevenLabs,
                voiceIdentifier: streamVoiceIdentifier,
                elevenLabsVoiceID: streamElevenLabsVoiceID,
                rate: streamRate
            )
        }
    }

    private func enqueue(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        if !streamVoiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: streamVoiceIdentifier) {
            utterance.voice = voice
        } else {
            // Best installed voice, not the plain en-US one, which is the
            // flat default-quality voice.
            utterance.voice = SpeechService.bestAvailableVoice()
        }
        utterance.rate = Float(streamRate)
        // A short gap between sentences sounds like reading rather than a
        // single run-on breath.
        utterance.postUtteranceDelay = 0.08
        queuedUtterances += 1
        isSpeaking = true
        // AVSpeechSynthesizer queues rather than replaces, which is what makes
        // sentence-at-a-time playback continuous.
        synthesizer.speak(utterance)
    }

    /// Cancels any speech in progress. Safe to call when nothing is playing.
    func stop() {
        remoteTask?.cancel()
        remoteTask = nil
        streamIsOpen = false
        queuedUtterances = 0
        chunker = SpeechChunker()
        streamedText = ""
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }

    // MARK: - Back ends

    private func speakWithSystemVoice(_ text: String, voiceIdentifier: String, rate: Double) {
        let utterance = AVSpeechUtterance(string: text)
        if !voiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            // Best installed voice, not the plain en-US one, which is the
            // flat default-quality voice.
            utterance.voice = SpeechService.bestAvailableVoice()
        }
        // AVSpeechUtteranceDefaultSpeechRate is ~0.5; the UI slider maps 0.4–0.7.
        utterance.rate = Float(rate)
        utterance.postUtteranceDelay = 0
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    private func play(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        audioPlayer = player
        isSpeaking = true
        player.play()
    }

    /// English voices, for the settings picker. Enhanced/premium voices sound
    /// markedly better in an earbud, so they sort first.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
    }

    /// The best-sounding installed English voice.
    ///
    /// Used when no voice has been chosen. The old fallback was
    /// `AVSpeechSynthesisVoice(language: "en-US")`, which returns the *default
    /// quality* system voice — the flat, robotic one. If a Premium or Enhanced
    /// voice is installed, picking it costs nothing and sounds like a different
    /// product.
    ///
    /// Prefers en-US among equals purely so the default is stable rather than
    /// dependent on what happens to sort first.
    static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let voices = availableVoices()
        guard let best = voices.first else {
            return AVSpeechSynthesisVoice(language: "en-US")
        }
        let sameQuality = voices.filter { $0.quality == best.quality }
        return sameQuality.first { $0.language == "en-US" } ?? best
    }

    /// "Premium", "Enhanced" or "Default", for the picker.
    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.utteranceEnded() }
    }

    /// One queued utterance finished. During a stream there may be more coming,
    /// so `isSpeaking` only drops once the queue is empty *and* the stream is
    /// closed — otherwise the caller would think the answer was over after the
    /// first sentence.
    private func utteranceEnded() {
        queuedUtterances = max(0, queuedUtterances - 1)
        guard queuedUtterances == 0, !streamIsOpen else { return }
        isSpeaking = false
        // Only does anything in mixing mode. Without it the other app stays
        // ducked after the answer ends, so music comes back quiet and never
        // recovers until something else claims the route.
        AudioSessionController.releaseAfterSpeaking()
    }
}

// MARK: - AVAudioPlayerDelegate

extension SpeechService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            AudioSessionController.releaseAfterSpeaking()
        }
    }
}
