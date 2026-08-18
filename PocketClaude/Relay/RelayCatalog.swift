import Foundation

/// A Claude Code session living on the relay machine.
///
/// These are not this app's conversations — they are the sessions the CLI
/// itself keeps, so a conversation started at the keyboard shows up here and
/// can be picked up from the phone. That is the point of the dashboard.
struct RelaySession: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// Repository name, from the working directory the session recorded.
    let project: String
    let projectPath: String
    let updatedAt: Date

    /// Sessions in an empty scratch directory aren't about code.
    var isChat: Bool { project.lowercased() == "chat" || projectPath.hasSuffix("pocketclaude-chat") }
}

/// Somewhere a new session can run.
struct RelayProject: Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    /// "code" for a checkout, "scratch" for the empty directory used by Chat.
    let kind: String
    let available: Bool

    var id: String { name }
    var isScratch: Bool { kind == "scratch" }
}

extension RelayClient {
    /// Every Claude Code session on the relay machine, newest first.
    func sessions() async throws -> [RelaySession] {
        let json = try await getJSON(path: "sessions")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        return (json["sessions"]?.arrayValue ?? []).compactMap { entry in
            guard let id = entry["id"]?.stringValue else { return nil }
            let stamp = entry["updatedAt"]?.stringValue ?? ""
            return RelaySession(
                id: id,
                title: entry["title"]?.stringValue ?? "Untitled session",
                project: entry["project"]?.stringValue ?? "—",
                projectPath: entry["projectPath"]?.stringValue ?? "",
                // Fractional seconds are present in practice, but a relay on a
                // different platform may drop them; falling back beats showing
                // every session as 1970.
                updatedAt: formatter.date(from: stamp) ?? plain.date(from: stamp) ?? .distantPast
            )
        }
    }

    /// Workspaces a new session can be started in.
    func projects() async throws -> [RelayProject] {
        let json = try await getJSON(path: "projects")
        return (json["projects"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            return RelayProject(
                name: name,
                path: entry["path"]?.stringValue ?? "",
                kind: entry["kind"]?.stringValue ?? "code",
                available: entry["available"]?.boolValue ?? true
            )
        }
    }

    /// Shared plumbing for the two read-only endpoints.
    private func getJSON(path: String) async throws -> JSONValue {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RelayError.invalidURL(baseURL.absoluteString)
        }
        components.path = components.path.hasSuffix("/")
            ? components.path + path
            : components.path + "/" + path
        guard let url = components.url else {
            throw RelayError.invalidURL(baseURL.absoluteString)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Short: this is a directory listing, not an agent turn. Waiting two
        // minutes for a list would make the dashboard feel broken.
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RelayError.http(
                status: http.statusCode,
                body: String(decoding: data.prefix(300), as: UTF8.self)
            )
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
    }
}
