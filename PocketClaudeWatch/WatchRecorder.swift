import AVFoundation

/// Records what you say on the watch, to a file.
///
/// This exists because steering watchOS's own text input did not work. The
/// documented way to open dictation directly - presenting the text input
/// controller with nil suggestions - now opens the input picker instead, which
/// defaults to Scribble. Drawing letters is not talking, and there is no API to
/// preselect the microphone.
///
/// So the watch records audio and the phone transcribes it. More moving parts,
/// but every part is supported and none of it depends on which input mode a
/// future watchOS decides to prefer.
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var problem: String?

    private var recorder: AVAudioRecorder?
    private var destination: URL?

    /// Asks once, up front. Recording that fails silently because permission
    /// was never requested is indistinguishable from a broken button.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() {
        problem = nil
        guard !isRecording else { return }

        // A new file each time. Reusing one path meant a failed transfer could
        // send the previous question instead of this one.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("question-\(UUID().uuidString).m4a")

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            // 16 kHz mono AAC: speech recognition wants nothing better, and a
            // smaller file crosses to the phone faster.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else {
                problem = "The microphone wouldn't start."
                return
            }
            self.recorder = recorder
            self.destination = url
            isRecording = true
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Stops and returns the file, or nil if nothing usable was captured.
    func stop() -> URL? {
        guard let recorder, isRecording else { return nil }
        recorder.stop()
        self.recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)

        guard let url = destination else { return nil }
        destination = nil

        // A file of a few hundred bytes is a tap, not a question. Sending it
        // would cost a round trip to be told nothing was heard.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 2_000 else {
            try? FileManager.default.removeItem(at: url)
            problem = "That was too short - hold the button while you talk."
            return nil
        }
        return url
    }
}
