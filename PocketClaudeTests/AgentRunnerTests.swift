import XCTest
@testable import PocketClaude

/// End-to-end coverage of the agent loop with the network stubbed: tool round
/// trips, the confirmation gate, and the iteration ceiling.
final class AgentRunnerTests: XCTestCase {
    /// Mutable state shared with the stub handler.
    private final class Counter {
        var anthropicCalls = 0
    }

    private let repo = RepositoryRef(owner: "o", name: "r")

    private func makeRunner(allowWrites: Bool = true) -> AgentRunner {
        let session = MockURLProtocol.makeSession()
        return AgentRunner(
            anthropic: AnthropicClient(
                baseURL: URL(string: "https://api.anthropic.com")!,
                session: session,
                apiKeyProvider: { "sk-test" }
            ),
            executor: ToolExecutor(
                client: GitHubClient(
                    baseURL: URL(string: "https://api.github.com")!,
                    session: session,
                    tokenProvider: { "gh-token" }
                ),
                repo: repo
            ),
            allowWrites: allowWrites
        )
    }

    private var configuration: AnthropicClient.Configuration {
        AnthropicClient.Configuration(
            model: "claude-opus-5",
            maxTokens: 8_000,
            effort: "high",
            system: "system",
            tools: ToolCatalog.tools(allowWrites: true),
            useStructuredOutput: false
        )
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private static func toolUseResponse(name: String, input: String, id: String = "toolu_1") -> Data {
        Data.json("""
        {"id":"msg_a","model":"claude-opus-5",
         "content":[{"type":"tool_use","id":"\(id)","name":"\(name)","input":\(input)}],
         "stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5}}
        """)
    }

    private static func finalResponse(spoken: String, detail: String = "detail") -> Data {
        Data.json("""
        {"id":"msg_b","model":"claude-opus-5",
         "content":[{"type":"text","text":"{\\"spoken_summary\\": \\"\(spoken)\\", \\"detail\\": \\"\(detail)\\"}"}],
         "stop_reason":"end_turn","usage":{"input_tokens":20,"output_tokens":8}}
        """)
    }

    // MARK: - Read path

    @MainActor
    func testReadToolRoundTripProducesAFinalAnswer() async throws {
        let counter = Counter()
        let encoded = Data("export const RC_HOLD_CAPACITY = 4".utf8).base64EncodedString()

        MockURLProtocol.handler = { request in
            guard let host = request.url?.host else { return (500, Data()) }
            if host == "api.anthropic.com" {
                counter.anthropicCalls += 1
                return counter.anthropicCalls == 1
                    ? (200, Self.toolUseResponse(name: "read_file", input: #"{"path":"lib/holds.ts"}"#))
                    : (200, Self.finalResponse(spoken: "Capacity is four."))
            }
            if request.url?.path == "/repos/o/r" {
                return (200, Data.json(#"{"default_branch":"main"}"#))
            }
            return (200, Data.json(#"{"content":"\#(encoded)","sha":"s"}"#))
        }

        var events: [AgentEvent] = []
        var messages: [ChatMessage] = [.userText("What is the hold capacity?")]

        let result = try await makeRunner().run(
            messages: &messages,
            configuration: configuration,
            onEvent: { events.append($0) },
            confirm: { _ in XCTFail("Read tools must not ask for confirmation"); return false }
        )

        XCTAssertEqual(result.response.spoken, "Capacity is four.")
        XCTAssertEqual(result.response.detail, "detail")

        // Usage is summed across every request in the turn.
        XCTAssertEqual(result.usage.inputTokens, 30)
        XCTAssertEqual(result.usage.outputTokens, 13)

        // user → assistant(tool_use) → user(tool_result) → assistant(final)
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[2].role, .user)
        XCTAssertEqual(
            messages[2].content.first?["type"]?.stringValue,
            "tool_result"
        )
        XCTAssertEqual(
            messages[2].content.first?["tool_use_id"]?.stringValue,
            "toolu_1"
        )

        XCTAssertTrue(events.contains(.toolStarted(name: "read_file", detail: "lib/holds.ts")))
        XCTAssertTrue(events.contains(.toolFinished(name: "read_file", succeeded: true)))
    }

    // MARK: - Confirmation gate

    @MainActor
    func testWriteToolAsksForConfirmationBeforeExecuting() async throws {
        let counter = Counter()

        MockURLProtocol.handler = { request in
            guard let host = request.url?.host else { return (500, Data()) }
            if host == "api.anthropic.com" {
                counter.anthropicCalls += 1
                return counter.anthropicCalls == 1
                    ? (200, Self.toolUseResponse(
                        name: "create_branch",
                        input: #"{"branch":"fix/holds"}"#
                      ))
                    : (200, Self.finalResponse(spoken: "Branch created."))
            }
            if request.url?.path == "/repos/o/r" {
                return (200, Data.json(#"{"default_branch":"main"}"#))
            }
            if request.httpMethod == "GET" {
                return (200, Data.json(#"{"object":{"sha":"basesha"}}"#))
            }
            return (201, Data.json(#"{"ref":"refs/heads/fix/holds"}"#))
        }

        var confirmations: [ToolCall] = []
        var messages: [ChatMessage] = [.userText("Make a branch")]

        let result = try await makeRunner().run(
            messages: &messages,
            configuration: configuration,
            onEvent: { _ in },
            confirm: { call in
                confirmations.append(call)
                return true
            }
        )

        XCTAssertEqual(confirmations.count, 1)
        XCTAssertEqual(confirmations.first?.name, "create_branch")
        XCTAssertEqual(result.response.spoken, "Branch created.")

        let toolResult = try XCTUnwrap(messages[2].content.first)
        XCTAssertNil(toolResult["is_error"], "An approved write should not report an error")
    }

    @MainActor
    func testDecliningAWriteSkipsItAndTellsClaudeNotToRetry() async throws {
        let counter = Counter()

        MockURLProtocol.handler = { request in
            guard let host = request.url?.host else { return (500, Data()) }
            if host == "api.anthropic.com" {
                counter.anthropicCalls += 1
                return counter.anthropicCalls == 1
                    ? (200, Self.toolUseResponse(
                        name: "put_file",
                        input: #"{"path":"a.ts","content":"x","message":"m","branch":"feature"}"#
                      ))
                    : (200, Self.finalResponse(spoken: "Okay, I left it alone."))
            }
            XCTFail("Declined writes must never reach GitHub")
            return (500, Data())
        }

        var messages: [ChatMessage] = [.userText("Commit that")]
        var declinedEvents = 0

        let result = try await makeRunner().run(
            messages: &messages,
            configuration: configuration,
            onEvent: { event in
                if case .confirmationDeclined = event { declinedEvents += 1 }
            },
            confirm: { _ in false }
        )

        XCTAssertEqual(declinedEvents, 1)
        XCTAssertEqual(result.response.spoken, "Okay, I left it alone.")

        let toolResult = try XCTUnwrap(messages[2].content.first)
        XCTAssertEqual(toolResult["is_error"]?.boolValue, true)
        let text = try XCTUnwrap(toolResult["content"]?.stringValue)
        XCTAssertTrue(text.contains("declined"))
        XCTAssertTrue(text.contains("Do not retry"))
    }

    @MainActor
    func testWriteToolIsRefusedOutrightWhenWritesAreDisabled() async throws {
        let counter = Counter()

        MockURLProtocol.handler = { request in
            guard request.url?.host == "api.anthropic.com" else {
                XCTFail("No GitHub call should happen")
                return (500, Data())
            }
            counter.anthropicCalls += 1
            return counter.anthropicCalls == 1
                ? (200, Self.toolUseResponse(name: "put_file", input: #"{"path":"a.ts"}"#))
                : (200, Self.finalResponse(spoken: "Writes are off."))
        }

        var messages: [ChatMessage] = [.userText("Commit that")]

        _ = try await makeRunner(allowWrites: false).run(
            messages: &messages,
            configuration: configuration,
            onEvent: { _ in },
            confirm: { _ in
                XCTFail("Must not prompt when writes are disabled")
                return true
            }
        )

        let toolResult = try XCTUnwrap(messages[2].content.first)
        XCTAssertEqual(toolResult["is_error"]?.boolValue, true)
        XCTAssertTrue(
            try XCTUnwrap(toolResult["content"]?.stringValue).contains("write tools are disabled")
        )
    }

    // MARK: - Safety rails

    @MainActor
    func testLoopStopsAtTheIterationCeiling() async throws {
        // Always ask for another tool call — the runner must bail rather than
        // billing forever.
        MockURLProtocol.handler = { request in
            if request.url?.host == "api.anthropic.com" {
                return (200, Self.toolUseResponse(name: "list_repo_files", input: "{}"))
            }
            if request.url?.path == "/repos/o/r" {
                return (200, Data.json(#"{"default_branch":"main"}"#))
            }
            return (200, Data.json(#"{"tree":[]}"#))
        }

        var messages: [ChatMessage] = [.userText("loop forever")]
        let result = try await makeRunner().run(
            messages: &messages,
            configuration: configuration,
            onEvent: { _ in },
            confirm: { _ in true }
        )

        XCTAssertTrue(result.response.spoken.contains("tool limit"))
        // Each iteration appends an assistant turn and a tool-result turn.
        XCTAssertEqual(messages.count, 1 + AgentRunner.maxIterations * 2)
    }

    @MainActor
    func testAPIErrorPropagatesOutOfTheLoop() async {
        MockURLProtocol.handler = { _ in
            (429, Data.json(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#))
        }

        var messages: [ChatMessage] = [.userText("hi")]
        do {
            _ = try await makeRunner().run(
                messages: &messages,
                configuration: configuration,
                onEvent: { _ in },
                confirm: { _ in true }
            )
            XCTFail("Expected the error to propagate")
        } catch let error as AnthropicError {
            XCTAssertEqual(error, .api(type: "rate_limit_error", message: "slow down"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
