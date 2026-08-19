import XCTest
@testable import PocketClaude

/// Collects the events a real turn would hand to the speech synthesiser, in the
/// order they arrive. Ordering is the point: out-of-order chunks would scramble
/// the spoken answer.
///
/// Swift note: `@unchecked Sendable` plus a lock, rather than an actor, so the
/// `@Sendable` event closure can capture it without every read becoming `await`.
/// Deliveries all happen on the main actor, so the lock is belt and braces.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RelayEvent] = []

    func record(_ event: RelayEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }

    var events: [RelayEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var chunks: [String] {
        events.compactMap { if case .chunk(let text) = $0 { return text } else { return nil } }
    }
}

final class RelayClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> RelayClient {
        RelayClient(
            baseURL: URL(string: "http://mini-pc:8787")!,
            token: "test-token",
            session: MockURLProtocol.makeSession()
        )
    }

    /// The lines a real SSE body would produce, in order — `URLSession`'s
    /// `bytes.lines` strips the newline and yields "" for a blank separator.
    private func sseLines(_ frames: [(String, String)]) -> AsyncStream<String> {
        var lines: [String] = []
        for (event, data) in frames {
            lines.append("event: \(event)")
            lines.append("data: \(data)")
            lines.append("")
        }
        return AsyncStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    /// The same frames as `sseLines`, but with the blank separators removed —
    /// which is what `URLSession.bytes.lines` actually delivers, because
    /// Foundation's `AsyncLineSequence` strips empty lines instead of yielding
    /// "". Reading the relay through this shape is the real code path.
    private func sseLinesWithoutBlanks(_ frames: [(String, String)]) -> AsyncStream<String> {
        var lines: [String] = []
        for (event, data) in frames {
            lines.append("event: \(event)")
            lines.append("data: \(data)")
        }
        return AsyncStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    // MARK: - Request shape

    func testPostsToTheAskEndpoint() throws {
        let request = try makeClient().makeRequest(text: "hi", sessionID: nil)
        XCTAssertEqual(request.url?.absoluteString, "http://mini-pc:8787/ask")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testSendsTheBearerToken() throws {
        let request = try makeClient().makeRequest(text: "hi", sessionID: nil)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-token"
        )
    }

    func testKeepsAPathPrefixOnTheBaseURL() throws {
        // Someone fronting the relay with a reverse proxy under /pocketclaude
        // should not have that path thrown away.
        let client = RelayClient(
            baseURL: URL(string: "https://host/pocketclaude")!,
            token: "t",
            session: MockURLProtocol.makeSession()
        )
        let request = try client.makeRequest(text: "hi", sessionID: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://host/pocketclaude/ask")
    }

    func testSendsSessionIDWhenResuming() throws {
        let request = try makeClient().makeRequest(text: "and the tests?", sessionID: "session_abc")
        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(json["sessionId"]?.stringValue, "session_abc")
        XCTAssertEqual(json["text"]?.stringValue, "and the tests?")
    }

    func testSendsNullSessionIDWhenStartingFresh() throws {
        let request = try makeClient().makeRequest(text: "hi", sessionID: nil)
        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(json["sessionId"], JSONValue.null)
    }

    // MARK: - Streaming

    func testStreamsChunksInOrderAndReturnsTheFinalAnswer() async throws {
        let payload = sseLines([
            ("session", #"{"sessionId":"session_abc"}"#),
            ("chunk", #"{"text":"The hold "}"#),
            ("tool", #"{"names":["Read","Grep"]}"#),
            ("chunk", #"{"text":"lifecycle is in holds.ts."}"#),
            ("done", #"{"sessionId":"session_abc","costUSD":0.02,"isError":false,"result":"The hold lifecycle is in holds.ts."}"#),
        ])
        let recorder = EventRecorder()
        let result = try await makeClient().consume(lines: payload) { event in
            recorder.record(event)
        }

        XCTAssertEqual(result.sessionId, "session_abc")
        XCTAssertEqual(result.costUSD, 0.02)
        XCTAssertEqual(result.text, "The hold lifecycle is in holds.ts.")
        XCTAssertFalse(result.isError)

        let chunks = recorder.chunks
        XCTAssertEqual(chunks, ["The hold ", "lifecycle is in holds.ts."])

        let events = recorder.events
        XCTAssertEqual(events.first, .session("session_abc"))
        XCTAssertTrue(events.contains(.tool(["Read", "Grep"])))
    }

    func testStreamsWhenTheLineSequenceDropsBlankSeparators() async throws {
        // Regression: the reader used to end a frame only at a blank line, so
        // against the real URLSession sequence no frame ever ended — every
        // payload ran together into one unparseable string and the entire
        // answer was lost, reported as "the relay finished without an answer".
        let payload = sseLinesWithoutBlanks([
            ("session", #"{"sessionId":"session_abc"}"#),
            ("chunk", #"{"text":"The hold "}"#),
            ("tool", #"{"names":["Read","Grep"]}"#),
            ("chunk", #"{"text":"lifecycle is in holds.ts."}"#),
            ("done", #"{"sessionId":"session_abc","costUSD":0.02,"isError":false,"result":"The hold lifecycle is in holds.ts."}"#),
        ])
        let recorder = EventRecorder()
        let result = try await makeClient().consume(lines: payload) { event in
            recorder.record(event)
        }

        XCTAssertEqual(result.text, "The hold lifecycle is in holds.ts.")
        XCTAssertEqual(result.sessionId, "session_abc")
        XCTAssertEqual(recorder.chunks, ["The hold ", "lifecycle is in holds.ts."])
        XCTAssertTrue(recorder.events.contains(.tool(["Read", "Grep"])))
    }

    func testHandlesCarriageReturnsFromAWindowsRelay() async throws {
        let payload = AsyncStream<String> { continuation in
            continuation.yield("event: chunk\r")
            continuation.yield(#"data: {"text":"Answer."}"# + "\r")
            continuation.yield("event: done\r")
            continuation.yield(#"data: {"result":"Answer.","isError":false}"# + "\r")
            continuation.finish()
        }
        let recorder = EventRecorder()
        let result = try await makeClient().consume(lines: payload) { event in
            recorder.record(event)
        }

        XCTAssertEqual(recorder.chunks, ["Answer."])
        XCTAssertEqual(result.text, "Answer.")
    }

    func testStopsAtDoneEvenWithoutBlankSeparators() async throws {
        let payload = sseLinesWithoutBlanks([
            ("chunk", #"{"text":"Answer."}"#),
            ("done", #"{"sessionId":"s","result":"Answer.","isError":false}"#),
            ("chunk", #"{"text":"LEAKED"}"#),
        ])
        let recorder = EventRecorder()
        _ = try await makeClient().consume(lines: payload) { event in
            recorder.record(event)
        }

        XCTAssertEqual(recorder.chunks, ["Answer."])
    }

    func testThrowsWhenTheRelayReportsAnError() async {
        let payload = sseLines([
            ("error", #"{"message":"not logged in. Run claude auth login."}"#),
        ])

        do {
            _ = try await makeClient().consume(lines: payload) { _ in }
            XCTFail("expected an error")
        } catch let error as RelayError {
            XCTAssertEqual(error, .relay("not logged in. Run claude auth login."))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSurfacesAnUnauthorizedResponse() async {
        MockURLProtocol.handler = { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }

        do {
            _ = try await makeClient().ask(text: "q", sessionID: nil) { _ in }
            XCTFail("expected an error")
        } catch let error as RelayError {
            guard case .http(let status, _) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 401)
            // The message should point at the actual fix, not just the number.
            XCTAssertTrue(
                error.errorDescription?.contains("RELAY_TOKEN") == true,
                "unhelpful message: \(error.errorDescription ?? "")"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStopsReadingAfterTheDoneFrame() async throws {
        // Anything after `done` is not part of the answer and must not be spoken.
        let payload = sseLines([
            ("chunk", #"{"text":"Answer."}"#),
            ("done", #"{"sessionId":"s","result":"Answer.","isError":false}"#),
            ("chunk", #"{"text":"LEAKED"}"#),
        ])
        let recorder = EventRecorder()
        _ = try await makeClient().consume(lines: payload) { event in
            recorder.record(event)
        }

        let chunks = recorder.chunks
        XCTAssertEqual(chunks, ["Answer."])
    }

    func testIgnoresUnknownEventTypes() async throws {
        let payload = sseLines([
            ("mystery", #"{"whatever":true}"#),
            ("chunk", #"{"text":"Still fine."}"#),
            ("done", #"{"result":"Still fine.","isError":false}"#),
        ])
        let result = try await makeClient().consume(lines: payload) { _ in }
        XCTAssertEqual(result.text, "Still fine.")
    }

    // MARK: - Configuration

    func testMakeReturnsNilWithoutAToken() {
        KeychainStore.delete(.relayToken)
        let settings = AppSettings(defaults: Self.emptyDefaults())
        settings.relayURLString = "http://mini-pc:8787"
        XCTAssertNil(RelayClient.make(settings: settings))
    }

    func testMakeReturnsNilWithoutAnAddress() {
        let settings = AppSettings(defaults: Self.emptyDefaults())
        settings.relayURLString = ""
        XCTAssertNil(RelayClient.make(settings: settings))
    }

    func testRelayIsNotConfiguredWithoutBothPieces() {
        KeychainStore.delete(.relayToken)
        let settings = AppSettings(defaults: Self.emptyDefaults())
        settings.backend = .relay
        settings.relayURLString = "http://mini-pc:8787"
        XCTAssertFalse(settings.isRelayConfigured)
        XCTAssertFalse(settings.isConfigured)
    }

    func testRejectsAnAddressWithNoScheme() {
        let settings = AppSettings(defaults: Self.emptyDefaults())
        settings.relayURLString = "mini-pc:8787"
        XCTAssertFalse(settings.isRelayConfigured)
    }

    private static func emptyDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "relay-tests-\(UUID().uuidString)")!
        return suite
    }

    // MARK: - Model and effort

    func testSendsTheChosenModelAndEffort() throws {
        // The composer chip claimed to control these and did not: the relay
        // only ever read its own RELAY_MODEL, so a phone set to Opus was
        // answered by whatever the server was configured with.
        let client = RelayClient(baseURL: URL(string: "http://relay.test:8788")!, token: "t")
        let request = try client.makeRequest(
            text: "hello",
            sessionID: nil,
            model: "claude-opus-5",
            effort: "high"
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(json["model"]?.stringValue, "claude-opus-5")
        XCTAssertEqual(json["effort"]?.stringValue, "high")
    }

    func testOmitsModelAndEffortWhenUnset() throws {
        // Omitted rather than empty, so the relay falls back to its own
        // configuration instead of being handed "" to act on.
        let client = RelayClient(baseURL: URL(string: "http://relay.test:8788")!, token: "t")
        let request = try client.makeRequest(text: "hello", sessionID: nil)
        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertNil(json["model"])
        XCTAssertNil(json["effort"])
    }
}
