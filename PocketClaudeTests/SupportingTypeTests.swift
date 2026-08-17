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
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketclaude-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeSession(question: String, startedAt: Date = Date()) -> Session {
        var session = Session()
        session.startedAt = startedAt
        session.messages = [.userText(question)]
        session.transcript = [TranscriptEntry(kind: .user, text: question)]
        return session
    }

    func testSaveAndLoadPreservesRawContentBlocks() throws {
        let store = SessionStore(directory: directory)
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
        let loaded = try XCTUnwrap(store.load(id: session.id))

        XCTAssertEqual(loaded.messages, session.messages)
        XCTAssertEqual(
            loaded.messages[1].content.first?["signature"]?.stringValue,
            "sig=="
        )
        XCTAssertEqual(loaded.usage.inputTokens, 10)
    }

    func testLoadReturnsNilWhenNothingSaved() {
        XCTAssertNil(SessionStore(directory: directory).loadMostRecent())
    }

    func testDeleteRemovesOnlyThatSession() {
        let store = SessionStore(directory: directory)
        let keep = makeSession(question: "keep me")
        let drop = makeSession(question: "drop me")
        store.save(keep)
        store.save(drop)

        store.delete(id: drop.id)

        XCTAssertNotNil(store.load(id: keep.id))
        XCTAssertNil(store.load(id: drop.id))
    }

    func testSessionsAccumulateRatherThanOverwrite() {
        // The whole point of the rewrite: starting a new conversation must not
        // destroy the previous one.
        let store = SessionStore(directory: directory)
        store.save(makeSession(question: "first"))
        store.save(makeSession(question: "second"))
        store.save(makeSession(question: "third"))

        XCTAssertEqual(store.summaries().count, 3)
    }

    func testEmptySessionsAreNotSaved() {
        let store = SessionStore(directory: directory)
        store.save(Session())
        XCTAssertTrue(store.summaries().isEmpty)
    }

    func testSummariesAreNewestFirst() {
        // Explicit start dates: two saves can land in the same millisecond, so
        // `updatedAt` alone would leave the order genuinely undefined.
        let store = SessionStore(directory: directory)
        store.save(makeSession(question: "older", startedAt: Date(timeIntervalSince1970: 1_000)))
        store.save(makeSession(question: "newer", startedAt: Date(timeIntervalSince1970: 2_000)))

        let titles = store.summaries().map(\.title)
        XCTAssertEqual(titles.first, "newer")
        XCTAssertEqual(titles.last, "older")
    }

    func testOrderingIsTotalWhenTimestampsCollide() {
        // Regression: `sorted(by:)` is not stable, so equal timestamps used to
        // let the list come back in a different order each time it was opened.
        let shared = Date(timeIntervalSince1970: 5_000)
        var a = makeSession(question: "a", startedAt: shared)
        var b = makeSession(question: "b", startedAt: shared)
        a.updatedAt = shared
        b.updatedAt = shared

        let first = [SessionSummary(a), SessionSummary(b)].sorted(by: SessionSummary.newestFirst)
        let second = [SessionSummary(b), SessionSummary(a)].sorted(by: SessionSummary.newestFirst)

        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testTitleComesFromTheFirstQuestion() {
        let session = makeSession(question: "What does the hold lifecycle do?")
        XCTAssertEqual(session.title, "What does the hold lifecycle do?")
    }

    func testTitleFallsBackToADateWhenThereIsNoQuestion() {
        XCTAssertFalse(Session().title.isEmpty)
    }

    func testSearchMatchesTranscriptText() {
        var session = makeSession(question: "how do holds expire")
        session.transcript.append(
            TranscriptEntry(kind: .assistant, text: "They expire in reservations.ts")
        )
        let summary = SessionSummary(session)

        XCTAssertTrue(summary.matches("reservations"))
        XCTAssertTrue(summary.matches("holds expire"))
        XCTAssertTrue(summary.matches("HOLDS"), "search should be case-insensitive")
        XCTAssertFalse(summary.matches("campsite pricing"))
    }

    func testEmptySearchMatchesEverything() {
        XCTAssertTrue(SessionSummary(makeSession(question: "anything")).matches("  "))
    }

    func testLegacySingleSessionFileIsMigrated() throws {
        // Upgrading from a single-session build must not lose the conversation
        // that was open at the time.
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let legacy = directory.appendingPathComponent("pocketclaude-session.json")
        let session = makeSession(question: "from the old build")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: legacy)

        let store = SessionStore(directory: directory)

        XCTAssertEqual(store.summaries().count, 1)
        XCTAssertEqual(store.summaries().first?.title, "from the old build")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.path),
            "the legacy file should be removed once migrated"
        )
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
