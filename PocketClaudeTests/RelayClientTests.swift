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

    private func sse(_ frames: [(String, String)]) -> Data {
        Data(frames.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined().utf8)
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
        let payload = sse([
            ("session", #"{"sessionId":"session_abc"}"#),
            ("chunk", #"{"text":"The hold "}"#),
            ("tool", #"{"names":["Read","Grep"]}"#),
            ("chunk", #"{"text":"lifecycle is in holds.ts."}"#),
            ("done", #"{"sessionId":"session_abc","costUSD":0.02,"isError":false,"result":"The hold lifecycle is in holds.ts."}"#),
        ])
        MockURLProtocol.handler = { _ in (200, payload) }

        let recorder = EventRecorder()
        let result = try await makeClient().ask(text: "q", sessionID: nil) { event in
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

    func testThrowsWhenTheRelayReportsAnError() async {
        MockURLProtocol.handler = { _ in
            (200, self.sse([("error", #"{"message":"not logged in. Run claude auth login."}"#)]))
        }

        do {
            _ = try await makeClient().ask(text: "q", sessionID: nil) { _ in }
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
        let payload = sse([
            ("chunk", #"{"text":"Answer."}"#),
            ("done", #"{"sessionId":"s","result":"Answer.","isError":false}"#),
            ("chunk", #"{"text":"LEAKED"}"#),
        ])
        MockURLProtocol.handler = { _ in (200, payload) }

        let recorder = EventRecorder()
        _ = try await makeClient().ask(text: "q", sessionID: nil) { event in
            recorder.record(event)
        }

        let chunks = recorder.chunks
        XCTAssertEqual(chunks, ["Answer."])
    }

    func testIgnoresUnknownEventTypes() async throws {
        let payload = sse([
            ("mystery", #"{"whatever":true}"#),
            ("chunk", #"{"text":"Still fine."}"#),
            ("done", #"{"result":"Still fine.","isError":false}"#),
        ])
        MockURLProtocol.handler = { _ in (200, payload) }

        let result = try await makeClient().ask(text: "q", sessionID: nil) { _ in }
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
}
