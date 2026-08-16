import XCTest
@testable import PocketClaude

final class AnthropicClientTests: XCTestCase {
    private func makeClient(key: String? = "sk-test") -> AnthropicClient {
        AnthropicClient(
            baseURL: URL(string: "https://api.anthropic.com")!,
            session: MockURLProtocol.makeSession(),
            apiKeyProvider: { key }
        )
    }

    private var configuration: AnthropicClient.Configuration {
        AnthropicClient.Configuration(
            model: "claude-opus-5",
            maxTokens: 16_000,
            effort: "high",
            system: "You are PocketClaude.",
            tools: [ToolCatalog.readTools[0]],
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

    // MARK: - Request shape

    func testRequestBodyHasRequiredFields() throws {
        let body = makeClient().makeRequestBody(
            messages: [.userText("hi")],
            configuration: configuration
        )

        XCTAssertEqual(body["model"]?.stringValue, "claude-opus-5")
        XCTAssertEqual(body["max_tokens"]?.intValue, 16_000)
        XCTAssertEqual(body["output_config"]?["effort"]?.stringValue, "high")
        XCTAssertEqual(body["thinking"]?["type"]?.stringValue, "adaptive")
        XCTAssertEqual(body["messages"]?.arrayValue?.count, 1)
        XCTAssertEqual(body["tools"]?.arrayValue?.count, 1)
    }

    /// `temperature` / `top_p` / `top_k` are rejected with a 400 on Opus 5. This
    /// test is here so nobody "helpfully" adds them back.
    func testRequestBodyOmitsSamplingParameters() {
        let body = makeClient().makeRequestBody(
            messages: [.userText("hi")],
            configuration: configuration
        )
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])
        XCTAssertNil(body["top_k"])
    }

    func testSystemPromptCarriesACacheBreakpoint() throws {
        let body = makeClient().makeRequestBody(
            messages: [.userText("hi")],
            configuration: configuration
        )
        let system = try XCTUnwrap(body["system"]?.arrayValue?.first)
        XCTAssertEqual(system["text"]?.stringValue, "You are PocketClaude.")
        XCTAssertEqual(system["cache_control"]?["type"]?.stringValue, "ephemeral")
    }

    func testStructuredOutputAddsSchemaOnlyWhenEnabled() throws {
        var enabled = configuration
        enabled.useStructuredOutput = true

        let without = makeClient().makeRequestBody(messages: [], configuration: configuration)
        let with = makeClient().makeRequestBody(messages: [], configuration: enabled)

        XCTAssertNil(without["output_config"]?["format"])
        XCTAssertEqual(with["output_config"]?["format"]?["type"]?.stringValue, "json_schema")
        let required = with["output_config"]?["format"]?["schema"]?["required"]?.arrayValue
        XCTAssertEqual(required?.compactMap(\.stringValue), ["spoken_summary", "detail"])
    }

    /// Haiku 4.5 predates adaptive thinking and the effort parameter; sending
    /// either is a 400.
    func testOlderModelsGetNeitherThinkingNorEffort() {
        var haiku = configuration
        haiku.model = "claude-haiku-4-5"
        haiku.supportsAdaptiveThinking = false

        let body = makeClient().makeRequestBody(messages: [], configuration: haiku)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        // Everything else is unchanged.
        XCTAssertEqual(body["model"]?.stringValue, "claude-haiku-4-5")
        XCTAssertNotNil(body["system"])
    }

    func testStructuredOutputStillWorksOnOlderModels() {
        var haiku = configuration
        haiku.supportsAdaptiveThinking = false
        haiku.useStructuredOutput = true

        let body = makeClient().makeRequestBody(messages: [], configuration: haiku)
        XCTAssertNil(body["output_config"]?["effort"])
        XCTAssertNotNil(body["output_config"]?["format"])
    }

    func testModelCapabilityFlags() {
        XCTAssertTrue(AppSettings.Model.opus5.supportsAdaptiveThinking)
        XCTAssertTrue(AppSettings.Model.sonnet5.supportsAdaptiveThinking)
        XCTAssertFalse(AppSettings.Model.haiku45.supportsAdaptiveThinking)
    }

