import XCTest
@testable import PocketClaude

final class JSONValueTests: XCTestCase {
    func testRoundTripsUnknownFields() throws {
        let raw = #"{"type":"thinking","thinking":"","signature":"abc==","extra":{"nested":[1,2,3]}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        let reencoded = try JSONEncoder().encode(value)
        let reparsed = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        XCTAssertEqual(value, reparsed)
        XCTAssertEqual(reparsed["extra"]?["nested"]?.arrayValue?.count, 3)
    }

    func testWholeNumbersEncodeAsIntegers() throws {
        let encoded = try JSONEncoder().encode(JSONValue.object(["n": .int(42)]))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #"{"n":42}"#)
    }

    func testFromBuildsNestedLiterals() {
        let value = JSONValue.from([
            "type": "object",
            "required": ["a", "b"],
            "count": 2,
            "flag": true,
        ])
        XCTAssertEqual(value["type"]?.stringValue, "object")
        XCTAssertEqual(value["required"]?.arrayValue?.count, 2)
        XCTAssertEqual(value["count"]?.intValue, 2)
        XCTAssertEqual(value["flag"]?.boolValue, true)
    }

    func testSubscriptOnNonObjectReturnsNil() {
        XCTAssertNil(JSONValue.string("hello")["key"])
    }
}

final class CostEstimatorTests: XCTestCase {
    func testOpusPricing() {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        let cost = CostEstimator.cost(of: usage, model: "claude-opus-5")
        XCTAssertEqual(cost, 30.0, accuracy: 0.001)
    }

    func testCacheReadsAreTenPercentOfInput() {
        let usage = TokenUsage(cacheReadInputTokens: 1_000_000)
        XCTAssertEqual(
            CostEstimator.cost(of: usage, model: "claude-opus-5"),
            0.5,
            accuracy: 0.001
        )
    }

    func testCacheWritesAreOneAndAQuarterInput() {
        let usage = TokenUsage(cacheCreationInputTokens: 1_000_000)
        XCTAssertEqual(
            CostEstimator.cost(of: usage, model: "claude-opus-5"),
            6.25,
            accuracy: 0.001
        )
    }

    func testUnknownModelFallsBackToOpusPricing() {
        let usage = TokenUsage(inputTokens: 1_000_000)
        XCTAssertEqual(
            CostEstimator.cost(of: usage, model: "claude-something-new"),
            5.0,
            accuracy: 0.001
        )
    }

    func testUsageAddition() {
        let a = TokenUsage(inputTokens: 1, outputTokens: 2, cacheCreationInputTokens: 3, cacheReadInputTokens: 4)
        let sum = a + a
        XCTAssertEqual(sum.inputTokens, 2)
        XCTAssertEqual(sum.outputTokens, 4)
        XCTAssertEqual(sum.cacheCreationInputTokens, 6)
        XCTAssertEqual(sum.cacheReadInputTokens, 8)
    }

    func testFormattingSmallAmounts() {
        XCTAssertEqual(CostEstimator.format(0), "$0.00")
        XCTAssertEqual(CostEstimator.format(0.004), "<$0.01")
        XCTAssertEqual(CostEstimator.format(1.239), "$1.24")
    }
}

final class SessionStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketclaude-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testSaveAndLoadPreservesRawContentBlocks() throws {
        let store = SessionStore(fileURL: fileURL)
        var session = Session()
        session.messages = [
            .userText("hello"),
            ChatMessage(role: .assistant, content: [
                .object(["type": .string("thinking"), "signature": .string("sig==")]),
                .object(["type": .string("text"), "text": .string("hi")]),
            ]),
        ]
        session.transcript = [TranscriptEntry(kind: .user, text: "hello")]
        session.usage = TokenUsage(inputTokens: 10, outputTokens: 3)

        store.save(session)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.messages, session.messages)
        XCTAssertEqual(
            loaded.messages[1].content.first?["signature"]?.stringValue,
            "sig=="
        )
        XCTAssertEqual(loaded.usage.inputTokens, 10)
    }

    func testLoadReturnsNilWhenNothingSaved() {
        XCTAssertNil(SessionStore(fileURL: fileURL).load())
    }

    func testClearRemovesTheFile() {
        let store = SessionStore(fileURL: fileURL)
        store.save(Session())
        XCTAssertNotNil(store.load())
        store.clear()
        XCTAssertNil(store.load())
    }
}

final class SystemPromptTests: XCTestCase {
    func testNamesTheRepositoryAndDefaultBranch() {
        let prompt = SystemPrompt.build(
            owner: "tylerflores1992",
            repository: "camphawk",
            defaultBranch: "develop",
            allowWrites: true
        )
        XCTAssertTrue(prompt.contains("tylerflores1992/camphawk"))
        XCTAssertTrue(prompt.contains("develop"))
    }

    func testWriteModeStatesTheNeverCommitToDefaultRule() {
        let prompt = SystemPrompt.build(
            owner: "o", repository: "r", defaultBranch: "main", allowWrites: true
        )
        XCTAssertTrue(prompt.contains("NEVER commit directly"))
        XCTAssertTrue(prompt.contains("create_pull_request"))
    }

    func testReadOnlyModeSaysWritesAreDisabled() {
        let prompt = SystemPrompt.build(
            owner: "o", repository: "r", defaultBranch: "main", allowWrites: false
        )
        XCTAssertTrue(prompt.contains("Read-only mode"))
        XCTAssertFalse(prompt.contains("NEVER commit directly"))
    }

    func testAlwaysSpecifiesTheSpokenSummaryContract() {
        let prompt = SystemPrompt.build(
            owner: "o", repository: "r", defaultBranch: nil, allowWrites: false
        )
        XCTAssertTrue(prompt.contains("spoken_summary"))
        XCTAssertTrue(prompt.contains("detail"))
    }
}

final class AppSettingsTests: XCTestCase {
    private func makeSettings() -> AppSettings {
        let suiteName = "pocketclaude.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return AppSettings(defaults: defaults)
    }

    func testRepositorySlugParsing() {
        let settings = makeSettings()
        settings.repositorySlug = "tylerflores1992/camphawk"
        XCTAssertEqual(settings.repository?.owner, "tylerflores1992")
        XCTAssertEqual(settings.repository?.name, "camphawk")
    }

    func testMalformedSlugIsRejected() {
        let settings = makeSettings()
        for bad in ["", "camphawk", "a/b/c", "/camphawk", "tyler/"] {
            settings.repositorySlug = bad
            XCTAssertNil(settings.repository, "'\(bad)' should not parse")
        }
    }

    func testDefaultsAreOpusHighAndWritesEnabled() {
        let settings = makeSettings()
        XCTAssertEqual(settings.model, .opus5)
        XCTAssertEqual(settings.effort, .high)
        XCTAssertTrue(settings.allowWriteTools)
        XCTAssertEqual(settings.voiceEngine, .system)
        XCTAssertFalse(settings.useStructuredOutput)
    }
}
