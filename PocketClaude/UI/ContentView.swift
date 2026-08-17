import SwiftUI

/// The whole app is one screen: transcript on top, big talk button on the bottom.
struct ContentView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @ObservedObject var settings: AppSettings

    @State private var typedInput = ""
    @State private var isShowingTypedInput = false
    @State private var isShowingSessions = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TranscriptView(
                    entries: viewModel.session.transcript,
                    liveTranscript: viewModel.liveTranscript
                )

                statusBar

                if case .awaitingConfirmation(let prompt) = viewModel.state {
                    confirmationBar(prompt: prompt)
                }

                if isShowingTypedInput { typedInputBar }

                TalkButton(
                    isListening: viewModel.state == .listening,
                    // Still tappable while a confirmation is pending, so you can
                    // answer "confirm" or "cancel" by voice.
                    isEnabled: !viewModel.state.isBusy || isAwaitingConfirmation,
                    onPress: viewModel.beginListening,
                    onRelease: viewModel.endListening
                )
                .padding(.vertical, 20)
            }
            .navigationTitle("PocketClaude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { viewModel.newSession() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New session")

                    Button { isShowingSessions = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Past conversations")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { isShowingTypedInput.toggle() } label: {
                        Image(systemName: "keyboard")
                    }
                    .accessibilityLabel("Type instead")

                    Button { viewModel.repeatLastAnswer() } label: {
                        Image(systemName: "arrow.counterclockwise.circle")
                    }
                    .accessibilityLabel("Repeat last answer")

                    Button { viewModel.isShowingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $viewModel.isShowingSettings) {
                SettingsView(settings: settings)
            }
            .sheet(isPresented: $isShowingSessions) {
                SessionListView(viewModel: viewModel)
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .task { await viewModel.prepare() }
        .onChange(of: settings.handsFreeMode) { _, enabled in
            if enabled { viewModel.startHandsFree() } else { viewModel.stopHandsFree() }
        }
        .onChange(of: settings.stemPressControl) { _, _ in
            viewModel.applyStemPressSetting()
        }
    }

    private var isAwaitingConfirmation: Bool {
        if case .awaitingConfirmation = viewModel.state { return true }
        return false
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            switch viewModel.state {
            case .idle:
                if settings.isConfigured {
                    Label("Ready", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        viewModel.isShowingSettings = true
                    } label: {
                        // Relay mode has no API keys and no repository slug —
                        // the repo lives on the server — so the direct-API
                        // wording would send you looking for the wrong fields.
                        Label(
                            settings.backend == .relay
                                ? "Add your relay address"
                                : "Add your keys and repo",
                            systemImage: "key.fill"
                        )
                    }
                }
            case .listening:
                Label("Listening…", systemImage: "waveform")
                    .foregroundStyle(.red)
            case .working(let detail):
                ProgressView().controlSize(.small)
                Text(detail).lineLimit(1)
            case .awaitingConfirmation:
                Label("Waiting for your confirmation", systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
            case .speaking:
                Label("Speaking", systemImage: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(CostEstimator.format(viewModel.session.estimatedCost))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Estimated session cost")
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Confirmation

    private func confirmationBar(prompt: String) -> some View {
        VStack(spacing: 10) {
            Text(prompt)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    viewModel.resolveConfirmation(false)
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.resolveConfirmation(true)
                } label: {
                    Text("Confirm").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Or hold the button and say “confirm” or “cancel”.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Typed fallback

    private var typedInputBar: some View {
        HStack {
            TextField("Type a message", text: $typedInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .submitLabel(.send)

            Button {
                viewModel.sendTyped(typedInput)
                typedInput = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(typedInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}
