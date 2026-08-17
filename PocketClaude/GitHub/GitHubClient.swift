import Foundation

/// GitHub REST client — this is the piece that makes "no server" possible.
///
/// Claude's tools are Swift methods on this type; the phone executes the API
/// calls itself, so there is nothing to host. Read methods are unrestricted;
/// write methods refuse protected branches unconditionally (see `guardBranch`).
struct GitHubClient {
    static let defaultBaseURL = URL(string: "https://api.github.com")!

    /// Branches this client will never commit to, whatever it is asked.
    static let protectedBranches: Set<String> = ["main", "master", "trunk", "release", "production"]

    /// Tool results are fed straight back into the context window, so they must
    /// be bounded. These caps keep a runaway `read_file` from blowing the budget.
    static let maxFileCharacters = 60_000
    static let maxTreeEntries = 800

    var baseURL: URL
    var session: URLSession
    var tokenProvider: @Sendable () -> String?

    init(
        baseURL: URL = GitHubClient.defaultBaseURL,
        session: URLSession = GitHubClient.makeSession(),
        tokenProvider: @escaping @Sendable () -> String? = { KeychainStore.get(.githubToken) }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    // MARK: - Safety guard

    /// The one rule the agent cannot talk its way around: no writes to a
    /// protected branch, and no writes to the repository's default branch.
    static func guardBranch(_ branch: String, defaultBranch: String?) throws {
        let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if protectedBranches.contains(normalized) {
            throw GitHubError.protectedBranch(branch)
        }
        if let defaultBranch, normalized == defaultBranch.lowercased() {
            throw GitHubError.protectedBranch(branch)
        }
    }

    // MARK: - Transport

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: JSONValue? = nil
    ) throws -> URLRequest {
        guard let token = tokenProvider(), !token.isEmpty else { throw GitHubError.missingToken }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        // Setting `.path` (not `.percentEncodedPath`) makes URLComponents encode
        // spaces and other unsafe characters for us while leaving `/` intact.
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw GitHubError.decoding("Could not build URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PocketClaude", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    @discardableResult
    private func perform(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.decoding("Non-HTTP response")
        }

        if !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(JSONValue.self, from: data))?["message"]?
                .stringValue ?? String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 404 { throw GitHubError.notFound(request.url?.path ?? "resource") }
            throw GitHubError.http(status: http.statusCode, message: message)
        }

        if data.isEmpty { return .null }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw GitHubError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Read: repository metadata

