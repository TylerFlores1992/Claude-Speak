import Foundation

/// The tools Claude can call. Each one is a Swift method on `GitHubClient`
/// executed by the phone — this is the whole trick that makes Phase 1 serverless.
enum ToolCatalog {
    // MARK: - Names (single source of truth; used by the executor's switch)

    enum Name {
        static let getRepoInfo = "get_repo_info"
        static let listRepoFiles = "list_repo_files"
        static let readFile = "read_file"
        static let searchCode = "search_code"
        static let listIssues = "list_issues"
        static let getIssue = "get_issue"
        static let listPullRequests = "list_pull_requests"
        static let getPullRequest = "get_pull_request"

        static let createIssue = "create_issue"
        static let createBranch = "create_branch"
        static let putFile = "put_file"
        static let createPullRequest = "create_pull_request"
    }

    static let writeToolNames: Set<String> = [
        Name.createIssue, Name.createBranch, Name.putFile, Name.createPullRequest,
    ]

    static func isWrite(_ name: String) -> Bool { writeToolNames.contains(name) }

    // MARK: - Definitions

    static let readTools: [ToolDefinition] = [
        ToolDefinition(
            name: Name.getRepoInfo,
            description: "Get metadata about the configured repository, including its default branch, description, and primary language. Call this first when you need to know which branch to read from or base a new branch on.",
            inputSchema: .from([
                "type": "object",
                "properties": [String: Any](),
                "required": [String](),
            ]),
            isWrite: false
        ),
        ToolDefinition(
            name: Name.listRepoFiles,
            description: "List file paths in the repository, recursively. Use path_prefix to scope to a directory (e.g. 'src/lib/holds') — an unscoped listing on a large repo returns a lot of noise. Returns paths only, not contents.",
            inputSchema: .from([
                "type": "object",
                "properties": [
                    "path_prefix": [
                        "type": "string",
                        "description": "Only return paths starting with this prefix. Omit for the whole repository.",
                    ],
                    "ref": [
                        "type": "string",
                        "description": "Branch, tag, or commit SHA. Defaults to the repository's default branch.",
                    ],
                ],
                "required": [String](),
            ]),
            isWrite: false
        ),
        ToolDefinition(
            name: Name.readFile,
            description: "Read the full text of one file. Use this before answering any question about what code does — never describe code you have not read. Large files are truncated and the result says so.",
            inputSchema: .from([
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Repository-relative path, e.g. 'src/lib/holds/lifecycle.ts'.",
                    ],
                    "ref": [
                        "type": "string",
                        "description": "Branch, tag, or commit SHA. Defaults to the default branch.",
                    ],
                ],
                "required": ["path"],
            ]),
            isWrite: false
        ),
        ToolDefinition(
            name: Name.searchCode,
            description: "Search the repository's code with GitHub code search. Best for locating a symbol or string when you do not know the file, e.g. 'RC_HOLD_CAPACITY' or 'TODO hold lifecycle'. Returns matching paths with a snippet. Note GitHub code search indexes the default branch only and may lag recent pushes.",
            inputSchema: .from([
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Search terms. GitHub qualifiers such as path: and language: work here; the repo: qualifier is added automatically.",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum hits to return (default 20, max 100).",
                    ],
                ],
                "required": ["query"],
            ]),
            isWrite: false
        ),
        ToolDefinition(
            name: Name.listIssues,
            description: "List issues in the repository. Pull requests are filtered out.",
            inputSchema: .from([
                "type": "object",
                "properties": [
                    "state": [
                        "type": "string",
                        "enum": ["open", "closed", "all"],
                        "description": "Defaults to open.",
                    ],
                    "limit": ["type": "integer", "description": "Default 20, max 100."],
                ],
                "required": [String](),
            ]),
            isWrite: false
        ),
        ToolDefinition(
            name: Name.getIssue,
            description: "Read one issue in full, including its body.",
            inputSchema: .from([
                "type": "object",
                "properties": ["number": ["type": "integer", "description": "Issue number."]],
                "required": ["number"],
            ]),
            isWrite: false
        ),
        ToolDefinition(
            name: Name.listPullRequests,
            description: "List pull requests in the repository.",
            inputSchema: .from([
                "type": "object",
                "properties": [
                    "state": [
                        "type": "string",
                        "enum": ["open", "closed", "all"],
                        "description": "Defaults to open.",
                    ],
                    "limit": ["type": "integer", "description": "Default 20, max 100."],
                ],
                "required": [String](),
            ]),
            isWrite: false
        ),
        ToolDefinition(
            name: Name.getPullRequest,
            description: "Read one pull request, optionally with the list of changed files and their patches.",
            inputSchema: .from([
                "type": "object",
                "properties": [
                    "number": ["type": "integer", "description": "Pull request number."],
                    "include_files": [
                        "type": "boolean",
                        "description": "Include changed files and diffs. Defaults to false — diffs are large.",
                    ],
                ],
                "required": ["number"],
            ]),
            isWrite: false
        ),
    ]

    static let writeTools: [ToolDefinition] = [
        ToolDefinition(
            name: Name.createIssue,
            description: "Open a new issue. The person will be asked to confirm out loud before this runs.",
            inputSchema: .from([
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Issue title."],
                    "body": ["type": "string", "description": "Issue body in markdown."],
                ],
                "required": ["title"],
            ]),
            isWrite: true
        ),
        ToolDefinition(
            name: Name.createBranch,
            description: "Create a new branch. Always the first step of any code change — direct commits to the default branch are rejected. The person will be asked to confirm before this runs.",
            inputSchema: .from([
                "type": "object",
                "properties": [
                    "branch": [
                        "type": "string",
                        "description": "New branch name, e.g. 'fix/hold-decline-path'. Must not be main, master, or the default branch.",
                    ],
                    "from_branch": [
                        "type": "string",
                        "description": "Branch to base it on. Defaults to the repository's default branch.",
                    ],
                ],
                "required": ["branch"],
            ]),
            isWrite: true
        ),
        ToolDefinition(
            name: Name.putFile,
            description: "Create or replace a file on a branch, as one commit. You must pass the file's COMPLETE new contents — this is a whole-file write, not a patch, so read the file first if you are editing it. Writes to the default branch are rejected. The person will be asked to confirm before this runs.",
            inputSchema: .from([
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Repository-relative file path."],
                    "content": ["type": "string", "description": "The complete new file contents."],
                    "message": ["type": "string", "description": "Commit message."],
                    "branch": ["type": "string", "description": "Branch to commit to. Never the default branch."],
                ],
                "required": ["path", "content", "message", "branch"],
            ]),
            isWrite: true
        ),
        ToolDefinition(
            name: Name.createPullRequest,
            description: "Open a pull request from your branch into the default branch. The final step of a change. The person will be asked to confirm before this runs.",
            inputSchema: .from([
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Pull request title."],
                    "head": ["type": "string", "description": "Source branch (the one you committed to)."],
                    "base": [
                        "type": "string",
                        "description": "Target branch. Defaults to the repository's default branch.",
                    ],
                    "body": ["type": "string", "description": "Pull request description in markdown."],
                ],
                "required": ["title", "head"],
            ]),
            isWrite: true
        ),
    ]

    static func tools(allowWrites: Bool) -> [ToolDefinition] {
        allowWrites ? readTools + writeTools : readTools
    }

    // MARK: - Spoken confirmation

    /// One short sentence describing what a write will do, read aloud before the
    /// person confirms. Deliberately avoids paths-as-punctuation.
    static func confirmationPrompt(for call: ToolCall) -> String {
        switch call.name {
        case Name.createIssue:
            let title = call.input["title"]?.stringValue ?? "an issue"
            return "Open a new issue titled \(title). Confirm?"
        case Name.createBranch:
            let branch = call.input["branch"]?.stringValue ?? "a new branch"
            return "Create the branch \(spokenBranch(branch)). Confirm?"
        case Name.putFile:
            let path = call.input["path"]?.stringValue ?? "a file"
            let branch = call.input["branch"]?.stringValue ?? "a branch"
            return "Commit \(spokenPath(path)) to \(spokenBranch(branch)). Confirm?"
        case Name.createPullRequest:
            let title = call.input["title"]?.stringValue ?? "a pull request"
            return "Open a pull request titled \(title). Confirm?"
        default:
            return "Run \(call.name.replacingOccurrences(of: "_", with: " ")). Confirm?"
        }
    }

    /// "src/lib/holds.ts" reads terribly. "holds dot t s, in src lib" reads fine.
    static func spokenPath(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard let file = components.last else { return path }
        let directories = components.dropLast()
        let spokenFile = file.replacingOccurrences(of: ".", with: " dot ")
        if directories.isEmpty { return spokenFile }
        return "\(spokenFile), in \(directories.joined(separator: " "))"
    }

    static func spokenBranch(_ branch: String) -> String {
        branch
            .replacingOccurrences(of: "/", with: " slash ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}
