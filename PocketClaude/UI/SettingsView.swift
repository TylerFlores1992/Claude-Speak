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
    @State private var savedNotice: String?

    var body: some View {
        NavigationStack {
            Form {
                credentialsSection
                repositorySection
                modelSection
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
                    KeychainStore.set(text.wrappedValue, for: key)
                    text.wrappedValue = ""
                    savedNotice = "\(title) saved to the Keychain."
                }
                .buttonStyle(.bordered)
                .disabled(text.wrappedValue.isEmpty)

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
                    Text("Default").tag("")
                    ForEach(SpeechService.availableVoices(), id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
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

            Toggle("Speak write confirmations", isOn: $settings.speakConfirmations)
        } header: {
            Text("Voice out")
        } footer: {
            Text("The system voice is free and works offline. ElevenLabs sounds better and costs money per character; if a request fails, the app falls back to the system voice rather than going silent.")
        }
    }

    // MARK: - Listening

    private var listeningSection: some View {
        Section {
            Toggle("Prefer on-device recognition", isOn: $settings.preferOnDeviceRecognition)
            Toggle("AirPod stem press starts talking", isOn: $settings.stemPressControl)
            Toggle("Hands-free mode", isOn: $settings.handsFreeMode)
            if settings.handsFreeMode {
                TextField("End keyword", text: $settings.handsFreeEndKeyword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("Voice in")
        } footer: {
            Text("iOS gives apps no direct access to AirPods gestures. Stem-press support works by claiming the Now Playing slot and reading the play/pause command a squeeze produces — so it stops working the moment another app (music, podcasts) takes that slot, and resumes after PocketClaude next speaks. On-device recognition keeps audio off Apple's servers and works with no signal, where the locale supports it. Hands-free mode keeps the microphone open while the app is in the foreground and sends when it hears your end keyword — it drains the battery noticeably and stops when the app is backgrounded.")
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
