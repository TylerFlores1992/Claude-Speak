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

    var body: some View {
        Group {
            VStack(spacing: 0) {
                TranscriptView(
                    entries: viewModel.session.transcript,
                    liveTranscript: viewModel.liveTranscript
                )

                statusBar

                composer
            }
            .navigationTitle(viewModel.activeProject.isEmpty ? "PocketClaude" : viewModel.activeProject)
            .navigationBarTitleDisplayMode(.inline)
            // No toolbar of its own. Starting a fresh conversation lives on
            // the sessions screen, next to the list of what already exists,
            // rather than as an unlabelled icon a thumb finds by accident.
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
                        Label("Add your relay address", systemImage: "key.fill")
                    }
                }
            case .listening:
                Label("Listening…", systemImage: "waveform")
                    .foregroundStyle(.red)
            case .working(let detail):
                ProgressView().controlSize(.small)
                Text(detail).lineLimit(1)
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
            TextField(composerPromptForLane, text: $typedInput, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .font(.body)
                .focused($isComposerFocused)
                .submitLabel(.send)
                .onSubmit(sendTyped)

            HStack(spacing: 8) {
                repeatButton

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

                // Only in a cloud session, and only while there is history
                // left to bring over. Once the conversation is on screen there
                // is nothing more to fetch, and a button that repeats what it
                // already did is the kind of thing you tap twice wondering
                // whether it worked.
                if !viewModel.activeCloudSessionID.isEmpty, viewModel.canPullHistory {
                    Button {
                        Task { await viewModel.pullCloudHistory() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: viewModel.pullPending
                                ? "clock.arrow.circlepath"
                                : "arrow.down.circle")
                                .font(.caption2)
                            Text(viewModel.pullPending ? "Pulling" : "History")
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.pcIconWell, in: Capsule())
                        .foregroundStyle(.primary)
                    }
                    .disabled(viewModel.pullPending)
                    .accessibilityLabel(viewModel.pullPending
                        ? "History requested. It arrives with the next reply."
                        : "Bring this session's conversation over from claude.ai for reference.")
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
                        isEnabled: !viewModel.state.isBusy,
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

    /// The prompt names where the question is going, since the two lanes
    /// behave differently enough that guessing is unpleasant.
    private var composerPromptForLane: String {
        viewModel.activeCloudSessionID.isEmpty ? composerPrompt : "Ask the cloud session"
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

    /// Say the last answer again.
    ///
    /// It replaced a menu holding three things, two of which the sessions
    /// screen already does better: past conversations are that whole screen,
    /// and starting a new one is the button on it. What was left was the one
    /// action with nowhere else to live and a real reason to be one tap deep —
    /// a plane goes over, you miss the answer, and hunting through a menu for
    /// it means you have missed it twice.
    private var repeatButton: some View {
        Button {
            viewModel.repeatLastAnswer()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
                .background(Color.pcIconWell, in: Circle())
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("Say the last answer again")
    }
}
