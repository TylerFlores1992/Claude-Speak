import AVFoundation
import SwiftUI

/// Keys, repository, model, and voice. Everything secret goes to the Keychain
/// the moment you tap Save and is never held in `@AppStorage`/`UserDefaults`.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var anthropicKey = ""
    @State private var githubToken = ""
    @State private var elevenLabsKey = ""
    @State private var relayToken = ""
    @State private var relayUpdateMessage: String?
    @State private var isUpdatingRelay = false
    @State private var savedNotice: String?

    var body: some View {
        NavigationStack {
            Form {
                backendSection
                if settings.backend == .relay {
                    relaySection
                } else {
                    credentialsSection
                    repositorySection
                    modelSection
                }
                voiceSection
                listeningSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Saved",
                isPresented: Binding(
                    get: { savedNotice != nil },
                    set: { if !$0 { savedNotice = nil } }
                )
            ) {
                Button("OK", role: .cancel) { savedNotice = nil }
            } message: {
                Text(savedNotice ?? "")
            }
        }
    }

    // MARK: - Backend

    private var backendSection: some View {
        Section {
            Picker("Answers from", selection: $settings.backend) {
                ForEach(AppSettings.Backend.allCases) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
        } header: {
            Text("Backend")
        } footer: {
            switch settings.backend {
            case .directAPI:
                Text("Calls Anthropic straight from this phone, billed to your API key per token. Works anywhere with a signal, but can only read the repository and open pull requests — it cannot run anything.")
            case .relay:
                Text("Calls the relay on your own machine, which runs the Claude Code CLI against a real checkout. No per-question charge — it uses your Claude subscription — and it can run your tests and builds. Only works while that machine is awake and reachable.")
            }
        }
    }

    /// What's wrong with the relay address, or nil when it's usable. Deliberately
    /// says nothing about the token — that row reports its own state.
    private var relayAddressProblem: String? {
        let trimmed = settings.relayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No address set" }
        guard RelayAddress.isUsable(trimmed) else {
            return "Needs http:// or https://, e.g. http://100.x.y.z:8788"
        }
        return nil
    }

    private var relaySection: some View {
        Section {
            // The app-wide `.tint(.indigo)` bleeds into a TextField's
            // placeholder, so an example address here reads as one you already
            // entered. The word "Required" is what stops it being mistaken for
            // a value, and the status line below says plainly whether it is set.
            TextField("Required — http://100.x.y.z:8788", text: $settings.relayURLString)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)

            if let problem = relayAddressProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            secretRow(
                title: "Relay token",
                placeholder: "matches RELAY_TOKEN",
                text: $relayToken,
                key: .relayToken
            )

            Button {
                Task { await updateRelay() }
            } label: {
                HStack {
                    Label("Update and restart relay", systemImage: "arrow.down.circle")
                    Spacer()
                    if isUpdatingRelay { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isUpdatingRelay || !settings.isRelayConfigured)

            if let relayUpdateMessage {
                Text(relayUpdateMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Relay")
        } footer: {
            Text("Set these to the address and RELAY_TOKEN of `relay/server.mjs` on your machine. A Tailscale hostname keeps the relay off the public internet. The repository, model, and tool permissions are configured on the server, not here — see relay/README.md.")
        }
    }

    /// Pulls new relay code and restarts it.
    ///
    /// Only does anything when the relay runs under `relay/run.ps1` — the
    /// server can fetch new code but cannot start running it on its own, and
    /// the supervisor is what turns the exit into a restart.
    private func updateRelay() async {
        guard let client = RelayClient.make(settings: settings) else {
            relayUpdateMessage = "Set the relay address and token first."
            return
        }
        isUpdatingRelay = true
        defer { isUpdatingRelay = false }
        do {
            let result = try await client.update()
            relayUpdateMessage = result.message
        } catch {
            relayUpdateMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        Section {
            secretRow(
                title: "Anthropic API key",
                placeholder: "sk-ant-…",
                text: $anthropicKey,
                key: .anthropicAPIKey
            )
            secretRow(
                title: "GitHub token",
                placeholder: "github_pat_… or ghp_…",
                text: $githubToken,
                key: .githubToken
            )
        } header: {
            Text("Credentials")
        } footer: {
            Text("Stored in the iOS Keychain, never in app settings or backups you can read. A fine-grained GitHub token with Contents: Read is enough for read-only use; Contents: Read and write plus Pull requests: Read and write is needed to open PRs.")
        }
    }

    @ViewBuilder
    private func secretRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        key: KeychainStore.Key
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if KeychainStore.has(key) {
                    Label("Saved", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            HStack {
                SecureField(placeholder, text: text)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Save") {
                    // Trim before storing. Pasting a token from Mail or Notes
                    // routinely brings a trailing space or newline with it, and
                    // every consumer of these compares bytes exactly — the relay
                    // uses timingSafeEqual, so one invisible character reads as
                    // a wrong token and you get a 401 with nothing to see.
                    let cleaned = text.wrappedValue
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { return }
                    KeychainStore.set(cleaned, for: key)
                    text.wrappedValue = ""
                    savedNotice = "\(title) saved to the Keychain."
                }
                .buttonStyle(.bordered)
                .disabled(
                    text.wrappedValue
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )

                if KeychainStore.has(key) {
                    Button(role: .destructive) {
                        KeychainStore.delete(key)
                        savedNotice = "\(title) removed."
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Repository

    private var repositorySection: some View {
        Section {
            TextField("owner/repo", text: $settings.repositorySlug)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Toggle("Allow write tools", isOn: $settings.allowWriteTools)
        } header: {
            Text("Repository")
        } footer: {
            Text("With write tools on, Claude can propose branches, commits, and pull requests — each one still needs your spoken or tapped confirmation. Commits to main, master, or the repository's default branch are refused unconditionally.")
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $settings.model) {
                ForEach(AppSettings.Model.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }

            Picker("Effort", selection: $settings.effort) {
                ForEach(AppSettings.Effort.allCases) { effort in
                    Text(effort.rawValue.capitalized).tag(effort)
                }
            }

            Stepper(
                "Max tokens: \(settings.maxTokens)",
                value: $settings.maxTokens,
                in: 4_000...32_000,
                step: 2_000
            )

            Toggle("Structured JSON output", isOn: $settings.useStructuredOutput)
        } header: {
            Text("Model")
        } footer: {
            Text("Higher effort means more thinking and more tool calls — better answers, longer waits, more tokens. Structured output asks the API to enforce the spoken-summary schema; leave it off unless you see the model drifting out of format.")
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section {
            Picker("Engine", selection: $settings.voiceEngine) {
                ForEach(AppSettings.VoiceEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }

            if settings.voiceEngine == .system {
                Picker("Voice", selection: $settings.systemVoiceIdentifier) {
                    Text("Best available").tag("")
                    // Quality is the thing that matters here and it isn't
                    // guessable from the name — Samantha exists at three
                    // different qualities that sound nothing alike.
                    ForEach(SpeechService.availableVoices(), id: \.identifier) { voice in
                        Text("\(voice.name) — \(SpeechService.qualityLabel(voice))")
                            .tag(voice.identifier)
                    }
                }
            } else {
                secretRow(
                    title: "ElevenLabs API key",
                    placeholder: "sk_…",
                    text: $elevenLabsKey,
                    key: .elevenLabsAPIKey
                )
                TextField("Voice ID", text: $settings.elevenLabsVoiceID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            VStack(alignment: .leading) {
                Text("Speech rate")
                Slider(value: $settings.speechRate, in: 0.40...0.70)
            }

            Toggle("Keep music playing", isOn: $settings.keepOtherAudioPlaying)

            Toggle("Speak while the answer arrives", isOn: $settings.speakIncrementally)

            Toggle("Speak write confirmations", isOn: $settings.speakConfirmations)
        } header: {
            Text("Voice out")
        } footer: {
            Text("Keep music playing dips Spotify or a podcast while an answer is read and lets it back up afterwards, instead of stopping it. The cost is the AirPod stem press: an app that mixes with other audio can never hold the Now Playing slot, and that slot is the only channel a squeeze travels down. Music or the squeeze, not both. iOS ships only Default-quality voices, which sound robotic. Download better ones in iOS Settings → Accessibility → Spoken Content → Voices → English — the Premium voices are a large improvement and cost nothing. They appear in the list above once downloaded. ElevenLabs sounds better still and costs money per character; if a request fails, the app falls back to a system voice rather than going silent.")
        }
    }

    // MARK: - Listening

    private var listeningSection: some View {
        Section {
            Toggle("Prefer on-device recognition", isOn: $settings.preferOnDeviceRecognition)
            Toggle("AirPod stem press starts talking", isOn: $settings.stemPressControl)
            Toggle("Wake word", isOn: $settings.wakeWordEnabled)
            if settings.wakeWordEnabled {
                TextField("Wake phrase", text: $settings.wakePhrase)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Toggle("Hands-free mode", isOn: $settings.handsFreeMode)
            if settings.handsFreeMode || settings.wakeWordEnabled {
                TextField("End keyword", text: $settings.handsFreeEndKeyword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("Voice in")
        } footer: {
            Text("Wake word is the one way to ask a question with the phone locked and pocketed. It works because iOS lets an app that already holds the microphone keep recording in the background, even though it will not hand the microphone to a backgrounded app in the first place — so the microphone is taken while the app is open and never let go. That costs battery, and it turns the AirPod stem press off: holding the microphone is exactly what gives up the Now Playing slot a stem press travels down. Say the phrase, wait for the beep, ask, then either say your end keyword or just stop talking. On-device recognition keeps audio off Apple's servers and works with no signal, but on some devices it reports words as you speak and then finishes with nothing — the question is lost silently. It's off by default for that reason; turn it on and check it actually sends. iOS gives apps no direct access to AirPods gestures. Stem press works by holding the Now Playing slot and reading the play/pause command a squeeze produces. Only one app can hold that slot, so while this is on it plays silence to keep it — you can't listen to music or a podcast on the same device, and it uses battery. Starting a take needs the screen on: a locked device won't hand the microphone to a backgrounded app, and taking the microphone is also what gives up the Now Playing slot, so the two can't both be held. Hands-free mode keeps the microphone open while the app is in the foreground and sends when it hears your end keyword — it drains the battery noticeably and stops when the app is backgrounded.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Phase", value: "1 — on-phone only")
            LabeledContent("Server", value: "None")
        } footer: {
            Text("Everything runs on this device: speech in, Anthropic Messages API, GitHub REST as tools, speech out. There is no shell, no test runner, and no build step — see ROADMAP.md for what a server would add.")
        }
    }
}
