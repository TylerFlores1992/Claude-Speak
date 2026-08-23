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
    /// Running right now — usually being served to claude.ai by Remote
    /// Control. Resuming one is walking into a live conversation, not
    /// reopening a transcript.
    let isLive: Bool

    /// Sessions in an empty scratch directory aren't about code.
    var isChat: Bool { project.lowercased() == "chat" || projectPath.hasSuffix("pocketclaude-chat") }
}

/// A cloud session this app has been told about.
///
/// Remembered because nothing can list cloud sessions: there is no API for it,
/// and `claude agents --json` covers local background sessions only. Keeping
/// the ones you have added is what turns "paste the link again" into a row you
/// can tap.
struct CloudSession: Identifiable, Equatable, Sendable {
    let cloudID: String
    let localID: String?
    let title: String?
    let project: String?
    let updatedAt: Date?

    var id: String { cloudID }
    var displayTitle: String { title ?? cloudID }
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
                updatedAt: formatter.date(from: stamp) ?? plain.date(from: stamp) ?? .distantPast,
                isLive: entry["live"]?.boolValue ?? false
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

    /// Hides a session from the list. The transcript stays on the relay
    /// machine and `claude --resume` still works at a keyboard — it has only
    /// left this list.
    func archiveSession(id: String) async throws {
        let json = try await post(path: "sessions/archive", body: ["id": .string(id)], timeout: 15)
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
    }

    /// Deletes a session's transcript file. Not undoable, which is why the UI
    /// confirms first and archive is the swipe that doesn't.
    func deleteSession(id: String) async throws {
        let json = try await post(path: "sessions/delete", body: ["id": .string(id)], timeout: 15)
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
    }

    /// Cloud sessions this relay has pulled down before.
    func cloudSessions() async throws -> [CloudSession] {
        let json = try await getJSON(path: "cloud")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        return (json["sessions"]?.arrayValue ?? []).compactMap { entry in
            guard let cloudID = entry["cloudId"]?.stringValue else { return nil }
            let stamp = entry["updatedAt"]?.stringValue ?? ""
            return CloudSession(
                cloudID: cloudID,
                localID: entry["localId"]?.stringValue,
                title: entry["title"]?.stringValue,
                project: entry["project"]?.stringValue,
                updatedAt: formatter.date(from: stamp) ?? plain.date(from: stamp)
            )
        }
    }

    /// Adds a cloud session to the remembered list from its link.
    ///
    /// Adding is an act of interest, so the relay also marks its answers as
    /// wanted — otherwise the first question asked would be refused by the
    /// hook's own probe.
    func addCloudSession(link: String, title: String = "") async throws -> CloudSession {
        var body: [String: JSONValue] = ["sessionId": .string(link)]
        if !title.isEmpty { body["title"] = .string(title) }
        let json = try await post(path: "cloud/add", body: body, timeout: 20)
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
        guard let id = json["sessionId"]?.stringValue else {
            throw RelayError.relay("The relay didn't return a session id.")
        }
        return CloudSession(
            cloudID: id,
            localID: nil,
            title: json["title"]?.stringValue,
            project: nil,
            updatedAt: Date()
        )
    }

    /// Renames a session on the relay machine.
    ///
    /// An empty name puts the default back, whatever that was — a title set
    /// with `/rename` in the session, a generated one, or the first question.
    func renameSession(id: String, title: String) async throws {
        let json = try await post(
            path: "sessions/rename",
            body: ["id": .string(id), "title": .string(title)],
            timeout: 20
        )
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
    }

    /// Renames a cloud session in this list.
    ///
    /// The session on claude.ai is untouched: this is the label on a row here,
    /// not its name over there.
    func renameCloudSession(id: String, title: String) async throws {
        let json = try await post(
            path: "cloud/rename",
            body: ["sessionId": .string(id), "title": .string(title)],
            timeout: 20
        )
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
    }

    /// Drops a session from the list. The session itself is untouched — it
    /// keeps running on claude.ai and can be added again from its link.
    func forgetCloudSession(id: String) async throws {
        let json = try await post(path: "cloud/forget", body: ["sessionId": .string(id)], timeout: 20)
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
    }