    func testToolsAreOmittedWhenEmpty() {
        var noTools = configuration
        noTools.tools = []
        let body = makeClient().makeRequestBody(messages: [], configuration: noTools)
        XCTAssertNil(body["tools"])
    }

    func testSendsAuthenticationHeaders() async throws {
        MockURLProtocol.handler = { _ in
            (200, Data.json(#"{"id":"msg_1","model":"claude-opus-5","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":2}}"#))
        }

        _ = try await makeClient().send(messages: [.userText("hi")], configuration: configuration)

        let request = try XCTUnwrap(MockURLProtocol.recorded.first)
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testMissingKeyThrowsBeforeAnyRequest() async {
        do {
            _ = try await makeClient(key: nil)
                .send(messages: [.userText("hi")], configuration: configuration)
            XCTFail("Expected .missingAPIKey")
        } catch let error as AnthropicError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    // MARK: - Response decoding

    func testDecodesTextAndUsage() throws {
        let response = try MessagesResponse.decode(from: Data.json("""
        {"id":"msg_1","model":"claude-opus-5",
         "content":[{"type":"text","text":"Hello there"}],
         "stop_reason":"end_turn",
         "usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":40}}
        """))

        XCTAssertEqual(response.text, "Hello there")
        XCTAssertEqual(response.usage.inputTokens, 100)
        XCTAssertEqual(response.usage.outputTokens, 20)
        XCTAssertEqual(response.usage.cacheReadInputTokens, 40)
        XCTAssertFalse(response.wantsToolUse)
    }

    func testDecodesToolCalls() throws {
        let response = try MessagesResponse.decode(from: Data.json("""
        {"id":"msg_2","model":"claude-opus-5",
         "content":[
           {"type":"text","text":"Let me look."},
           {"type":"tool_use","id":"toolu_1","name":"read_file","input":{"path":"a.ts"}}
         ],
         "stop_reason":"tool_use",
         "usage":{"input_tokens":1,"output_tokens":1}}
        """))

        XCTAssertTrue(response.wantsToolUse)
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].id, "toolu_1")
        XCTAssertEqual(response.toolCalls[0].name, "read_file")
        XCTAssertEqual(response.toolCalls[0].input["path"]?.stringValue, "a.ts")
    }

    /// Thinking blocks carry an opaque signature and must survive the round trip
    /// byte-for-byte, or the next request is rejected.
    func testThinkingBlocksArePreservedVerbatim() throws {
        let raw = """
        {"id":"msg_3","model":"claude-opus-5",
         "content":[
           {"type":"thinking","thinking":"","signature":"AbCdEf123=="},
           {"type":"text","text":"Answer"}
         ],
         "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        let response = try MessagesResponse.decode(from: Data.json(raw))
        let echoed = ChatMessage(role: .assistant, content: response.content)

        let encoded = try JSONEncoder().encode(echoed.wireValue)
        let reparsed = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let thinking = try XCTUnwrap(reparsed["content"]?.arrayValue?.first)
        XCTAssertEqual(thinking["type"]?.stringValue, "thinking")
        XCTAssertEqual(thinking["signature"]?.stringValue, "AbCdEf123==")
    }

    func testRefusalIsSurfacedAsAnError() async {
        MockURLProtocol.handler = { _ in
            (200, Data.json("""
            {"id":"msg_4","model":"claude-opus-5","content":[],
             "stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},
             "usage":{"input_tokens":1,"output_tokens":0}}
            """))
        }

        do {
            _ = try await makeClient().send(messages: [.userText("x")], configuration: configuration)
            XCTFail("Expected .refused")
        } catch let error as AnthropicError {
            XCTAssertEqual(error, .refused(category: "cyber"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAPIErrorBodyIsMappedToATypedError() async {
        MockURLProtocol.handler = { _ in
            (400, Data.json("""
            {"type":"error","error":{"type":"invalid_request_error","message":"max_tokens too large"}}
            """))
        }

        do {
            _ = try await makeClient().send(messages: [.userText("x")], configuration: configuration)
            XCTFail("Expected an API error")
        } catch let error as AnthropicError {
            XCTAssertEqual(
                error,
                .api(type: "invalid_request_error", message: "max_tokens too large")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try MessagesResponse.decode(from: Data.json(#"{"id":"x"}"#)))
    }
}
