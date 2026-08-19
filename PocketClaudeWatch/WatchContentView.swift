import SwiftUI

/// One button. Tap to start talking, tap again to send.
///
/// No keyboard: typing on a watch was never the point, and the button that
/// offered it was the one that kept opening Scribble.
struct WatchContentView: View {
    @ObservedObject var link: WatchLink
    @StateObject private var recorder = WatchRecorder()

    var body: some View {
        VStack(spacing: 10) {
            Button {
                if recorder.isRecording {
                    if let url = recorder.stop() {
                        link.ask(recording: url)
                    }
                } else {
                    recorder.start()
                }
            } label: {
                Label(
                    recorder.isRecording ? "Send" : "Ask",
                    systemImage: recorder.isRecording ? "stop.fill" : "mic.fill"
                )
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .indigo)
            .disabled(link.isBusy)

            Text(message)
                .font(.footnote)
                .foregroundStyle(isProblem ? .red : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(6)
        }
        .padding()
        .task {
            // Asked on first appearance rather than on first tap, so the very
            // first question is not swallowed by a permission sheet.
            _ = await recorder.requestPermission()
        }
    }

    private var isProblem: Bool { recorder.problem != nil || link.isError }

    private var message: String {
        if let problem = recorder.problem { return problem }
        if recorder.isRecording { return "Listening - tap Send when you're done." }
        return link.status
    }
}
