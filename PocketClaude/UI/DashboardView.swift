import SwiftUI

/// The home screen: the sessions you can talk to, cloud ones first.
///
/// Cloud sessions run on Anthropic's infrastructure and are the ones this app
/// is really for — the same conversations that are open in the Claude app. Add
/// one with the + button and its claude.ai link; nothing on the relay machine
/// can list them, so the link is how they get here.
///
/// Below those are the relay machine's own Claude Code sessions, grouped by
/// repository, so a conversation started at the keyboard can be picked up from
/// the phone.
struct DashboardView: View {
    @ObservedObject var viewModel: ConversationViewModel

    @State private var sessions: [RelaySession] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var cloudSessions: [CloudSession] = []
    /// Set by a delete swipe; the confirmation dialog acts on it. Deleting is
    /// the one action here that cannot be taken back, so it is the one that
    /// asks.
    @State private var sessionPendingDeletion: RelaySession?
    /// What is being renamed, and what it is being renamed to. Two ids rather
    /// than one because a cloud session and a relay session are renamed through
    /// different endpoints, and only one of them can be in flight at a time.
    @State private var renamingLocalID: String?
    @State private var renamingCloudID: String?
    @State private var renameText = ""
    @State private var rowActionProblem: String?
    @State private var isAddingSession = false
    @State private var newSessionLink = ""
    @State private var newSessionTitle = ""
    @State private var addProblem: String?
    @State private var isAdding = false

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
            newChatButton
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search sessions")
        .task {
            await load()
            await loadCloudSessions()
        }
        .refreshable {
            await load()
            await loadCloudSessions()
        }
        .sheet(isPresented: $isAddingSession) { addSessionSheet }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { isAddingSession = true } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Add a session from claude.ai")
            }
        }
    }

    /// Paste a link, get a row. The whole of adding a session.
    ///
    /// One field and one button, because this is the thing done often. The
    /// sheet that used to sit beside it carried teleporting, queueing, Remote
    /// Control and refreshing; teleport turned out not to work at all, and the
    /// rest were occasional enough to be noise next to this.
    private var addSessionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("claude.ai/code/session_…", text: $newSessionLink, axis: .vertical)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...3)

                    TextField("Name it (optional)", text: $newSessionTitle)
                } footer: {
                    Text("Open the session in the Claude app, copy its link, and paste it here. It joins the list above and you can ask it questions by voice.")
                }

                if let addProblem {
                    Section {
                        Label(addProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        Task { await addSession() }
                    } label: {
                        HStack {
                            Text("Add it")
                            Spacer()
                            if isAdding { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(
                        isAdding
                            || newSessionLink.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            }
            .navigationTitle("Add a session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isAddingSession = false }
                }
            }
        }
    }

    private func addSession() async {
        addProblem = nil
        isAdding = true
        defer { isAdding = false }
        do {
            let session = try await viewModel.addCloudSession(
                link: newSessionLink.trimmingCharacters(in: .whitespacesAndNewlines),
                title: newSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            newSessionLink = ""
            newSessionTitle = ""
            await loadCloudSessions()
            isAddingSession = false
            // Straight in, because adding a session is asking to use it.
            viewModel.useCloudSession(session)
        } catch {
            addProblem = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func loadCloudSessions() async {
        // Keep what is already on screen if the relay does not answer. The
        // previous version replaced the list with nothing on any failure, so a
        // momentary hiccup on the way back to this screen looked exactly like
        // a session that had failed to save.
        guard let found = try? await viewModel.cloudSessions() else { return }
        cloudSessions = found
    }

    @ViewBuilder
    private var content: some View {
        // Every branch here weighs both lanes. Gating on `sessions` alone meant
        // the local sessions on the relay machine decided whether the cloud
        // ones were drawn at all: with none on the relay -- which is the normal
        // state for someone who works in cloud sessions -- the list was
        // replaced by "No sessions yet" while sessions sat in it, and adding
        // another by link changed nothing visible.
        if isLoading && isEmptyEverywhere {
            ProgressView("Reading sessions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, isEmptyEverywhere {
            ContentUnavailableView {
                Label("Can't reach the relay", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try again") { Task { await load() } }
                Button("Settings") { viewModel.isShowingSettings = true }
            }
        } else if isEmptyEverywhere {
            ContentUnavailableView(
                "No sessions yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Add one from its claude.ai link, start one below, or run `claude` on the relay machine.")
            )
        } else {
            list
        }
    }

    /// Nothing to show in either lane. A cloud session is a session: one of
    /// those alone is reason enough to draw the list.
    private var isEmptyEverywhere: Bool {
        sessions.isEmpty && cloudSessions.isEmpty
    }

    private var list: some View {
        List {
            if !cloudSessions.isEmpty {
                Section {
                    ForEach(cloudSessions) { session in
                        Button {
                            viewModel.useCloudSession(session)
                        } label: {
                            cloudRow(session)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.pcCard)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Removes it from this list only. The session keeps
                            // running on claude.ai and can be added again from
                            // its link, so there is nothing to confirm.
                            Button(role: .destructive) {
                                Task { await forget(session) }
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }

                            Button {
                                beginRename(cloud: session)
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Label("On claude.ai", systemImage: "cloud.fill")
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                } footer: {
                    Text("These run on Anthropic's infrastructure. Ask by voice here; the same conversation is in the Claude app.")
                        .font(.caption)
                }
            }

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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Full swipe off, deliberately: iOS runs the first
                            // action on a full swipe, and "flick left, session
                            // gone" is the wrong ergonomics next to a delete.
                            Button(role: .destructive) {
                                sessionPendingDeletion = session
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                Task { await archive(session) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.orange)

                            Button {
                                beginRename(local: session)
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
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
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete \u{201C}\(sessionPendingDeletion?.title ?? "")\u{201D}", role: .destructive) {
                if let session = sessionPendingDeletion {
                    Task { await delete(session) }
                }
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: {
            Text("The transcript is removed from the relay machine. This can't be undone — archive instead if you only want it out of the list.")
        }
        .alert(
            "Rename",
            isPresented: Binding(
                get: { renamingLocalID != nil || renamingCloudID != nil },
                set: { if !$0 { cancelRename() } }
            )
        ) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Save") { Task { await commitRename() } }
            Button("Cancel", role: .cancel) { cancelRename() }
        } message: {
            Text("Leave it empty to go back to the name it had.")
        }
        .alert(
            "That didn't work",
            isPresented: Binding(
                get: { rowActionProblem != nil },
                set: { if !$0 { rowActionProblem = nil } }
            )
        ) {
            Button("OK", role: .cancel) { rowActionProblem = nil }
        } message: {
            Text(rowActionProblem ?? "")
        }
    }

    private func beginRename(local session: RelaySession) {
        renamingCloudID = nil
        renamingLocalID = session.id
        renameText = session.title
    }

    private func beginRename(cloud session: CloudSession) {
        renamingLocalID = nil
        renamingCloudID = session.cloudID
        renameText = session.title ?? ""
    }

    private func cancelRename() {
        renamingLocalID = nil
        renamingCloudID = nil
        renameText = ""
    }

    /// Renames whichever row was swiped, then reloads that list.
    ///
    /// Not optimistic, unlike archive and remove. Those take a row away, and a
    /// row that comes back is obviously a failure; a name that quietly reverts
    /// looks like a typo you made. So the list is re-read and shows what the
    /// relay actually stored.
    private func commitRename() async {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = renamingLocalID
        let cloud = renamingCloudID
        cancelRename()

        do {
            if let local {
                try await viewModel.renameSession(id: local, title: name)
                await load()
            } else if let cloud {
                try await viewModel.renameCloudSession(id: cloud, title: name)
                await loadCloudSessions()
            }
        } catch {
            rowActionProblem = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func archive(_ session: RelaySession) async {
        // Optimistic: the row leaves the list now, and comes back with an
        // explanation if the relay refuses. Waiting on a round trip to hide a
        // row makes the swipe feel broken.
        sessions.removeAll { $0.id == session.id }
        do {
            try await viewModel.archiveSession(id: session.id)
        } catch {
            rowActionProblem = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            await load()
        }
    }

    private func delete(_ session: RelaySession) async {
        sessionPendingDeletion = nil
        sessions.removeAll { $0.id == session.id }
        do {
            try await viewModel.deleteSession(id: session.id)
        } catch {
            rowActionProblem = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            await load()
        }
    }

    private func cloudRow(_ session: CloudSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.footnote)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                Text(session.project ?? "claude.ai")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let updated = session.updatedAt {
                Text(updated, format: .relative(presentation: .numeric))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func forget(_ session: CloudSession) async {
        cloudSessions.removeAll { $0.cloudID == session.cloudID }
        do {
            try await viewModel.forgetCloudSession(id: session.cloudID)
        } catch {
            rowActionProblem = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            await loadCloudSessions()
        }
    }

    private func row(_ session: RelaySession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.isChat ? "bubble.left" : "chevron.left.forwardslash.chevron.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.pcIconWell, in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if session.isLive {
                        // Live under Remote Control - the same conversation is
                        // open on claude.ai or in the Claude app right now.
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Live on claude.ai")
                    }
                    Text(session.title)
                        .font(.body)
                        .lineLimit(1)
                }
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

    /// Starts a conversation with no repository behind it.
    ///
    /// It used to ask which workspace to start in, which was a question with a
    /// real answer only while the relay was where repository work happened.
    /// Work with a repository now starts in the Claude app, arrives here as a
    /// cloud session, and brings its own environment. What is left for the
    /// relay to start is a chat: somewhere to think out loud, on the scratch
    /// workspace the relay already keeps for exactly this.
    private var newChatButton: some View {
        Button {
            viewModel.startSession(inProject: "Chat")
        } label: {
            Label("New chat", systemImage: "plus")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
        }
        .padding(.bottom, 12)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await viewModel.relaySessions()
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
