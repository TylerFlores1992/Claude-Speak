import Foundation

/// Progress signals emitted while a turn runs, so the UI can show what the agent
/// is doing without the person having to guess at silence.
enum AgentEvent: Equatable, Sendable {
    case thinking
    case toolStarted(name: String, detail: String)
    case toolFinished(name: String, succeeded: Bool)
    case awaitingConfirmation(prompt: String)
    case confirmationDeclined(name: String)
}

struct AgentTurnResult: Equatable, Sendable {
    var response: AgentResponse
    var usage: TokenUsage
    var model: String
}

/// The agent loop: call the API, execute any tools it asks for, feed the results
/// back, repeat until Claude stops calling tools.
///
/// This is the manual loop rather than an SDK tool runner — there is no
/// Anthropic Swift SDK, and writing the loop by hand is about forty lines.
struct AgentRunner {
    typealias EventHandler = @MainActor (AgentEvent) -> Void
    typealias ConfirmationHandler = @MainActor (ToolCall) async -> Bool

    /// Hard stop so a confused model can't bill you for an infinite tool loop.
    static let maxIterations = 12

    var anthropic: AnthropicClient
    var executor: ToolExecutor
    var allowWrites: Bool

    /// Runs one user turn to completion.
    ///
    /// `messages` is `inout` so the caller keeps the full history — including the
    /// assistant's raw content blocks — for the next turn.
    func run(
        messages: inout [ChatMessage],
        configuration: AnthropicClient.Configuration,
        onEvent: @escaping EventHandler,
        confirm: @escaping ConfirmationHandler
    ) async throws -> AgentTurnResult {
        var totalUsage = TokenUsage()
        var lastModel = configuration.model

        for iteration in 0..<Self.maxIterations {
            await onEvent(.thinking)

            let response = try await anthropic.send(messages: messages, configuration: configuration)
            totalUsage = totalUsage + response.usage
            if !response.model.isEmpty { lastModel = response.model }

            // Echo the assistant turn back verbatim. Thinking blocks carry an
            // opaque signature and must survive this round trip unmodified.
            messages.append(ChatMessage(role: .assistant, content: response.content))

            guard response.wantsToolUse, !response.toolCalls.isEmpty else {
                return AgentTurnResult(
                    response: ResponseParser.parse(response.text),
                    usage: totalUsage,
                    model: lastModel
                )
            }

            // All tool_result blocks for one assistant turn must go back in a
            // single user message — splitting them across messages trains the
            // model out of parallel tool calls.
            var outcomes: [ToolOutcome] = []
            for call in response.toolCalls {
                outcomes.append(await handle(call, onEvent: onEvent, confirm: confirm))
            }
            messages.append(ChatMessage(role: .user, content: outcomes.map(\.wireValue)))

            if iteration == Self.maxIterations - 1 {
                return AgentTurnResult(
                    response: AgentResponse(
                        spoken: "I hit the tool limit for this turn. Ask me to continue and I'll pick up where I left off.",
                        detail: "Stopped after \(Self.maxIterations) tool rounds without a final answer. The conversation is intact — send another message to continue."
                    ),
                    usage: totalUsage,
                    model: lastModel
                )
            }
        }

        // Unreachable: the loop always returns. Kept for exhaustiveness.
        throw AnthropicError.malformedResponse("Agent loop ended without a result")
    }

    // MARK: - One tool call

    private func handle(
        _ call: ToolCall,
        onEvent: @escaping EventHandler,
        confirm: @escaping ConfirmationHandler
    ) async -> ToolOutcome {
        let isWrite = ToolCatalog.isWrite(call.name)

        // Belt and braces: even if a stale tool list leaked a write tool into the
        // request, refuse it when writes are off.
        if isWrite && !allowWrites {
            return ToolOutcome(
                toolUseID: call.id,
                text: "Error: write tools are disabled in Settings. Describe the change instead of making it.",
                isError: true
            )
        }

        if isWrite {
            let prompt = ToolCatalog.confirmationPrompt(for: call)
            await onEvent(.awaitingConfirmation(prompt: prompt))
            let approved = await confirm(call)
            guard approved else {
                await onEvent(.confirmationDeclined(name: call.name))
                return ToolOutcome(
                    toolUseID: call.id,
                    text: "The user declined this action. Do not retry it. Ask what they would like to do differently, or continue without it.",
                    isError: true
                )
            }
        }

        await onEvent(.toolStarted(name: call.name, detail: Self.detail(for: call)))
        let outcome = await executor.execute(call)
        await onEvent(.toolFinished(name: call.name, succeeded: !outcome.isError))
        return outcome
    }

    /// A compact one-liner about a tool call, for the transcript.
    static func detail(for call: ToolCall) -> String {
        switch call.name {
        case ToolCatalog.Name.readFile:
            return call.input["path"]?.stringValue ?? ""
        case ToolCatalog.Name.searchCode:
            return call.input["query"]?.stringValue ?? ""
        case ToolCatalog.Name.listRepoFiles:
            return call.input["path_prefix"]?.stringValue ?? "whole repo"
        case ToolCatalog.Name.getIssue, ToolCatalog.Name.getPullRequest:
            return call.input["number"].map { "#\($0.displayText)" } ?? ""
        case ToolCatalog.Name.putFile:
            let path = call.input["path"]?.stringValue ?? ""
            let branch = call.input["branch"]?.stringValue ?? ""
            return "\(path) → \(branch)"
        case ToolCatalog.Name.createBranch:
            return call.input["branch"]?.stringValue ?? ""
        case ToolCatalog.Name.createPullRequest, ToolCatalog.Name.createIssue:
            return call.input["title"]?.stringValue ?? ""
        default:
            return ""
        }
    }
}
