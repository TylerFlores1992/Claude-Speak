import SwiftUI

/// The conversation: transcript on top, one composer card at the bottom.
///
/// Pushed from the dashboard rather than being the root, so the navigation
/// stack belongs to `RootView` and this supplies only its own toolbar.
struct ConversationScreen: View {
    @ObservedObject var viewModel: ConversationViewModel
    @ObservedObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    @State private var typedInput = ""
    /// Whether the composer field holds the keyboard. Needed because SwiftUI
    /// gives no other way to put it away: tapping outside a TextField inside a
    /// scrolling stack does not dismiss it, so without this the keyboard covers
    /// the transcript with no way back.
    @FocusState private var isComposerFocused: Bool
    @State private var isShowingSessions = false

    var body: some View {
        Group {
            VStack(spacing: 0) {
                TranscriptView(
                    entries: viewModel.session.transcript,
                    liveTranscript: viewModel.liveTranscript
                )

                statusBar

                if case .awaitingConfirmation(let prompt) = viewModel.state {
                    confirmationBar(prompt: prompt)
                }

                composer
            }
            .navigationTitle(viewModel.activeProject.isEmpty ? "PocketClaude" : viewModel.activeProject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { viewModel.newSession() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New session")
                }
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
        .task {
            await viewModel.prepare()
            // Already on from a previous launch: the loop lives with the view
            // model, not the setting, so something has to start it.
            if settings.wakeWordEnabled { viewModel.startWakeWord() }
        }
        .onChange(of: settings.handsFreeMode) { _, enabled in
            if enabled { viewModel.startHandsFree() } else { viewModel.stopHandsFree() }
        }
        .onChange(of: settings.stemPressControl) { _, _ in
            viewModel.applyStemPressSetting()
        }
        .onChange(of: settings.keepOtherAudioPlaying) { _, _ in
            viewModel.applyStemPressSetting()
        }
        .onChange(of: settings.wakeWordEnabled) { _, enabled in
            if enabled { viewModel.startWakeWord() } else { viewModel.stopWakeWord() }
        }
        // Anything else that plays audio — music, a podcast — takes the Now
        // Playing slot, and with it the stem press. Coming back to the
        // foreground is the one moment we can take it back without the person
        // having to ask a question first.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.applyStemPressSetting() }
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

    // MARK: - Composer

    /// One rounded card holding everything you act with: what you want to say,
    /// what will answer, and the button that sends it.
    ///
    /// Previously these were three stacked strips — a typing bar you had to
    /// reveal from the toolbar, a row of chips, and a 168pt button below them.
    /// Collapsing them costs nothing functionally and gives the transcript back
    /// most of the lower third of the screen, which is the part you actually
    /// read.
    private var composer: some View {
        VStack(spacing: 12) {
            TextField(composerPrompt, text: $typedInput, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .font(.body)
                .focused($isComposerFocused)
                .submitLabel(.send)
                .onSubmit(sendTyped)

            HStack(spacing: 8) {
                actionsMenu

                if isComposerFocused {
                    Button { isComposerFocused = false } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Color.pcIconWell, in: Circle())
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Hide the keyboard")
                    .transition(.scale.combined(with: .opacity))
                }

                ChipMenu(title: modelChipTitle, systemImage: "sparkle") {
                    Picker("Model", selection: $settings.model) {
                        ForEach(AppSettings.Model.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    Picker("Effort", selection: $settings.effort) {
                        ForEach(AppSettings.Effort.allCases) { effort in
                            Text(effort.displayName).tag(effort)
                        }
                    }
                }

                Spacer(minLength: 0)

                // The send arrow replaces the microphone only while there is
                // something typed. Two always-visible buttons that both mean
                // "send" is the confusing arrangement worth avoiding, and the
                // hold-to-talk button is the one that has to be reachable
                // without looking.
                if hasTypedText {
                    Button(action: sendTyped) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .disabled(viewModel.state.isBusy)
                    .accessibilityLabel("Send")
                } else {
                    TalkButton(
                        isListening: viewModel.state == .listening,
                        // Still usable while a confirmation is pending, so you
                        // can answer "confirm" or "cancel" by voice.
                        isEnabled: !viewModel.state.isBusy || isAwaitingConfirmation,
                        size: .compact,
                        onPress: viewModel.beginListening,
                        onRelease: viewModel.endListening
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.pcCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.15), value: isComposerFocused)
    }

    /// Names the workspace, so it is clear which checkout a question lands in
    /// without spending a chip on it.
    private var composerPrompt: String {
        viewModel.activeProject.isEmpty
            ? "Ask Claude"
            : "Ask about \(viewModel.activeProject)"
    }

    /// "Opus 5 High" — model and effort together, the way Claude shows them.
    /// Effort only applies to models that support it, so naming it beside a
    /// model that ignores it would be a lie about what the next turn will do.
    private var modelChipTitle: String {
        settings.model.supportsAdaptiveThinking
            ? "\(settings.model.shortName) \(settings.effort.displayName)"
            : settings.model.shortName
    }

    private var hasTypedText: Bool {
        !typedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendTyped() {
        let text = typedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.sendTyped(text)
        typedInput = ""
        // Put the keyboard away on send. Leaving it up hides the answer that
        // was just asked for.
        isComposerFocused = false
    }

    /// The things you reach for occasionally. In a menu rather than the toolbar
    /// because the toolbar was carrying five icons, none of them labelled.
    private var actionsMenu: some View {
        Menu {
            Button { isShowingSessions = true } label: {
                Label("Past conversations", systemImage: "clock.arrow.circlepath")
            }
            Button { viewModel.repeatLastAnswer() } label: {
                Label("Repeat last answer", systemImage: "arrow.counterclockwise")
            }
            Divider()
            Button { viewModel.newSession() } label: {
                Label("New session", systemImage: "square.and.pencil")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 34, height: 34)
                .background(Color.pcIconWell, in: Circle())
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("More actions")
    }
}
