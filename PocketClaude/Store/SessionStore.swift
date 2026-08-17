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
    /// Last time anything was appended. Drives ordering in the session list.
    /// Optional so sessions written by earlier builds still decode.
    var updatedAt: Date? = nil
    /// API-visible history, including raw assistant content blocks.
    var messages: [ChatMessage] = []
    var transcript: [TranscriptEntry] = []
    var usage: TokenUsage = TokenUsage()
    /// Model that produced most of this session, for the cost estimate.
    var model: String = AppSettings.Model.opus5.rawValue
    /// Claude Code's own session ID, when answers came from the relay. Passing
    /// it back as `--resume` is what makes the next question a follow-up.
    /// Optional so sessions saved by earlier builds still decode.
    var relaySessionID: String? = nil

    var isEmpty: Bool { messages.isEmpty && transcript.isEmpty }

    var estimatedCost: Double { CostEstimator.cost(of: usage, model: model) }

    /// The first thing you asked, which is what you'll recognise it by.
    /// Falls back to the date so a session is never nameless in the list.
    var title: String {
        if let first = transcript.first(where: { $0.kind == .user })?.text {
            let cleaned = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return String(cleaned.prefix(80)) }
        }
        return Session.dateFormatter.string(from: startedAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Enough of a session to list and search it without decoding every transcript.
struct SessionSummary: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var startedAt: Date
    var updatedAt: Date
    var exchangeCount: Int
    var estimatedCost: Double
    var usedRelay: Bool
    /// Lowercased title plus transcript, for the search field.
    var searchIndex: String

    init(_ session: Session) {
        id = session.id
        title = session.title
        startedAt = session.startedAt
        updatedAt = session.updatedAt ?? session.startedAt
        exchangeCount = session.transcript.filter { $0.kind == .user }.count
        estimatedCost = session.estimatedCost
        usedRelay = session.relaySessionID != nil
        searchIndex = ([session.title] + session.transcript.map(\.text))
            .joined(separator: " ")
            .lowercased()
    }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        // Every word must appear somewhere, so "hold decline" narrows rather
        // than widening the way a single substring match would.
        return trimmed.split(separator: " ").allSatisfy { searchIndex.contains($0) }
    }
}

/// Saves conversations so closing the app — or starting a new session — doesn't
/// lose them.
///
/// One JSON file per session in a directory, rather than one file holding every
/// session. A single file would have to be read and rewritten whole on every
/// save, which grows with your history; a file per session keeps each write the
/// size of the session being written. There is deliberately no index file: it
/// would be a second thing to keep in sync, and reading the directory is only
/// needed when you actually open the session list.
struct SessionStore {
    private let directory: URL
    /// Where single-session builds kept their only conversation. Migrated on
    /// first use so upgrading doesn't lose the session you had open.
    private let legacyFileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory

        self.directory = base.appendingPathComponent("sessions", isDirectory: true)
        self.legacyFileURL = base.appendingPathComponent("pocketclaude-session.json")
        try? FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
        migrateLegacySessionIfNeeded()
    }

    // MARK: - Reading

    /// Newest first. Decodes every session, so call it when the list is opened
    /// rather than on launch.
    func summaries() -> [SessionSummary] {
        allSessions()
            .map(SessionSummary.init)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) -> Session? {
        decode(at: url(for: id))
    }

    /// The conversation to reopen on launch.
    func loadMostRecent() -> Session? {
        allSessions().max { lhs, rhs in
            (lhs.updatedAt ?? lhs.startedAt) < (rhs.updatedAt ?? rhs.startedAt)
        }
    }

    // MARK: - Writing

    /// Empty sessions aren't worth a file — tapping "new session" twice
    /// shouldn't litter the list with blanks.
    func save(_ session: Session) {
        guard !session.isEmpty else { return }
        var stamped = session
        stamped.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stamped) else { return }
        // `.completeFileProtection` keeps the transcript encrypted at rest while
        // the device is locked. Session history can quote private source code.
        try? data.write(to: url(for: session.id), options: [.atomic, .completeFileProtection])
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Removes every saved session. Only used by tests and a deliberate
    /// "delete everything" action — the toolbar's new-session button archives.
    func deleteAll() {
        for url in files() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Internals

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func files() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return (contents ?? []).filter { $0.pathExtension == "json" }
    }

    private func allSessions() -> [Session] {
        files().compactMap(decode(at:))
    }

    private func decode(at url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Session.self, from: data)
    }

    private func migrateLegacySessionIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyFileURL.path),
              let session = decode(at: legacyFileURL)
        else { return }

        if !session.isEmpty {
            save(session)
        }
        try? FileManager.default.removeItem(at: legacyFileURL)
    }
}
