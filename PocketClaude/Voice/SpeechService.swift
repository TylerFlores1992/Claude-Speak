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

    /// Cancels any speech in progress. Safe to call when nothing is playing.
    func stop() {
        remoteTask?.cancel()
        remoteTask = nil
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
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
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
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }
}

// MARK: - AVAudioPlayerDelegate

extension SpeechService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }
}
