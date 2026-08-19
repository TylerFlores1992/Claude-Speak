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

    /// Pulls new relay code and restarts it, when a supervisor is running.
    ///
    /// Returns what git said. `changed` is false when already current, which is
    /// worth distinguishing: "nothing to do" and "updated" both succeed, and
    /// only one of them drops the connection.
    func update() async throws -> (message: String, changed: Bool) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RelayError.invalidURL(baseURL.absoluteString)
        }
        components.path = components.path.hasSuffix("/")
            ? components.path + "update"
            : components.path + "/update"
        guard let url = components.url else { throw RelayError.invalidURL(baseURL.absoluteString) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RelayError.relay(json["error"]?.stringValue ?? "Update failed (HTTP \(http.statusCode)).")
        }
        let changed = json["changed"]?.boolValue ?? false
        let before = json["before"]?.stringValue ?? "?"
        let after = json["after"]?.stringValue ?? "?"
        // Absent on an older relay. Assuming supervised there keeps the message
        // the same as it has always been rather than warning about nothing.
        let supervised = json["supervised"]?.boolValue ?? true

        if !changed { return ("Already up to date (\(after)).", false) }
        if supervised {
            return ("Updated \(before) → \(after). The relay is restarting.", true)
        }
        return (
            "Updated \(before) → \(after), but the relay isn't running under run.ps1, "
                + "so it can't restart itself and is still on the old code. "
                + "Stop it and run .\\relay\\run.ps1.",
            true
        )
    }

    /// Pulls a session from Anthropic's cloud onto the relay machine.
    ///
    /// After this succeeds the session is an ordinary local one: it appears in
    /// `sessions()` and `ask` can resume it like any other. Nothing about it is
    /// special afterwards, which is why this is the route worth having rather
    /// than a parallel cloud-session mode through the whole app.
    ///
    /// What comes across is the conversation and the branch. The cloud
    /// environment - its variables, its setup script, its network rules - does
    /// not; work continues in the relay machine's own environment.
    func teleport(sessionID: String, project: String = "") async throws {
        var body: [String: JSONValue] = ["sessionId": .string(sessionID)]
        if !project.isEmpty { body["project"] = .string(project) }
        _ = try await post(path: "teleport", body: body, timeout: 200)
    }

    /// Queues a message into a cloud session.
    ///
    /// Returns without an answer, because the CLI returns without one: this
    /// posts the message and exits. Read the reply in the Claude app, or
    /// teleport the session first if you want it answered here.
    func sendToCloud(sessionID: String, text: String) async throws -> URL? {
        let json = try await post(
            path: "cloud/send",
            body: ["sessionId": .string(sessionID), "text": .string(text)],
            timeout: 70
        )
        return (json["url"]?.stringValue).flatMap(URL.init(string:))
    }

    /// Shared plumbing for the endpoints that post JSON and read JSON back.
    private func post(
        path: String,
        body: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> JSONValue {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RelayError.invalidURL(baseURL.absoluteString)
        }
        components.path = components.path.hasSuffix("/")
            ? components.path + path
            : components.path + "/" + path
        guard let url = components.url else { throw RelayError.invalidURL(baseURL.absoluteString) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let (data, response) = try await session.data(for: request)
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RelayError.relay(
                json["error"]?.stringValue ?? "The relay refused that (HTTP \(http.statusCode))."
            )
        }
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
        return json
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
