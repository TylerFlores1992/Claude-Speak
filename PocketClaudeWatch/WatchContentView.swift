import SwiftUI

/// One button. Tap to start talking, tap again to send.
///
/// A second appears while recording, to throw the take away — you notice you
/// said the wrong thing while you are still saying it, and without this the
/// only way out was to send it and wait for an answer to a question you did
/// not mean to ask.
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
                .frame(maxWidth: .infinity, minHeight: recorder.isRecording ? 52 : 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .indigo)
            .disabled(link.isBusy)

            // Only while recording, because there is nothing to cancel
            // otherwise, and a permanent second button on a screen this size
            // costs the one that matters.
            if recorder.isRecording {
                Button {
                    recorder.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }

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
        if recorder.isRecording { return "Listening - Send when you're done, Cancel to throw it away." }
        return link.status
    }
}