    /// What the app can show of a cloud session's conversation.
    ///
    /// Either the relay's own notes — the questions this app sent and the
    /// answers that came back — or, once pulled, the session's real history.
    /// `pulled` says which, and `pullPending` says a pull is waiting on the
    /// session's next turn.
    struct CloudHistory {
        var messages: [TranscriptEntry]
        var pulled: Bool
        var pullPending: Bool
    }

    func cloudTranscript(id: String) async throws -> CloudHistory {
        let json = try await getJSON(path: "cloud/transcript?sessionId=\(id)")
        let messages = (json["messages"]?.arrayValue ?? []).compactMap { entry -> TranscriptEntry? in
            guard let text = entry["text"]?.stringValue, !text.isEmpty else { return nil }
            let role = entry["role"]?.stringValue ?? "assistant"
            return TranscriptEntry(kind: role == "user" ? .user : .assistant, text: text)
        }
        return CloudHistory(
            messages: messages,
            pulled: json["pulled"]?.boolValue ?? false,
            pullPending: json["pullPending"]?.boolValue ?? false
        )
    }

    /// Asks a cloud session to send back its own conversation.
    ///
    /// This sends no message and forces no turn. The relay leaves a note that
    /// the session's Stop hook — which runs inside the session, where the
    /// transcript actually is — reads the next time the session finishes a
    /// turn. So the history arrives alongside the next reply, which in practice
    /// means the next thing you say to it.
    func pullCloudHistory(id: String) async throws {
        let json = try await post(path: "cloud/pull", body: ["sessionId": .string(id)], timeout: 20)
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
    }

    /// A quick liveness check, used before an operation that would otherwise
    /// sit for minutes.
    ///
    /// Starting a cloud session legitimately takes a while — Anthropic has to
    /// provision a VM and clone the repository — so its timeout is generous.
    /// That generosity is miserable when the relay is simply not there: the
    /// request waits out the whole window before failing. Five seconds against
    /// `/health` separates "unreachable" from "working on it" immediately.
    func isReachable() async -> Bool {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        components.path = components.path.hasSuffix("/")
            ? components.path + "health"
            : components.path + "/health"
        guard let url = components.url else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// Asks a cloud session and waits for the answer.
    ///
    /// The whole turn runs on Anthropic's infrastructure, in the session you
    /// can open in the Claude app, and comes back through a Stop hook
    /// committed to that repository. The relay is a courier — nothing about
    /// this answer was computed on your machine.
    ///
    /// Not streamed, unlike `ask`: the hook fires once, when the turn is over,
    /// so there is nothing to speak as it arrives. The trade is that the
    /// conversation lives somewhere you can pick it up from any device.
    func askCloud(sessionID: String, text: String, timeout: TimeInterval = 300) async throws -> String {
        let json = try await post(
            path: "cloud/ask",
            body: [
                "sessionId": .string(sessionID),
                "text": .string(text),
                // A little under the request timeout, so the relay gives up
                // and explains before the connection does it wordlessly.
                "timeoutMs": .number(Double(Int(timeout - 20) * 1000)),
            ],
            timeout: timeout
        )
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
        guard let answer = json["answer"]?.stringValue, !answer.isEmpty else {
            throw RelayError.emptyResponse
        }
        return answer
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
        // Deliberately not throwing on an "error" field here. Remote Control
        // reports why it could not start in that field while the request
        // itself succeeded, and the phone needs to show that reason rather
        // than a generic failure. Callers that want it fatal check it.
        return json
    }

    /// Shared plumbing for the two read-only endpoints.
    private func getJSON(path: String) async throws -> JSONValue {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RelayError.invalidURL(baseURL.absoluteString)
        }

        // A query string has to be set as the query, never folded into the
        // path. `URLComponents` percent-encodes whatever the path setter is
        // given, so a "?" handed to it becomes "%3F" and the relay sees one
        // long path with no parameters at all — a 400 that reads like the
        // relay is down rather than like a malformed URL.
        let route: String
        let query: String?
        if let split = path.firstIndex(of: "?") {
            route = String(path[path.startIndex..<split])
            query = String(path[path.index(after: split)...])
        } else {
            route = path
            query = nil
        }

        components.path = components.path.hasSuffix("/")
            ? components.path + route
            : components.path + "/" + route
        if let query, !query.isEmpty {
            components.percentEncodedQuery = query
        }
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
