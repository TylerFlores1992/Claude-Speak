import XCTest
@testable import PocketClaude

/// The tool-call layer: this is what the agent actually reaches through, so URL
/// construction, auth headers, decoding, and the branch guard are all covered.
final class GitHubClientTests: XCTestCase {
    private let repo = RepositoryRef(owner: "tylerflores1992", name: "camphawk")

    private func makeClient() -> GitHubClient {
        GitHubClient(
            baseURL: URL(string: "https://api.github.com")!,
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "test-token" }
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

    // MARK: - Branch guard (the never-push-to-main rule)

    func testGuardRejectsMain() {
        XCTAssertThrowsError(try GitHubClient.guardBranch("main", defaultBranch: nil))
    }

    func testGuardRejectsMasterRegardlessOfCase() {
        XCTAssertThrowsError(try GitHubClient.guardBranch("MASTER", defaultBranch: nil))
    }

    func testGuardRejectsTheRepositorysDefaultBranch() {
        XCTAssertThrowsError(try GitHubClient.guardBranch("develop", defaultBranch: "develop"))
    }

    func testGuardAllowsFeatureBranch() {
        XCTAssertNoThrow(try GitHubClient.guardBranch("fix/hold-decline", defaultBranch: "main"))
    }

    func testPutFileRefusesProtectedBranchWithoutMakingARequest() async {
        let client = makeClient()
        MockURLProtocol.handler = { _ in (200, Data.json("{}")) }

        do {
            _ = try await client.putFile(
                repo,
                path: "a.ts",
                content: "x",
                message: "m",
                branch: "main",
                defaultBranch: "main"
            )
            XCTFail("Expected the guard to reject a write to main")
        } catch let error as GitHubError {
            guard case .protectedBranch = error else {
                return XCTFail("Expected .protectedBranch, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(MockURLProtocol.recorded.isEmpty, "The guard must fail before any network call")
    }

    func testCreateBranchRefusesToCreateABranchNamedMain() async {
        let client = makeClient()
        MockURLProtocol.handler = { _ in (200, Data.json("{}")) }
        do {
            _ = try await client.createBranch(
                repo, branch: "main", fromBranch: "main", defaultBranch: "main"
            )
            XCTFail("Expected rejection")
        } catch let error as GitHubError {
            guard case .protectedBranch = error else {
                return XCTFail("Expected .protectedBranch, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Auth and URLs

    func testSendsBearerTokenAndAPIVersionHeaders() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { _ in
            (200, Data.json(#"{"default_branch":"main","private":true}"#))
        }

        _ = try await client.repositoryInfo(repo)

        let request = try XCTUnwrap(MockURLProtocol.recorded.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.url?.path, "/repos/tylerflores1992/camphawk")
    }

    func testMissingTokenThrowsBeforeAnyRequest() async {
        let client = GitHubClient(
            baseURL: URL(string: "https://api.github.com")!,
            session: MockURLProtocol.makeSession(),
            tokenProvider: { nil }
        )
        do {
            _ = try await client.repositoryInfo(repo)
            XCTFail("Expected .missingToken")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .missingToken)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    func testPathsWithSpacesArePercentEncoded() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { _ in
            (200, Data.json(#"{"content":"aGk=","sha":"abc"}"#))
        }

        _ = try await client.readFile(repo, path: "docs/my notes.md", ref: "main")

        let request = try XCTUnwrap(MockURLProtocol.recorded.first)
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("my%20notes.md"), "Got \(url)")
        XCTAssertTrue(url.contains("ref=main"))
    }

    // MARK: - Decoding

    func testDecodeBase64ContentHandlesEmbeddedNewlines() {
        // GitHub wraps base64 at 60 characters; Data(base64Encoded:) rejects that
        // by default, which is exactly the bug this guards against.
        let encoded = "aGVsbG8g\nd29ybGQ=\n"
        XCTAssertEqual(GitHubClient.decodeBase64Content(encoded), "hello world")
    }

    func testDecodeBase64ContentReturnsNilForNonUTF8() {
        // 0xFF 0xFE is not valid UTF-8.
        let encoded = Data([0xFF, 0xFE]).base64EncodedString()
        XCTAssertNil(GitHubClient.decodeBase64Content(encoded))
    }

    func testReadFileTruncatesOversizedFiles() async throws {
        let client = makeClient()
        let huge = String(repeating: "a", count: GitHubClient.maxFileCharacters + 500)
        let encoded = Data(huge.utf8).base64EncodedString()
        MockURLProtocol.handler = { _ in
            (200, Data.json(#"{"content":"\#(encoded)","sha":"sha1"}"#))
        }

        let file = try await client.readFile(repo, path: "big.ts", ref: "main")
        XCTAssertTrue(file.truncated)
        XCTAssertEqual(file.text.count, GitHubClient.maxFileCharacters)
    }

    func testReadFileOnADirectoryIsAClearError() async {
        let client = makeClient()
        MockURLProtocol.handler = { _ in (200, Data.json("[]")) }
        do {
            _ = try await client.readFile(repo, path: "src", ref: "main")
            XCTFail("Expected a decoding error")
        } catch let error as GitHubError {
            guard case .decoding(let message) = error else {
                return XCTFail("Expected .decoding, got \(error)")
            }
            XCTAssertTrue(message.contains("directory"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testListFilesFiltersByPrefixAndKeepsTypes() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { _ in
            (200, Data.json("""
            {"tree":[
              {"path":"src/a.ts","type":"blob","size":10},
              {"path":"src/nested","type":"tree"},
              {"path":"docs/b.md","type":"blob","size":20}
            ]}
            """))
        }

        let entries = try await client.listFiles(repo, ref: "main", pathPrefix: "src/")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.path, "src/a.ts")
        XCTAssertEqual(entries.first?.size, 10)
        XCTAssertEqual(entries.last?.type, "tree")
    }

    func testListIssuesExcludesPullRequests() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { _ in
            (200, Data.json("""
            [
              {"number":1,"title":"Real issue","state":"open"},
              {"number":2,"title":"A PR","state":"open","pull_request":{"url":"x"}}
            ]
            """))
        }

        let issues = try await client.listIssues(repo, state: "open", limit: 20)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?["title"]?.stringValue, "Real issue")
    }

    func testSearchCodeScopesQueryToTheRepository() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { _ in
            (200, Data.json("""
            {"items":[{"path":"lib/holds.ts","text_matches":[{"fragment":"RC_HOLD_CAPACITY = 4"}]}]}
            """))
        }

        let hits = try await client.searchCode(repo, query: "RC_HOLD_CAPACITY")

        let request = try XCTUnwrap(MockURLProtocol.recorded.first)
        let query = try XCTUnwrap(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value
        )
        XCTAssertEqual(query, "RC_HOLD_CAPACITY repo:tylerflores1992/camphawk")
        XCTAssertEqual(hits.first?.path, "lib/holds.ts")
        XCTAssertEqual(hits.first?.snippet, "RC_HOLD_CAPACITY = 4")
    }

    // MARK: - Writes

    func testPutFileSendsBase64ContentAndBranch() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                // "does this file already exist?" — say no.
                return (404, Data.json(#"{"message":"Not Found"}"#))
            }
            return (201, Data.json(#"{"commit":{"sha":"deadbeefcafe"}}"#))
        }

        let result = try await client.putFile(
            repo,
            path: "lib/holds.ts",
            content: "export const x = 1\n",
            message: "Add x",
            branch: "fix/holds",
            defaultBranch: "main"
        )

        XCTAssertEqual(result.branch, "fix/holds")
        XCTAssertEqual(result.commitSHA, "deadbeefcafe")

        let put = try XCTUnwrap(MockURLProtocol.recorded.last)
        XCTAssertEqual(put.httpMethod, "PUT")
        let body = try XCTUnwrap(MockURLProtocol.json(of: put))
        XCTAssertEqual(body["branch"]?.stringValue, "fix/holds")
        XCTAssertEqual(body["message"]?.stringValue, "Add x")
        XCTAssertNil(body["sha"], "A new file must not carry a blob sha")
        let encoded = try XCTUnwrap(body["content"]?.stringValue)
        XCTAssertEqual(GitHubClient.decodeBase64Content(encoded), "export const x = 1\n")
    }

    func testPutFileIncludesExistingBlobSHAWhenReplacing() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                let encoded = Data("old".utf8).base64EncodedString()
                return (200, Data.json(#"{"content":"\#(encoded)","sha":"oldsha"}"#))
            }
            return (200, Data.json(#"{"commit":{"sha":"newsha"}}"#))
        }

        _ = try await client.putFile(
            repo, path: "a.ts", content: "new", message: "m",
            branch: "feature", defaultBranch: "main"
        )

        let body = try XCTUnwrap(MockURLProtocol.json(of: MockURLProtocol.recorded.last!))
        XCTAssertEqual(body["sha"]?.stringValue, "oldsha")
    }

    func testCreateBranchResolvesBaseSHAThenPostsRef() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                return (200, Data.json(#"{"object":{"sha":"basesha"}}"#))
            }
            return (201, Data.json(#"{"ref":"refs/heads/fix/x"}"#))
        }

        let sha = try await client.createBranch(
            repo, branch: "fix/x", fromBranch: "main", defaultBranch: "main"
        )
        XCTAssertEqual(sha, "basesha")

        let post = try XCTUnwrap(MockURLProtocol.recorded.last)
        let body = try XCTUnwrap(MockURLProtocol.json(of: post))
        XCTAssertEqual(body["ref"]?.stringValue, "refs/heads/fix/x")
        XCTAssertEqual(body["sha"]?.stringValue, "basesha")
    }

    func testCreatePullRequestReturnsNumberAndURL() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { _ in
            (201, Data.json("""
            {"number":42,"html_url":"https://github.com/o/r/pull/42","title":"Fix decline path"}
            """))
        }

        let result = try await client.createPullRequest(
            repo, title: "Fix decline path", head: "fix/decline", base: "main", body: nil
        )
        XCTAssertEqual(result.number, 42)
        XCTAssertEqual(result.url, "https://github.com/o/r/pull/42")
    }

    func testCreatePullRequestRefusesMainAsHead() async {
        let client = makeClient()
        MockURLProtocol.handler = { _ in (201, Data.json("{}")) }
        do {
            _ = try await client.createPullRequest(
                repo, title: "t", head: "main", base: "main", body: nil
            )
            XCTFail("Expected rejection")
        } catch let error as GitHubError {
            guard case .protectedBranch = error else {
                return XCTFail("Expected .protectedBranch, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Errors

    func testHTTPErrorSurfacesGitHubMessage() async {
        let client = makeClient()
        MockURLProtocol.handler = { _ in
            (403, Data.json(#"{"message":"Resource not accessible by personal access token"}"#))
        }
        do {
            _ = try await client.repositoryInfo(repo)
            XCTFail("Expected an HTTP error")
        } catch let error as GitHubError {
            guard case .http(let status, let message) = error else {
                return XCTFail("Expected .http, got \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertTrue(message.contains("personal access token"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNotFoundIsItsOwnCase() async {
        let client = makeClient()
        MockURLProtocol.handler = { _ in (404, Data.json(#"{"message":"Not Found"}"#)) }
        do {
            _ = try await client.repositoryInfo(repo)
            XCTFail("Expected .notFound")
        } catch let error as GitHubError {
            guard case .notFound = error else {
                return XCTFail("Expected .notFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