    func repositoryInfo(_ repo: RepositoryRef) async throws -> RepositoryInfo {
        let value = try await perform(makeRequest(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)"
        ))
        guard let defaultBranch = value["default_branch"]?.stringValue else {
            throw GitHubError.decoding("Repository response had no default_branch")
        }
        return RepositoryInfo(
            defaultBranch: defaultBranch,
            description: value["description"]?.stringValue,
            isPrivate: value["private"]?.boolValue ?? false,
            language: value["language"]?.stringValue
        )
    }

    // MARK: - Read: file tree

    /// Recursive tree listing, optionally filtered by a path prefix.
    func listFiles(
        _ repo: RepositoryRef,
        ref: String,
        pathPrefix: String? = nil
    ) async throws -> [RepoFileEntry] {
        let value = try await perform(makeRequest(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/git/trees/\(ref)",
            query: [URLQueryItem(name: "recursive", value: "1")]
        ))

        guard let tree = value["tree"]?.arrayValue else {
            throw GitHubError.decoding("Tree response had no `tree` array")
        }

        var entries: [RepoFileEntry] = []
        for node in tree {
            guard let path = node["path"]?.stringValue,
                  let type = node["type"]?.stringValue
            else { continue }
            if let pathPrefix, !pathPrefix.isEmpty, !path.hasPrefix(pathPrefix) { continue }
            entries.append(RepoFileEntry(path: path, type: type, size: node["size"]?.intValue))
            if entries.count >= Self.maxTreeEntries { break }
        }
        return entries
    }

    // MARK: - Read: file contents

    func readFile(_ repo: RepositoryRef, path: String, ref: String?) async throws -> FileContents {
        var query: [URLQueryItem] = []
        if let ref, !ref.isEmpty { query.append(URLQueryItem(name: "ref", value: ref)) }

        let value = try await perform(makeRequest(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/contents/\(path)",
            query: query
        ))

        // A directory comes back as an array, not an object.
        if value.arrayValue != nil {
            throw GitHubError.decoding("'\(path)' is a directory, not a file. Use list_repo_files.")
        }
        guard let encoded = value["content"]?.stringValue,
              let sha = value["sha"]?.stringValue
        else {
            throw GitHubError.decoding("File response had no content (is it larger than 1 MB?)")
        }

        guard let text = Self.decodeBase64Content(encoded) else {
            throw GitHubError.decoding("'\(path)' is not UTF-8 text (binary file?)")
        }

        if text.count > Self.maxFileCharacters {
            return FileContents(
                path: path,
                text: String(text.prefix(Self.maxFileCharacters)),
                sha: sha,
                truncated: true
            )
        }
        return FileContents(path: path, text: text, sha: sha, truncated: false)
    }

    /// GitHub returns base64 with embedded newlines, which `Data(base64Encoded:)`
    /// rejects by default.
    static func decodeBase64Content(_ encoded: String) -> String? {
        let cleaned = encoded
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Read: code search

    func searchCode(_ repo: RepositoryRef, query: String, limit: Int = 20) async throws -> [CodeSearchHit] {
        let scoped = "\(query) repo:\(repo.owner)/\(repo.name)"
        var request = try makeRequest(
            method: "GET",
            path: "/search/code",
            query: [
                URLQueryItem(name: "q", value: scoped),
                URLQueryItem(name: "per_page", value: String(min(limit, 100))),
            ]
        )
        // The text-match media type gives us the matching fragment, which is the
        // whole point of searching from a phone.
        request.setValue("application/vnd.github.text-match+json", forHTTPHeaderField: "Accept")

        let value = try await perform(request)
        guard let items = value["items"]?.arrayValue else { return [] }

        return items.compactMap { item in
            guard let path = item["path"]?.stringValue else { return nil }
            let fragment = item["text_matches"]?.arrayValue?
                .compactMap { $0["fragment"]?.stringValue }
                .first
            return CodeSearchHit(path: path, snippet: fragment)
        }
    }

    // MARK: - Read: issues and pull requests

    func listIssues(_ repo: RepositoryRef, state: String, limit: Int) async throws -> [JSONValue] {
        let value = try await perform(makeRequest(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/issues",
            query: [
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "per_page", value: String(min(limit, 100))),
            ]
        ))
        // GitHub's issues endpoint also returns PRs; filter them out so
        // "open issues" means what the person meant.
        return (value.arrayValue ?? []).filter { $0["pull_request"] == nil }
    }

    func getIssue(_ repo: RepositoryRef, number: Int) async throws -> JSONValue {
        try await perform(makeRequest(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(number)"
        ))
    }

    func listPullRequests(_ repo: RepositoryRef, state: String, limit: Int) async throws -> [JSONValue] {
        let value = try await perform(makeRequest(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/pulls",
            query: [
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "per_page", value: String(min(limit, 100))),
            ]
        ))
        return value.arrayValue ?? []
    }

    func getPullRequest(_ repo: RepositoryRef, number: Int) async throws -> JSONValue {
        try await perform(makeRequest(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)"
        ))
    }

    func pullRequestFiles(_ repo: RepositoryRef, number: Int) async throws -> [JSONValue] {
        let value = try await perform(makeRequest(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/files",
            query: [URLQueryItem(name: "per_page", value: "100")]
        ))
        return value.arrayValue ?? []
    }

    // MARK: - Write

    func createIssue(_ repo: RepositoryRef, title: String, body: String?) async throws -> JSONValue {
        var payload: [String: JSONValue] = ["title": .string(title)]
        if let body, !body.isEmpty { payload["body"] = .string(body) }
        return try await perform(makeRequest(
            method: "POST",
            path: "/repos/\(repo.owner)/\(repo.name)/issues",
            body: .object(payload)
        ))
    }

    /// Resolves a branch name to its head commit SHA.
    func branchHeadSHA(_ repo: RepositoryRef, branch: String) async throws -> String {
        let value = try await perform(makeRequest(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/git/ref/heads/\(branch)"
        ))
        guard let sha = value["object"]?["sha"]?.stringValue else {
            throw GitHubError.decoding("Ref response had no object.sha")
        }
        return sha
    }

    /// Creates `branch` pointing at the head of `fromBranch`.
    func createBranch(
        _ repo: RepositoryRef,
        branch: String,
        fromBranch: String,
        defaultBranch: String?
    ) async throws -> String {
        // Creating a branch *from* main is fine; creating a branch *named* main
        // is not.
        try Self.guardBranch(branch, defaultBranch: defaultBranch)

        let baseSHA = try await branchHeadSHA(repo, branch: fromBranch)
        _ = try await perform(makeRequest(
            method: "POST",
            path: "/repos/\(repo.owner)/\(repo.name)/git/refs",
            body: .object([
                "ref": .string("refs/heads/\(branch)"),
                "sha": .string(baseSHA),
            ])
        ))
        return baseSHA
    }

    /// Creates or updates a file on a non-protected branch.
    func putFile(
        _ repo: RepositoryRef,
        path: String,
        content: String,
        message: String,
        branch: String,
        defaultBranch: String?
    ) async throws -> CommitResult {
        try Self.guardBranch(branch, defaultBranch: defaultBranch)

        // GitHub requires the current blob SHA when replacing an existing file.
        var existingSHA: String?
        do {
            existingSHA = try await readFile(repo, path: path, ref: branch).sha
        } catch let error as GitHubError {
            // A 404 here just means "new file", which is fine. Anything else is real.
            guard case .notFound = error else { throw error }
            existingSHA = nil
        }

        var payload: [String: JSONValue] = [
            "message": .string(message),
            "content": .string(Data(content.utf8).base64EncodedString()),
            "branch": .string(branch),
        ]
        if let existingSHA { payload["sha"] = .string(existingSHA) }

        let value = try await perform(makeRequest(
            method: "PUT",
            path: "/repos/\(repo.owner)/\(repo.name)/contents/\(path)",
            body: .object(payload)
        ))

        return CommitResult(
            path: path,
            branch: branch,
            commitSHA: value["commit"]?["sha"]?.stringValue ?? ""
        )
    }

    func createPullRequest(
        _ repo: RepositoryRef,
        title: String,
        head: String,
        base: String,
        body: String?
    ) async throws -> PullRequestResult {
        // `head` is the source branch — it must never be a protected branch,
        // because a PR from main into main is nonsense and usually a sign the
        // agent committed to the wrong place.
        try Self.guardBranch(head, defaultBranch: nil)

        var payload: [String: JSONValue] = [
            "title": .string(title),
            "head": .string(head),
            "base": .string(base),
        ]
        if let body, !body.isEmpty { payload["body"] = .string(body) }

        let value = try await perform(makeRequest(
            method: "POST",
            path: "/repos/\(repo.owner)/\(repo.name)/pulls",
            body: .object(payload)
        ))

        guard let number = value["number"]?.intValue else {
            throw GitHubError.decoding("Pull request response had no number")
        }
        return PullRequestResult(
            number: number,
            url: value["html_url"]?.stringValue ?? "",
            title: value["title"]?.stringValue ?? title
        )
    }
}
