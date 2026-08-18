import SwiftUI

/// One button, because that is the whole point.
///
/// Dictation is Apple's own sheet rather than a microphone we drive. On the
/// watch that is both far less code and considerably more reliable — it is the
/// same input people already use for replying to messages, and it works with
/// the phone locked and pocketed.
struct WatchContentView: View {
    @ObservedObject var link: WatchLink

    var body: some View {
        VStack(spacing: 10) {
            TextFieldLink {
                Label("Ask", systemImage: "mic.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } onSubmit: { question in
                link.ask(question)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(link.isBusy)

            Text(link.status)
                .font(.footnote)
                .foregroundStyle(link.isError ? .red : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(6)
        }
        .padding()
    }
}
