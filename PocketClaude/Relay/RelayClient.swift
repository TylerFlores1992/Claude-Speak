import Foundation

/// What the relay sends back while a question is being answered.
///
/// Swift note: this is a plain enum with associated values — the closest
/// equivalent to a TypeScript discriminated union (`{kind: "chunk", text}`),
/// and the compiler forces you to handle every case in a `switch`.
enum RelayEvent: Equatable, Sendable {
    /// The Claude Code session this answer belongs to. Arrives first; storing it
    /// is what makes the next question a follow-up rather than a fresh start.
    case session(String)
    /// A piece of the answer as it is generated. Speak these as they arrive.
    case chunk(String)
    /// Tools the agent just invoked, for the status line.
    case tool([String])
    /// A transient note (an API retry, say) worth showing but not speaking.
    case status(String)
}

/// The end of one relay answer.
struct RelayResult: Equatable, Sendable {
    var sessionId: String?
    /// Claude Code's own estimate of what this run would have cost on the API.
    /// On a subscription run nothing is actually charged — see relay/README.md.
    var costUSD: Double?
    /// The complete answer. Authoritative: the streamed chunks are a preview,
    /// and this is what gets written to the transcript.
    var text: String?
    var isError: Bool = false
}

enum RelayError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL(String)
    case http(status: Int, body: String)
    case relay(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Set the relay address and token in Settings, or switch back to Direct API."
        case .invalidURL(let value):
            return "Relay address isn't a valid URL: \(value)"
        case .http(let status, let body):
            if status == 401 {
                return "Relay rejected the token (401). Check it matches RELAY_TOKEN on the server."
            }
            let detail = body.isEmpty ? "" : " — \(body.prefix(200))"
            return "Relay HTTP \(status)\(detail)"
        case .relay(let message):
            return message
        case .emptyResponse:
            return "The relay finished without an answer."
        }
    }
}

/// Talks to the `relay/server.mjs` running on your own machine, which drives the
/// Claude Code CLI against a local checkout.
///
/// The whole point of this path is that it costs nothing per question: the CLI
/// authenticates with your Claude subscription rather than an API key.
struct RelayClient {
    typealias EventHandler = @MainActor @Sendable (RelayEvent) -> Void

    var baseURL: URL
    var token: String
    var session: URLSession

    init(baseURL: URL, token: String, session: URLSession = RelayClient.makeSession()) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Long timeout because a real agent turn — reading files, running tests —
    /// routinely takes minutes. The relay enforces its own ceiling too.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Build a client from settings, or nil when the relay isn't set up.
    static func make(settings: AppSettings, session: URLSession? = nil) -> RelayClient? {
        let raw = settings.relayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme != nil,
              let token = KeychainStore.get(.relayToken),
              !token.isEmpty
        else { return nil }

        if let session {
            return RelayClient(baseURL: url, token: token, session: session)
        }
        return RelayClient(baseURL: url, token: token)
    }

