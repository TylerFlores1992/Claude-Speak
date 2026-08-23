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

/// A cloud session that has been brought onto the relay machine before.
///
/// Remembered because nothing can list cloud sessions: `claude agents --json`
/// covers local background sessions only, and the teleport picker is
/// interactive. Remembering the ones you have pulled is what turns "paste every
/// link again" into one button.
struct CloudSession: Identifiable, Equatable, Sendable {
    let cloudID: String
    let localID: String?
    let title: String?
    let project: String?
    let updatedAt: Date?

    var id: String { cloudID }
    var displayTitle: String { title ?? cloudID }
}

/// The outcome of refreshing one remembered session.
struct CloudRefreshResult: Identifiable, Equatable, Sendable {
    let cloudID: String
    let ok: Bool
    let title: String?
    let problem: String?

    var id: String { cloudID }
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
                updatedAt: formatter.date(from: stamp) ?? plain.date(from: stamp) ?? .distantPast,
                isLive: entry["live"]?.boolValue ?? false
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
        let json = try await post(path: "teleport", body: body, timeout: 200)
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
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

    /// Whether the relay is serving a session to claude.ai and the Claude app.
    struct RemoteControlState: Equatable, Sendable {
        var running: Bool
        var url: URL?
        var problem: String?
    }

    func remoteControlStatus() async throws -> RemoteControlState {
        parseRemoteControl(try await getJSON(path: "remote-control"))
    }

    /// Starts the Remote Control server on the relay machine.
    ///
    /// This is what makes a session watchable from somewhere else while the
    /// phone drives it: claude.ai/code and the Claude app connect to the
    /// session running here, so the same conversation is visible on both.
    func startRemoteControl(project: String = "") async throws -> RemoteControlState {
        var body: [String: JSONValue] = [:]
        if !project.isEmpty { body["project"] = .string(project) }
        return parseRemoteControl(try await post(path: "remote-control", body: body, timeout: 30))
    }

    func stopRemoteControl() async throws -> RemoteControlState {
        parseRemoteControl(try await post(path: "remote-control/stop", body: [:], timeout: 20))
    }

    private func parseRemoteControl(_ json: JSONValue) -> RemoteControlState {
        RemoteControlState(
            running: json["running"]?.boolValue ?? false,
            url: (json["url"]?.stringValue).flatMap(URL.init(string:)),
            problem: json["error"]?.stringValue
        )
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

    /// Re-pulls remembered cloud sessions, or one of them.
    ///
    /// Returns a result per session rather than throwing on the first failure:
    /// teleport needs a clean checkout, so one repository with uncommitted work
    /// must not hide the others that refreshed fine.
    func refreshCloudSessions(sessionID: String? = nil) async throws -> [CloudRefreshResult] {
        var body: [String: JSONValue] = [:]
        if let sessionID, !sessionID.isEmpty { body["sessionId"] = .string(sessionID) }
        // Long: each session is a teleport, and a teleport fetches a branch.
        let json = try await post(path: "cloud/refresh", body: body, timeout: 400)

        return (json["results"]?.arrayValue ?? []).compactMap { entry in
            guard let cloudID = entry["cloudId"]?.stringValue else { return nil }
            return CloudRefreshResult(
                cloudID: cloudID,
                ok: entry["ok"]?.boolValue ?? false,
                title: entry["title"]?.stringValue,
                problem: entry["error"]?.stringValue
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

    /// Starts a new cloud session with a first task, and returns its id.
    func startCloudSession(task: String, project: String = "") async throws -> CloudSession {
        var body: [String: JSONValue] = ["text": .string(task)]
        if !project.isEmpty { body["project"] = .string(project) }
        let json = try await post(path: "cloud/start", body: body, timeout: 200)
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
        guard let id = json["sessionId"]?.stringValue else {
            throw RelayError.relay("The session started but reported no id.")
        }
        return CloudSession(
            cloudID: id,
            localID: nil,
            title: json["title"]?.stringValue,
            project: project.isEmpty ? nil : project,
            updatedAt: Date()
        )
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
        // Checked here rather than in `post`, which no longer treats an "error"
        // field as fatal: Remote Control reports why it could not start in that
        // field on an otherwise successful request. This endpoint means it.
        if let problem = json["error"]?.stringValue, !problem.isEmpty {
            throw RelayError.relay(problem)
        }
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
