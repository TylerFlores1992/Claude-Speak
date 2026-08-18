import SwiftUI

/// The home screen: every Claude Code session on the relay machine, grouped by
/// repository.
///
/// These are the CLI's own sessions, so a conversation started at the keyboard
/// appears here and can be picked up from the phone. One repository has many
/// sessions — every separate conversation you have had in it.
///
/// Deliberately not a mirror of the Claude app's Chats. Those live on
/// Anthropic's servers with no public API; reaching them would mean scraping
/// the web app with account cookies. This shows what the relay can actually
/// see, which is the work that matters when you walk away from the desk.
struct DashboardView: View {
    @ObservedObject var viewModel: ConversationViewModel

    @State private var sessions: [RelaySession] = []
    @State private var projects: [RelayProject] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isChoosingProject = false

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
