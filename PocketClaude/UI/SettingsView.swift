import AVFoundation
import SwiftUI
import UIKit

/// Keys, repository, model, and voice. Everything secret goes to the Keychain
/// the moment you tap Save and is never held in `@AppStorage`/`UserDefaults`.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var elevenLabsKey = ""
    @State private var relayToken = ""
    @State private var relayUpdateMessage: String?
    @State private var isUpdatingRelay = false
    @State private var savedNotice: String?
    @State private var setup: RelayClient.CloudSetup?
    @State private var setupProblem: String?
    @State private var isReadingSetup = false
    @State private var copiedNotice = false

    var body: some View {
        NavigationStack {
            Form {
                relaySection
                cloudSetupSection
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

    // MARK: - Cloud setup

    /// The values a cloud environment needs, fetched rather than remembered.
    ///
    /// Both live on the relay already: the answer token is its own, and the URL
    /// is whatever Tailscale Funnel publishes. Asking it beats asking a person
    /// to recall a hostname, and it cannot be out of date the way a written-down
    /// value can.
    ///
    /// The token is never drawn on screen. It goes to the clipboard and nowhere
    /// else — a settings screen is the single most screenshotted part of an app
    /// when something is not working, and this one holds a credential.
    private var cloudSetupSection: some View {
        Section {
            if let setup, let block = setup.block {
                LabeledContent("Answer URL", value: setup.answerURL ?? "")
                    .font(.footnote)
                LabeledContent("Answer token", value: "••••••••")
                    .font(.footnote)

                Button {
                    UIPasteboard.general.string = block
                    copiedNotice = true
                } label: {
                    Label(copiedNotice ? "Copied" : "Copy both", systemImage: copiedNotice ? "checkmark" : "doc.on.doc")
                }
            } else if let setupProblem {
                Text(setupProblem)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let setup, !setup.funnelRunning {
                Text("The relay is reachable but Tailscale Funnel is not publishing it, so there is no public URL for a cloud session to answer to. Start the funnel and read this again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await readSetup() }
            } label: {
                HStack {
                    Text(setup == nil ? "Read from the relay" : "Read again")
                    if isReadingSetup {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isReadingSetup)
        } header: {
            Text("Cloud session setup")
        } footer: {
            Text("Paste these two into the environment at claude.ai/code for each repository you want to talk to. Once per environment, not per session — and the repository needs the Stop hook on its default branch. See relay/hooks/README.md.")
        }
    }

    private func readSetup() async {
        setupProblem = nil
        copiedNotice = false
        isReadingSetup = true
        defer { isReadingSetup = false }

        guard let client = RelayClient.make(settings: settings) else {
            setupProblem = "Set the relay address and token first."
            return
        }
        do {
            let found = try await client.cloudSetup()
            setup = found
            if found.answerToken == nil {
                setupProblem = "The relay has no RELAY_ANSWER_TOKEN set, so a cloud session has nothing to authenticate with. Set one on the relay first."
            }
        } catch {
            setupProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Relay

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

    // MARK: - Model

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
