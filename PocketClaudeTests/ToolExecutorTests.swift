import XCTest
@testable import PocketClaude

final class ToolExecutorTests: XCTestCase {
    private let repo = RepositoryRef(owner: "o", name: "r")

    private func makeExecutor() -> ToolExecutor {
        let client = GitHubClient(
            baseURL: URL(string: "https://api.github.com")!,
            session: MockURLProtocol.makeSession(),
            tokenProvider: { "token" }
        )
        return ToolExecutor(client: client, repo: repo)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Dispatch

    func testUnknownToolIsReportedAsAnErrorResultNotAThrow() async {
        let outcome = await makeExecutor().execute(
            ToolCall(id: "t1", name: "definitely_not_a_tool", input: .object([:]))
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.toolUseID, "t1")
        XCTAssertTrue(outcome.text.contains("Unknown tool"))
    }

    func testMissingRequiredArgumentBecomesAToolError() async {
        MockURLProtocol.handler = { _ in (200, Data.json(#"{"default_branch":"main"}"#)) }
        let outcome = await makeExecutor().execute(
            ToolCall(id: "t2", name: ToolCatalog.Name.readFile, input: .object([:]))
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("requires 'path'"))
    }

    func testReadFileResultIncludesPathRefAndContents() async throws {
        let encoded = Data("export const x = 1".utf8).base64EncodedString()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/repos/o/r" {
                return (200, Data.json(#"{"default_branch":"main"}"#))
            }
            return (200, Data.json(#"{"content":"\#(encoded)","sha":"s"}"#))
        }

        let outcome = await makeExecutor().execute(
            ToolCall(
                id: "t3",
                name: ToolCatalog.Name.readFile,
                input: .object(["path": .string("lib/x.ts")])
            )
        )

        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("lib/x.ts"))
        XCTAssertTrue(outcome.text.contains("ref main"))
        XCTAssertTrue(outcome.text.contains("export const x = 1"))
    }

    func testDefaultBranchIsFetchedOnceAndReused() async {
        MockURLProtocol.handler = { request in
            if request.url?.path == "/repos/o/r" {
                return (200, Data.json(#"{"default_branch":"develop"}"#))
            }
            return (200, Data.json(#"{"tree":[]}"#))
        }

        let executor = makeExecutor()
        _ = await executor.execute(
            ToolCall(id: "a", name: ToolCatalog.Name.listRepoFiles, input: .object([:]))
        )
        _ = await executor.execute(
            ToolCall(id: "b", name: ToolCatalog.Name.listRepoFiles, input: .object([:]))
        )

        let repoLookups = MockURLProtocol.recorded.filter { $0.url?.path == "/repos/o/r" }
        XCTAssertEqual(repoLookups.count, 1, "The default branch should be cached per session")
    }

    func testWriteToTheDefaultBranchIsRefused() async {
        MockURLProtocol.handler = { request in
            if request.url?.path == "/repos/o/r" {
                return (200, Data.json(#"{"default_branch":"develop"}"#))
            }
            return (200, Data.json("{}"))
        }

        let outcome = await makeExecutor().execute(
            ToolCall(id: "t4", name: ToolCatalog.Name.putFile, input: .object([
                "path": .string("a.ts"),
                "content": .string("x"),
                "message": .string("m"),
                "branch": .string("develop"),
            ]))
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("protected branch"))
    }

    func testListIssuesFormatsCompactly() async {
        MockURLProtocol.handler = { _ in
            (200, Data.json("""
            [{"number":7,"title":"Hold decline is broken","state":"open",
              "labels":[{"name":"bug"},{"name":"holds"}]}]
            """))
        }

        let outcome = await makeExecutor().execute(
            ToolCall(id: "t5", name: ToolCatalog.Name.listIssues, input: .object([:]))
        )
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.text, "#7 [open] Hold decline is broken — labels: bug, holds")
    }

    // MARK: - Catalog

    func testWriteToolsAreClassifiedCorrectly() {
        XCTAssertTrue(ToolCatalog.isWrite(ToolCatalog.Name.putFile))
        XCTAssertTrue(ToolCatalog.isWrite(ToolCatalog.Name.createPullRequest))
        XCTAssertTrue(ToolCatalog.isWrite(ToolCatalog.Name.createBranch))
        XCTAssertTrue(ToolCatalog.isWrite(ToolCatalog.Name.createIssue))
        XCTAssertFalse(ToolCatalog.isWrite(ToolCatalog.Name.readFile))
        XCTAssertFalse(ToolCatalog.isWrite(ToolCatalog.Name.searchCode))
    }

    func testReadOnlyModeExposesNoWriteTools() {
        let readOnly = ToolCatalog.tools(allowWrites: false)
        XCTAssertFalse(readOnly.contains { $0.isWrite })
        XCTAssertTrue(ToolCatalog.tools(allowWrites: true).contains { $0.isWrite })
    }

    func testEveryToolDeclaresAnObjectSchema() {
        for tool in ToolCatalog.tools(allowWrites: true) {
            XCTAssertEqual(
                tool.inputSchema["type"]?.stringValue,
                "object",
                "\(tool.name) must declare an object schema"
            )
            XCTAssertNotNil(tool.inputSchema["properties"], "\(tool.name) needs properties")
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) needs a description")
        }
    }

    func testToolNamesAreUnique() {
        let names = ToolCatalog.tools(allowWrites: true).map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    // MARK: - Spoken confirmations

    func testConfirmationPromptForCommitIsSpeakable() {
        let prompt = ToolCatalog.confirmationPrompt(for: ToolCall(
            id: "x",
            name: ToolCatalog.Name.putFile,
            input: .object([
                "path": .string("src/lib/holds.ts"),
                "branch": .string("fix/hold-decline"),
            ])
        ))
        XCTAssertTrue(prompt.contains("holds dot ts"))
        XCTAssertTrue(prompt.contains("fix slash hold decline"))
        XCTAssertTrue(prompt.hasSuffix("Confirm?"))
    }

    func testSpokenPathReadsDirectoriesSeparately() {
        XCTAssertEqual(ToolCatalog.spokenPath("a/b/c.swift"), "c dot swift, in a b")
        XCTAssertEqual(ToolCatalog.spokenPath("README.md"), "README dot md")
    }
}
