import AVFoundation
import Foundation
import Speech

/// Push-to-talk speech capture built on Apple's `Speech` framework.
///
/// On-device recognition is requested when the locale supports it, which keeps
/// audio off Apple's servers and works with no signal. Not every locale has an
/// on-device model, so we fall back rather than fail.
@MainActor
final class SpeechRecognizerService: NSObject, ObservableObject {
    enum RecognizerError: LocalizedError {
        case notAuthorized
        case microphoneDenied
        case unavailable

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition permission was denied. Enable it in iOS Settings → PocketClaude."
            case .microphoneDenied:
                return "Microphone permission was denied. Enable it in iOS Settings → PocketClaude."
            case .unavailable:
                return "Speech recognition is unavailable on this device right now."
            }
        }
    }

    /// Live transcript, updated as you speak.
    @Published private(set) var transcript: String = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isOnDevice = false

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Resumed once the final result lands (or the fallback timer fires).
    private var finalContinuation: CheckedContinuation<String, Never>?
    private var finalTimeoutTask: Task<Void, Never>?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        super.init()
    }

    var supportsOnDeviceRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    // MARK: - Permissions

    /// Ask for both permissions up front, so the first press-and-hold works.
    func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { throw RecognizerError.notAuthorized }

        let micGranted = await withCheckedContinuation { continuation in
            // iOS 17 replacement for AVAudioSession.requestRecordPermission.
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micGranted else { throw RecognizerError.microphoneDenied }
    }

    // MARK: - Recording

    func start(preferOnDevice: Bool) throws {
        guard !isRecording else { return }
        guard let recognizer, recognizer.isAvailable else { throw RecognizerError.unavailable }

        // Clean up anything left over from a previous take.
        reset()
        transcript = ""

        try AudioSessionController.configureForRecording()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if preferOnDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            isOnDevice = true
        } else {
            isOnDevice = false
        }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The Speech framework calls back off the main actor, so read the
            // values here and do all the mutation on the main actor.
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil

            Task { @MainActor in
                if let text { self.transcript = text }
                if isFinal || failed { self.finish(with: self.transcript) }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }

    /// Stops capture and waits briefly for the recognizer's final pass, which is
    /// usually more accurate than the last partial result.
    func stopAndAwaitTranscript(timeout: TimeInterval = 1.2) async -> String {
        guard isRecording else { return transcript }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRecording = false

        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            finalContinuation = continuation
            // Safety net: if the recognizer never delivers a final result we
            // would otherwise hang here forever.
            finalTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                self.finish(with: self.transcript)
            }
        }

        reset()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abandon the current take without producing a transcript.
    func cancel() {
        guard isRecording || task != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRecording = false
        finish(with: "")
        reset()
        transcript = ""
    }

    // MARK: - Internals

    /// Resumes the pending continuation exactly once.
    private func finish(with text: String) {
        finalTimeoutTask?.cancel()
        finalTimeoutTask = nil
        guard let continuation = finalContinuation else { return }
        finalContinuation = nil
        continuation.resume(returning: text)
    }

    private func reset() {
        task?.cancel()
        task = nil
        request = nil
    }
}
