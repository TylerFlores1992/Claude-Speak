import SwiftUI

/// Scrolling conversation log. The spoken summary is the headline; the full
/// detail is collapsed behind a disclosure so the screen stays scannable.
struct TranscriptView: View {
    var entries: [TranscriptEntry]
    var liveTranscript: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in
                        TranscriptRow(entry: entry).id(entry.id)
                    }

                    if !liveTranscript.isEmpty {
                        Text(liveTranscript)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 14))
                            .id(Self.liveID)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: entries.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: liveTranscript) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private static let liveID = "live-transcript"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if !liveTranscript.isEmpty {
                proxy.scrollTo(Self.liveID, anchor: .bottom)
            } else if let last = entries.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct TranscriptRow: View {
    var entry: TranscriptEntry
    @State private var isDetailExpanded = false

    var body: some View {
        switch entry.kind {
        case .user:
            Text(entry.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: .rect(cornerRadius: 16))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                // Rendered rather than raw: answers arrive as Markdown, and
                // literal ** and ## in the transcript is what you read.
                MarkdownText(text: entry.text)
                    .textSelection(.enabled)
                if let detail = entry.detail, !detail.isEmpty, detail != entry.text {
                    DisclosureGroup("Detail", isExpanded: $isDetailExpanded) {
                        MarkdownText(text: detail)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: .leading)

        case .tool:
            Label(entry.text, systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .status:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
