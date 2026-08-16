import Foundation

/// Thin, dependency-free client for `POST https://api.anthropic.com/v1/messages`.
///
/// Non-streaming on purpose (see DECISIONS.md). One request in, one response out;
/// the agent loop lives in `AgentRunner`.
struct AnthropicClient {
    struct Configuration: Sendable {
        var model: String
        var maxTokens: Int
        var effort: String
        var system: String
        var tools: [ToolDefinition]
        var useStructuredOutput: Bool
        /// Adaptive thinking and `output_config.effort` are Claude 4.6+ features.
        /// Sending either to an older model (Haiku 4.5) is a 400, so the caller
        /// tells us whether this model has them.
        var supportsAdaptiveThinking: Bool = true
    }

    static let apiVersion = "2023-06-01"
    static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    var baseURL: URL
    var session: URLSession
    /// Injected so tests can supply a key without touching the Keychain.
    var apiKeyProvider: @Sendable () -> String?

    init(
        baseURL: URL = AnthropicClient.defaultBaseURL,
        session: URLSession = AnthropicClient.makeSession(),
        apiKeyProvider: @escaping @Sendable () -> String? = { KeychainStore.get(.anthropicAPIKey) }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    /// Opus 5 turns with tool use can run for minutes; the default 60s timeout
    /// is far too short.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    // MARK: - Request construction

    /// Builds the JSON request body. Exposed (internal) so tests can assert on
    /// its exact shape without hitting the network.
    func makeRequestBody(messages: [ChatMessage], configuration: Configuration) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(configuration.model),
            "max_tokens": .int(configuration.maxTokens),
            "messages": .array(messages.map(\.wireValue)),
        ]

        // System prompt as a cacheable block. The prefix (tools + system) is
        // stable across every turn, so a cache breakpoint here is free money on
        // multi-turn sessions. Opus 5's minimum cacheable prefix is 512 tokens.
        body["system"] = .array([
            .object([
                "type": .string("text"),
                "text": .string(configuration.system),
                "cache_control": .object(["type": .string("ephemeral")]),
            ])
        ])

        if !configuration.tools.isEmpty {
            body["tools"] = .array(configuration.tools.map(\.wireValue))
        }

        // NOTE: no `temperature` / `top_p` / `top_k` — those are rejected with a
        // 400 on Opus 5. Steer behaviour through the system prompt instead.
        var outputConfig: [String: JSONValue] = [:]
        if configuration.supportsAdaptiveThinking {
            outputConfig["effort"] = .string(configuration.effort)
        }
        if configuration.useStructuredOutput {
            outputConfig["format"] = .object([
                "type": .string("json_schema"),
                "schema": AgentResponse.jsonSchema,
            ])
        }
        if !outputConfig.isEmpty {
            body["output_config"] = .object(outputConfig)
        }

        if configuration.supportsAdaptiveThinking {
            // Thinking is on by default on Opus 5; we don't display it, so leave
            // `display` at its default ("omitted") and just echo the blocks back.
            body["thinking"] = .object(["type": .string("adaptive")])
        }

        return .object(body)
    }

    // MARK: - Sending

    func send(messages: [ChatMessage], configuration: Configuration) async throws -> MessagesResponse {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw AnthropicError.missingAPIKey
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(
            makeRequestBody(messages: messages, configuration: configuration)
        )

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Prefer the structured error body when there is one.
            if let root = try? JSONDecoder().decode(JSONValue.self, from: data),
               let error = root["error"],
               let message = error["message"]?.stringValue {
                throw AnthropicError.api(
                    type: error["type"]?.stringValue ?? "api_error",
                    message: message
                )
            }
            throw AnthropicError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded = try MessagesResponse.decode(from: data)

        // A refusal is an HTTP 200 with `stop_reason: "refusal"` and empty or
        // partial content — checking stop_reason before reading content is
        // mandatory, not defensive.
        if decoded.isRefusal {
            throw AnthropicError.refused(category: decoded.refusalCategory)
        }

        return decoded
    }
}