    func makeRequest(text: String, sessionID: String?, project: String = "") throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RelayError.invalidURL(baseURL.absoluteString)
        }
        // Append rather than replace, so a base URL with a path prefix works.
        components.path = components.path.hasSuffix("/")
            ? components.path + "ask"
            : components.path + "/ask"
        guard let url = components.url else {
            throw RelayError.invalidURL(baseURL.absoluteString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var body: [String: JSONValue] = ["text": .string(text)]
        body["sessionId"] = sessionID.map(JSONValue.string) ?? .null
        // Omitted rather than empty when unset, so the relay falls back to its
        // configured repository instead of failing an allowlist lookup on "".
        if !project.isEmpty { body["project"] = .string(project) }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        return request
    }

    /// Sends one question and streams the answer back.
    ///
    /// `onEvent` fires on the main actor for each chunk, so the caller can hand
    /// text straight to the speech synthesiser without hopping threads.
    @discardableResult
    func ask(
        text: String,
        sessionID: String?,
        project: String = "",
        onEvent: @escaping EventHandler
    ) async throws -> RelayResult {
        let request = try makeRequest(text: text, sessionID: sessionID, project: project)
        let (bytes, response) = try await session.bytes(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Drain a little of the body so the error message says something.
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 500 { break }
            }
            throw RelayError.http(status: http.statusCode, body: body)
        }

        return try await consume(lines: bytes.lines, onEvent: onEvent)
    }

    /// Parses an SSE stream into events and a final result.
    ///
    /// Split out from `ask` so the framing rules can be tested against a plain
    /// sequence of lines. Stubbing `URLSession.bytes(for:)` tests URLSession,
    /// not this; the interesting behaviour is all here.
    func consume<Lines: AsyncSequence>(
        lines: Lines,
        onEvent: @escaping EventHandler
    ) async throws -> RelayResult where Lines.Element == String {
        var result = RelayResult()
        var eventName = ""
        var dataLine = ""
        var finished = false

        // Minimal SSE reader. A frame ends at a blank line *or* at the next
        // frame's `event:` line.
        //
        // Both, because the blank line can't be relied on: Foundation's
        // `AsyncLineSequence` — which is what `URLSession.bytes.lines` gives
        // you — strips empty lines rather than yielding "". Waiting only for a
        // blank line meant no frame ever ended, every payload accumulated into
        // one unparseable string, and the whole answer was silently lost.
        for try await raw in lines {
            // Tolerate CRLF, since the relay is often on Windows.
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let startsNewFrame = line.hasPrefix("event:")
                && !eventName.isEmpty
                && !dataLine.isEmpty

            if line.isEmpty || startsNewFrame {
                if let terminal = try await dispatch(
                    eventName: eventName,
                    dataLine: dataLine,
                    into: &result,
                    onEvent: onEvent
                ), terminal {
                    finished = true
                }
                eventName = ""
                dataLine = ""
                if finished { break }
                // A blank line carries nothing else; an `event:` line still
                // needs parsing below as the start of the next frame.
                if line.isEmpty { continue }
            }

            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLine += String(line.dropFirst("data:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // A stream that ended without a separator after its last frame — which
        // is every stream, when the line sequence drops blank lines.
        if !finished {
            _ = try await dispatch(
                eventName: eventName,
                dataLine: dataLine,
                into: &result,
                onEvent: onEvent
            )
        }

        return result
    }

    /// Handles one complete SSE frame.
    ///
    /// Returns nil for a frame that doesn't end the stream, `true` when the
    /// stream is finished, and throws when the relay reported a failure.
    private func dispatch(
        eventName: String,
        dataLine: String,
        into result: inout RelayResult,
        onEvent: @escaping EventHandler
    ) async throws -> Bool? {
        guard !eventName.isEmpty, !dataLine.isEmpty else { return nil }
        let payload = (try? JSONDecoder().decode(JSONValue.self, from: Data(dataLine.utf8)))
            ?? .object([:])

        switch eventName {
        case "session":
            if let id = payload["sessionId"]?.stringValue {
                result.sessionId = id
                await MainActor.run { onEvent(.session(id)) }
            }
            return nil

        case "chunk":
            if let text = payload["text"]?.stringValue, !text.isEmpty {
                await MainActor.run { onEvent(.chunk(text)) }
            }
            return nil

        case "tool":
            let names = payload["names"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !names.isEmpty {
                await MainActor.run { onEvent(.tool(names)) }
            }
            return nil

        case "status":
            if let text = payload["text"]?.stringValue {
                await MainActor.run { onEvent(.status(text)) }
            }
            return nil

        case "done":
            result.sessionId = payload["sessionId"]?.stringValue ?? result.sessionId
            result.costUSD = payload["costUSD"]?.doubleValue
            result.text = payload["result"]?.stringValue
            result.isError = payload["isError"]?.boolValue ?? false
            return true

        case "error":
            throw RelayError.relay(
                payload["message"]?.stringValue ?? "The relay reported an error."
            )

        default:
            return nil
        }
    }
}
