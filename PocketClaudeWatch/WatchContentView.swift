import SwiftUI

/// Ask by voice, with typing as the fallback rather than the default.
///
/// The first version used `TextFieldLink` for both, which opens whichever
/// input mode the watch prefers — Scribble, in practice. Talking is the entire
/// point of this app, so dictation now gets its own button and its own code
/// path, and the keyboard is the small one underneath.
struct WatchContentView: View {
    @ObservedObject var link: WatchLink

    /// Set when WatchKit had nothing to present from, so the person is told to
    /// use the other button rather than being left tapping a dead one.
    @State private var dictationUnavailable = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                dictationUnavailable = !WatchDictation.present { spoken in
                    link.ask(spoken)
                }
            } label: {
                Label("Ask", systemImage: "mic.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(link.isBusy)

            TextFieldLink {
                Label("Type", systemImage: "keyboard")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            } onSubmit: { question in
                link.ask(question)
            }
            .buttonStyle(.bordered)
            .disabled(link.isBusy)

            Text(dictationUnavailable ? "Dictation is not available right now — use Type." : link.status)
                .font(.footnote)
                .foregroundStyle(link.isError || dictationUnavailable ? .red : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(6)
        }
        .padding()
    }
}
