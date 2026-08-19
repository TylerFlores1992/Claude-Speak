import SwiftUI

/// The home screen: every Claude Code session on the relay machine, grouped by
/// repository.
///
/// These are the CLI's own sessions, so a conversation started at the keyboard
/// appears here and can be picked up from the phone. One repository has many
/// sessions — every separate conversation you have had in it.
///
/// The Claude app's cloud sessions are not here, because they run on
/// Anthropic's infrastructure and nothing on this machine can see them. Nor is
/// there an API that lists them. But they are reachable one at a time, through
/// the CLI: the cloud button brings one across with `--teleport`, after which
/// it is an ordinary local session and appears in this list like any other.
struct DashboardView: View {
    @ObservedObject var viewModel: ConversationViewModel

    @State private var sessions: [RelaySession] = []
    @State private var projects: [RelayProject] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isChoosingProject = false
    @State private var isBringingCloudSession = false
    @State private var cloudSessionLink = ""
    @State private var teleportProject = ""
    @State private var teleportProblem: String?
    @State private var isTeleporting = false
    @State private var cloudMessage = ""
    @State private var isSendingToCloud = false
    @State private var queuedSessionURL: URL?
    @State private var sendProblem: String?
    @State private var cloudSessions: [CloudSession] = []
    @State private var isRefreshingCloud = false
    @State private var refreshSummary: String?

