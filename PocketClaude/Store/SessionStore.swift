import Foundation

/// One line in the on-screen transcript. Distinct from `ChatMessage`, which is
/// what the API sees — the transcript also carries tool activity and errors that
/// never go back to Claude.
struct TranscriptEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case user
        case assistant
        case tool
        case status
        case error
    }

    var id: UUID = UUID()
    var kind: Kind
    var text: String
    /// The full answer, when it differs from what was spoken.
    var detail: String? = nil
    var timestamp: Date = Date()
}

/// A conversation, persisted between launches.
struct Session: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    /// API-visible history, including raw assistant content blocks.
    var messages: [ChatMessage] = []
    var transcript: [TranscriptEntry] = []
    var usage: TokenUsage = TokenUsage()
    /// Model that produced most of this session, for the cost estimate.
    var model: String = AppSettings.Model.opus5.rawValue

    var isEmpty: Bool { messages.isEmpty && transcript.isEmpty }

    var estimatedCost: Double { CostEstimator.cost(of: usage, model: model) }
}

/// Saves the current session to disk so closing the app doesn't lose context.
///
/// Deliberately a single file, written whole. Sessions are small (a few hundred
/// KB at most) and a database would be more machinery than this needs.
struct SessionStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            self.fileURL = directory.appendingPathComponent("pocketclaude-session.json")
        }
    }

    func load() -> Session? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Session.self, from: data)
    }

    func save(_ session: Session) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return }
        // `.completeFileProtection` keeps the transcript encrypted at rest while
        // the device is locked. Session history can quote private source code.
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
