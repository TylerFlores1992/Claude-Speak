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

// MARK: - Usage

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
