import Foundation

// MARK: - Conversation history

/// One turn in the conversation, stored as raw content blocks.
///
/// `content` is `[JSONValue]` on purpose: Claude Opus 5 thinks by default, and
/// `thinking` blocks must be echoed back **unmodified** on the next turn or the
/// API rejects the request. Re-serialising through hand-written structs would
/// lose fields we don't model.
struct ChatMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var role: Role
    var content: [JSONValue]

    static func userText(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: [
            .object(["type": .string("text"), "text": .string(text)])
        ])
    }

    var wireValue: JSONValue {
        .object(["role": .string(role.rawValue), "content": .array(content)])
    }
}

// MARK: - Tool definitions

/// A tool Claude can call. `inputSchema` is a JSON Schema object.
struct ToolDefinition: Equatable, Sendable {
    var name: String
    var description: String
    var inputSchema: JSONValue
    /// Read-only tools run immediately; write tools require confirmation.
    var isWrite: Bool

    var wireValue: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "input_schema": inputSchema,
        ])
    }
}

/// A `tool_use` block Claude emitted, lifted out of the raw content array.
struct ToolCall: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var input: JSONValue
}

/// Our answer to a `tool_use`, sent back as a `tool_result` block.
struct ToolOutcome: Equatable, Sendable {
    var toolUseID: String
    var text: String
    var isError: Bool

    var wireValue: JSONValue {
        var block: [String: JSONValue] = [
            "type": .string("tool_result"),
            "tool_use_id": .string(toolUseID),
            "content": .string(text),
        ]
        if isError { block["is_error"] = .bool(true) }
        return .object(block)
    }
}

// MARK: - Responses

struct TokenUsage: Equatable, Sendable, Codable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationInputTokens: Int = 0
    var cacheReadInputTokens: Int = 0

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }

    static func parse(_ value: JSONValue?) -> TokenUsage {
        guard let value else { return TokenUsage() }
        return TokenUsage(
            inputTokens: value["input_tokens"]?.intValue ?? 0,
            outputTokens: value["output_tokens"]?.intValue ?? 0,
            cacheCreationInputTokens: value["cache_creation_input_tokens"]?.intValue ?? 0,
            cacheReadInputTokens: value["cache_read_input_tokens"]?.intValue ?? 0
        )
    }
}

/// A decoded `POST /v1/messages` response.
struct MessagesResponse: Equatable, Sendable {
    var id: String
    var model: String
    /// Raw content blocks, preserved verbatim for the next turn.
    var content: [JSONValue]
    var stopReason: String?
    var refusalCategory: String?
    var usage: TokenUsage

    /// Concatenated text from every `text` block.
    var text: String {
        content
            .compactMap { block -> String? in
                guard block["type"]?.stringValue == "text" else { return nil }
                return block["text"]?.stringValue
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every `tool_use` block, in order.
    var toolCalls: [ToolCall] {
        content.compactMap { block in
            guard block["type"]?.stringValue == "tool_use",
                  let id = block["id"]?.stringValue,
                  let name = block["name"]?.stringValue
            else { return nil }
            return ToolCall(id: id, name: name, input: block["input"] ?? .object([:]))
        }
    }

    var isRefusal: Bool { stopReason == "refusal" }
    var wantsToolUse: Bool { stopReason == "tool_use" }

    static func decode(from data: Data) throws -> MessagesResponse {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)

        // API-level errors come back as {"type":"error","error":{...}}.
        if root["type"]?.stringValue == "error" {
            let message = root["error"]?["message"]?.stringValue ?? "Unknown API error"
            let kind = root["error"]?["type"]?.stringValue ?? "api_error"
            throw AnthropicError.api(type: kind, message: message)
        }

        guard let content = root["content"]?.arrayValue else {
            throw AnthropicError.malformedResponse("Response had no `content` array")
        }

        return MessagesResponse(
            id: root["id"]?.stringValue ?? "",
            model: root["model"]?.stringValue ?? "",
            content: content,
            stopReason: root["stop_reason"]?.stringValue,
            // stop_details is populated only on refusals, and may be null even then.
            refusalCategory: root["stop_details"]?["category"]?.stringValue,
            usage: TokenUsage.parse(root["usage"])
        )
    }
}

// MARK: - Errors

enum AnthropicError: LocalizedError, Equatable {
    case missingAPIKey
    case api(type: String, message: String)
    case http(status: Int, body: String)
    case malformedResponse(String)
    case refused(category: String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key. Add one in Settings."
        case .api(let type, let message):
            return "Anthropic API error (\(type)): \(message)"
        case .http(let status, let body):
            return "Anthropic HTTP \(status): \(body.prefix(400))"
        case .malformedResponse(let detail):
            return "Could not read the Anthropic response: \(detail)"
        case .refused(let category):
            if let category {
                return "Claude declined this request (\(category))."
            }
            return "Claude declined this request."
        }
    }
}