    private var grouped: [(project: String, sessions: [RelaySession])] {
        let matching = sessions.filter { session in
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return true }
            return session.title.lowercased().contains(q)
                || session.project.lowercased().contains(q)
        }
        return Dictionary(grouping: matching, by: \.project)
            .map { (project: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            // Most recently touched repository first — the one you were in.
            .sorted { ($0.sessions.first?.updatedAt ?? .distantPast) > ($1.sessions.first?.updatedAt ?? .distantPast) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            newSessionButton
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search sessions")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("New session in…", isPresented: $isChoosingProject, titleVisibility: .visible) {
            ForEach(projects.filter(\.available)) { project in
                Button(project.isScratch ? "\(project.name) — no repository" : project.name) {
                    viewModel.startSession(inProject: project.name)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isBringingCloudSession) {
            cloudSessionSheet
                .onAppear {
                    if cloudSessionLink.isEmpty {
                        cloudSessionLink = viewModel.settings.lastCloudSessionLink
                    }
                }
                .task { await loadCloudSessions() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { isBringingCloudSession = true } label: {
                    Image(systemName: "cloud.fill")
                }
                .accessibilityLabel("Bring a cloud session here")
            }
        }
    }

    /// Pulls a session from the Claude app onto the relay machine.
    ///
    /// Those sessions run on Anthropic's infrastructure, so nothing on the
    /// relay can see them and there is no API that lists them. `--teleport` is
    /// the supported way across, and once it has run the session is an
    /// ordinary local one that this list already shows.
    private var cloudSessionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("claude.ai/code/session_…", text: $cloudSessionLink, axis: .vertical)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...3)
                } header: {
                    Text("Session link")
                } footer: {
                    Text("Open the session in the Claude app, copy its link, and paste it here.")
                }

                Section {
                    Picker("Repository", selection: $teleportProject) {
                        Text("Relay default").tag("")
                        ForEach(projects.filter { $0.available && !$0.isScratch }) { project in
                            Text(project.name).tag(project.name)
                        }
                    }
                } footer: {
                    Text("Teleport checks out the session's branch, so it has to run in a checkout of the same repository, with nothing uncommitted.")
                }

                if let teleportProblem {
                    Section {
                        Label(teleportProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        Task { await bringCloudSession() }
                    } label: {
                        HStack {
                            Text("Bring it here")
                            Spacer()
                            if isTeleporting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isTeleporting || !hasCloudLink)
                } header: {
                    Text("Continue it here")
                } footer: {
                    Text("The conversation and its branch come across, and it becomes an ordinary session in the list above — answered out loud like any other. The cloud environment — its variables, setup script, and network rules — does not come with it; work continues in the relay machine's own environment.")
                }

                if !cloudSessions.isEmpty {
                    Section {
                        ForEach(cloudSessions) { session in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.displayTitle).lineLimit(1)
                                if let project = session.project {
                                    Text(project)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Button {
                            Task { await refreshCloud() }
                        } label: {
                            HStack {
                                Label("Update all from the cloud", systemImage: "arrow.clockwise")
                                Spacer()
                                if isRefreshingCloud { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(isRefreshingCloud)

                        if let refreshSummary {
                            Text(refreshSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Brought here before")
                    } footer: {
                        // Both limits stated, because both are surprising.
                        Text("Nothing can list your cloud sessions, so these are the ones you have pulled down before — pulling a new one adds it here. Updating re-pulls each of them, which needs a clean checkout of its repository; anything with uncommitted work is reported and skipped rather than stopping the rest.")
                    }
                }

                Section {
                    TextField("Ask it to do something…", text: $cloudMessage, axis: .vertical)
                        .lineLimit(1...5)

                    Button {
                        Task { await sendToCloudSession() }
                    } label: {
                        HStack {
                            Text("Send without bringing it here")
                            Spacer()
                            if isSendingToCloud { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(
                        isSendingToCloud
                            || !hasCloudLink
                            || cloudMessage.trimmingCharacters(in: .whitespaces).isEmpty
                    )

                    if let queuedSessionURL {
                        Link(destination: queuedSessionURL) {
                            Label("Queued — open in Claude", systemImage: "arrow.up.forward.app")
                        }
                    }

                    if let sendProblem {
                        Label(sendProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Leave it there")
                } footer: {
                    // Stated plainly because the shape is unusual and the
                    // alternative is waiting for a reply that is not coming.
                    Text("Queues a message into the session where it already runs, and returns straight away. No answer comes back here — the CLI posts and exits — so read it in the Claude app. Useful for starting something on the way out the door. The mic on the keyboard works for dictating it.")
                }
            }
            .navigationTitle("Cloud session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isBringingCloudSession = false }
                }
            }
        }
    }

    private func loadCloudSessions() async {
        cloudSessions = (try? await viewModel.cloudSessions()) ?? []
    }

    private func refreshCloud() async {
        refreshSummary = nil
        isRefreshingCloud = true
        defer { isRefreshingCloud = false }
        do {
            let results = try await viewModel.refreshCloudSessions()
            let updated = results.filter(\.ok).count
            let failed = results.filter { !$0.ok }
            // Names the first failure rather than only counting it: "1 couldn't
            // update" with no reason is the report that sends you to a log.
            if failed.isEmpty {
                refreshSummary = "Updated \(updated) of \(results.count)."
            } else {
                let reason = failed.first?.problem ?? "unknown reason"
                refreshSummary = "Updated \(updated) of \(results.count). "
                    + "\(failed.count) couldn't: \(reason)"
            }
            await loadCloudSessions()
            await load()
        } catch {
            refreshSummary = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private var hasCloudLink: Bool {
        !cloudSessionLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendToCloudSession() async {
        sendProblem = nil
        queuedSessionURL = nil
        isSendingToCloud = true
        defer { isSendingToCloud = false }

        let link = cloudSessionLink.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            queuedSessionURL = try await viewModel.sendToCloud(
                link: link,
                text: cloudMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            viewModel.settings.lastCloudSessionLink = link
            cloudMessage = ""
        } catch {
            sendProblem = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func bringCloudSession() async {
        teleportProblem = nil
        isTeleporting = true
        defer { isTeleporting = false }
        do {
            try await viewModel.teleport(
                link: cloudSessionLink.trimmingCharacters(in: .whitespacesAndNewlines),
                project: teleportProject
            )
            viewModel.settings.lastCloudSessionLink = cloudSessionLink
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cloudSessionLink = ""
            await loadCloudSessions()
            isBringingCloudSession = false
            // It is a local session now, so the ordinary list is where it shows.
            await load()
        } catch {
            teleportProblem = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && sessions.isEmpty {
            ProgressView("Reading sessions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, sessions.isEmpty {
            ContentUnavailableView {
                Label("Can't reach the relay", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try again") { Task { await load() } }
                Button("Settings") { viewModel.isShowingSettings = true }
            }
        } else if sessions.isEmpty {
            ContentUnavailableView(
                "No sessions yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Start one below, or run `claude` on the relay machine.")
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.project) { group in
                Section {
                    ForEach(group.sessions) { session in
                        Button {
                            viewModel.resume(session)
                        } label: {
                            row(session)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.pcCard)
                    }
                } header: {
                    Label(
                        group.project,
                        systemImage: group.sessions.first?.isChat == true ? "bubble.left" : "chevron.left.forwardslash.chevron.right"
                    )
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
                }
            }
            // Clears the floating button.
            Color.clear.frame(height: 64).listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ session: RelaySession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.isChat ? "bubble.left" : "chevron.left.forwardslash.chevron.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.pcIconWell, in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body)
                    .lineLimit(1)
                Text(session.projectPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            Text(session.updatedAt, format: .relative(presentation: .numeric))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var newSessionButton: some View {
        Button {
            isChoosingProject = true
        } label: {
            Label("New session", systemImage: "plus")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
        }
        .padding(.bottom, 12)
        .disabled(projects.isEmpty)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (found, available) = try await viewModel.relayCatalog()
            sessions = found
            projects = available
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
