import SwiftUI

/// Past conversations: search them, reopen one, delete the rest.
///
/// This is the screen-on half of the app. In your pocket you ask rather than
/// navigate — code search is a question, not a browser. What asking can't do is
/// find the conversation you had on Tuesday, which is what this is for.
struct SessionListView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// Snapshotted on appear rather than recomputed per keystroke — building it
    /// reads every session file.
    @State private var summaries: [SessionSummary] = []

    private var results: [SessionSummary] {
        summaries.filter { $0.matches(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if summaries.isEmpty {
                    ContentUnavailableView(
                        "No conversations yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Ask something and it will be saved here.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    list
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search conversations")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { summaries = viewModel.sessionSummaries() }
        }
    }

    private var list: some View {
        List {
            ForEach(results) { summary in
                Button {
                    viewModel.switchToSession(id: summary.id)
                    dismiss()
                } label: {
                    row(summary)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for index in offsets {
                    viewModel.deleteSession(id: results[index].id)
                }
                summaries = viewModel.sessionSummaries()
            }
        }
    }

    @ViewBuilder
    private func row(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if summary.id == viewModel.session.id {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Current conversation")
                }
                Text(summary.title)
                    .font(.body)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text(summary.updatedAt, format: .relative(presentation: .named))
                Text("·")
                Text(summary.exchangeCount == 1 ? "1 question" : "\(summary.exchangeCount) questions")
                if summary.usedRelay {
                    Text("·")
                    // Relay answers cost nothing, so a cost figure would be a
                    // lie. Say where it came from instead.
                    Label("Relay", systemImage: "desktopcomputer")
                        .labelStyle(.titleAndIcon)
                } else if summary.estimatedCost > 0 {
                    Text("·")
                    Text(CostEstimator.format(summary.estimatedCost))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
