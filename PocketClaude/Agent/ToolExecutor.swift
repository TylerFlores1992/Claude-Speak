import Foundation

/// Runs a `tool_use` block against GitHub and formats the result as text for the
/// `tool_result` that goes back to Claude.
///
/// Swift note: `actor` gives us a serialized, thread-safe box for the cached
/// default branch without any locking — closest analogue in TS would be a class
/// whose methods are all awaited through a queue.
actor ToolExecutor {
    private let client: GitHubClient
    private let repo: RepositoryRef
    private var cachedDefaultBranch: String?

    init(client: GitHubClient, repo: RepositoryRef) {
        self.client = client
        self.repo = repo
    }

    /// Fetched once per session and reused — every tool needs it, and it never
    /// changes mid-conversation.
    func defaultBranch() async throws -> String {
        if let cachedDefaultBranch { return cachedDefaultBranch }
        let branch = try await client.repositoryInfo(repo).defaultBranch
        cachedDefaultBranch = branch
        return branch
    }

    /// Resolve an optional caller-supplied ref, falling back to the default branch.
    ///
    /// Written out rather than `explicit ?? (try await defaultBranch())` because
    /// `??` takes a non-async autoclosure — `await` is not allowed on its right
    /// hand side.
    private func resolveRef(_ explicit: String?) async throws -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        return try await defaultBranch()
    }

    /// Never throws: a failed tool is reported back to Claude as an error
    /// `tool_result` so it can adjust, rather than killing the turn.
    func execute(_ call: ToolCall) async -> ToolOutcome {
        do {
            let text = try await run(call)
            return ToolOutcome(toolUseID: call.id, text: text, isError: false)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ToolOutcome(toolUseID: call.id, text: "Error: \(message)", isError: true)
        }
    }

    // MARK: - Dispatch

    private func run(_ call: ToolCall) async throws -> String {
        switch call.name {
        case ToolCatalog.Name.getRepoInfo:
            return try await runGetRepoInfo()
        case ToolCatalog.Name.listRepoFiles:
            return try await runListFiles(call)
        case ToolCatalog.Name.readFile:
            return try await runReadFile(call)
        case ToolCatalog.Name.searchCode:
            return try await runSearchCode(call)
        case ToolCatalog.Name.listIssues:
            return try await runListIssues(call)
        case ToolCatalog.Name.getIssue:
            return try await runGetIssue(call)
        case ToolCatalog.Name.listPullRequests:
            return try await runListPullRequests(call)
        case ToolCatalog.Name.getPullRequest:
            return try await runGetPullRequest(call)
        case ToolCatalog.Name.createIssue:
            return try await runCreateIssue(call)
        case ToolCatalog.Name.createBranch:
            return try await runCreateBranch(call)
        case ToolCatalog.Name.putFile:
            return try await runPutFile(call)
        case ToolCatalog.Name.createPullRequest:
            return try await runCreatePullRequest(call)
        default:
            throw GitHubError.decoding("Unknown tool '\(call.name)'")
        }
    }

    // MARK: - Read handlers

    private func runGetRepoInfo() async throws -> String {
        let info = try await client.repositoryInfo(repo)
        cachedDefaultBranch = info.defaultBranch
        var lines = [
            "repository: \(repo.slug)",
            "default_branch: \(info.defaultBranch)",
            "private: \(info.isPrivate)",
        ]
        if let language = info.language { lines.append("primary_language: \(language)") }
        if let description = info.description { lines.append("description: \(description)") }
        return lines.joined(separator: "\n")
    }

    private func runListFiles(_ call: ToolCall) async throws -> String {
        let ref = try await resolveRef(call.input["ref"]?.stringValue)
        let prefix = call.input["path_prefix"]?.stringValue
        let entries = try await client.listFiles(repo, ref: ref, pathPrefix: prefix)

        let files = entries.filter { $0.type == "blob" }
        guard !files.isEmpty else {
            return "No files matched\(prefix.map { " prefix '\($0)'" } ?? "") on ref '\(ref)'."
        }

        var output = "\(files.count) file(s) on ref '\(ref)'"
        if let prefix, !prefix.isEmpty { output += " under '\(prefix)'" }
        output += ":\n"
        output += files.map { "  \($0.path)" }.joined(separator: "\n")
        if entries.count >= GitHubClient.maxTreeEntries {
            output += "\n\n(Listing truncated at \(GitHubClient.maxTreeEntries) entries — narrow it with path_prefix.)"
        }
        return output
    }

    private func runReadFile(_ call: ToolCall) async throws -> String {
        guard let path = call.input["path"]?.stringValue, !path.isEmpty else {
            throw GitHubError.decoding("read_file requires 'path'")
        }
        let ref = try await resolveRef(call.input["ref"]?.stringValue)
        let file = try await client.readFile(repo, path: path, ref: ref)

        var output = "\(file.path) (ref \(ref))"
        if file.truncated {
            output += " — TRUNCATED at \(GitHubClient.maxFileCharacters) characters"
        }
        output += "\n\n\(file.text)"
        return output
    }

    private func runSearchCode(_ call: ToolCall) async throws -> String {
        guard let query = call.input["query"]?.stringValue, !query.isEmpty else {
            throw GitHubError.decoding("search_code requires 'query'")
        }
        let limit = call.input["limit"]?.intValue ?? 20
        let hits = try await client.searchCode(repo, query: query, limit: limit)

        guard !hits.isEmpty else {
            return "No code matches for '\(query)'. Note GitHub code search indexes the default branch and can lag recent pushes — try list_repo_files plus read_file if you expect a match."
        }

        return hits.map { hit in
            var entry = "- \(hit.path)"
            if let snippet = hit.snippet {
                let compact = snippet
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                entry += "\n    \(compact.prefix(300))"
            }
            return entry
        }.joined(separator: "\n")
    }

    private func runListIssues(_ call: ToolCall) async throws -> String {
        let state = call.input["state"]?.stringValue ?? "open"
        let limit = call.input["limit"]?.intValue ?? 20
        let issues = try await client.listIssues(repo, state: state, limit: limit)
        guard !issues.isEmpty else { return "No \(state) issues." }
        return issues.map { Self.summarizeIssue($0) }.joined(separator: "\n")
    }

    private func runGetIssue(_ call: ToolCall) async throws -> String {
        guard let number = call.input["number"]?.intValue else {
            throw GitHubError.decoding("get_issue requires 'number'")
        }
        let issue = try await client.getIssue(repo, number: number)
        var output = Self.summarizeIssue(issue)
        if let body = issue["body"]?.stringValue, !body.isEmpty {
            output += "\n\n\(body)"
        }
        return output
    }

    private func runListPullRequests(_ call: ToolCall) async throws -> String {
        let state = call.input["state"]?.stringValue ?? "open"
        let limit = call.input["limit"]?.intValue ?? 20
        let pulls = try await client.listPullRequests(repo, state: state, limit: limit)
        guard !pulls.isEmpty else { return "No \(state) pull requests." }
        return pulls.map { Self.summarizePullRequest($0) }.joined(separator: "\n")
    }

    private func runGetPullRequest(_ call: ToolCall) async throws -> String {
        guard let number = call.input["number"]?.intValue else {
            throw GitHubError.decoding("get_pull_request requires 'number'")
        }
        let pull = try await client.getPullRequest(repo, number: number)
        var output = Self.summarizePullRequest(pull)
        if let body = pull["body"]?.stringValue, !body.isEmpty {
            output += "\n\n\(body)"
        }

        if call.input["include_files"]?.boolValue == true {
            let files = try await client.pullRequestFiles(repo, number: number)
            output += "\n\nChanged files (\(files.count)):"
            for file in files {
                let path = file["filename"]?.stringValue ?? "?"
                let additions = file["additions"]?.intValue ?? 0
                let deletions = file["deletions"]?.intValue ?? 0
                output += "\n- \(path) (+\(additions)/-\(deletions))"
                if let patch = file["patch"]?.stringValue {
                    output += "\n\(patch.prefix(4000))"
                }
            }
        }
        return output
    }

    // MARK: - Write handlers

    private func runCreateIssue(_ call: ToolCall) async throws -> String {
        guard let title = call.input["title"]?.stringValue, !title.isEmpty else {
            throw GitHubError.decoding("create_issue requires 'title'")
        }
        let issue = try await client.createIssue(
            repo,
            title: title,
            body: call.input["body"]?.stringValue
        )
        let number = issue["number"]?.intValue ?? 0
        let url = issue["html_url"]?.stringValue ?? ""
        return "Opened issue #\(number): \(title)\n\(url)"
    }

    private func runCreateBranch(_ call: ToolCall) async throws -> String {
        guard let branch = call.input["branch"]?.stringValue, !branch.isEmpty else {
            throw GitHubError.decoding("create_branch requires 'branch'")
        }
        let base = try await defaultBranch()
        let from = call.input["from_branch"]?.stringValue ?? base
        let sha = try await client.createBranch(
            repo,
            branch: branch,
            fromBranch: from,
            defaultBranch: base
        )
        return "Created branch '\(branch)' from '\(from)' at \(sha.prefix(7))."
    }

    private func runPutFile(_ call: ToolCall) async throws -> String {
        guard let path = call.input["path"]?.stringValue, !path.isEmpty,
              let content = call.input["content"]?.stringValue,
              let message = call.input["message"]?.stringValue, !message.isEmpty,
              let branch = call.input["branch"]?.stringValue, !branch.isEmpty
        else {
            throw GitHubError.decoding("put_file requires 'path', 'content', 'message', and 'branch'")
        }
        let base = try await defaultBranch()
        let result = try await client.putFile(
            repo,
            path: path,
            content: content,
            message: message,
            branch: branch,
            defaultBranch: base
        )
        return "Committed \(result.path) to '\(result.branch)' as \(result.commitSHA.prefix(7))."
    }

    private func runCreatePullRequest(_ call: ToolCall) async throws -> String {
        guard let title = call.input["title"]?.stringValue, !title.isEmpty,
              let head = call.input["head"]?.stringValue, !head.isEmpty
        else {
            throw GitHubError.decoding("create_pull_request requires 'title' and 'head'")
        }
        let base = try await resolveRef(call.input["base"]?.stringValue)
        let result = try await client.createPullRequest(
            repo,
            title: title,
            head: head,
            base: base,
            body: call.input["body"]?.stringValue
        )
        return "Opened pull request #\(result.number): \(result.title)\n\(result.url)"
    }

    // MARK: - Formatting helpers

    static func summarizeIssue(_ issue: JSONValue) -> String {
        let number = issue["number"]?.intValue ?? 0
        let title = issue["title"]?.stringValue ?? "(untitled)"
        let state = issue["state"]?.stringValue ?? "?"
        let labels = (issue["labels"]?.arrayValue ?? [])
            .compactMap { $0["name"]?.stringValue }
        var line = "#\(number) [\(state)] \(title)"
        if !labels.isEmpty { line += " — labels: \(labels.joined(separator: ", "))" }
        return line
    }

    static func summarizePullRequest(_ pull: JSONValue) -> String {
        let number = pull["number"]?.intValue ?? 0
        let title = pull["title"]?.stringValue ?? "(untitled)"
        let state = pull["state"]?.stringValue ?? "?"
        let head = pull["head"]?["ref"]?.stringValue ?? "?"
        let base = pull["base"]?["ref"]?.stringValue ?? "?"
        let draft = (pull["draft"]?.boolValue ?? false) ? " (draft)" : ""
        return "#\(number) [\(state)]\(draft) \(title) — \(head) → \(base)"
    }
}
