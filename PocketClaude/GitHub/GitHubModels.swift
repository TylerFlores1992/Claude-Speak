import Foundation

/// `owner/repo` pair.
struct RepositoryRef: Equatable, Sendable {
    var owner: String
    var name: String

    var slug: String { "\(owner)/\(name)" }
}

struct RepositoryInfo: Equatable, Sendable {
    var defaultBranch: String
    var description: String?
    var isPrivate: Bool
    var language: String?
}

struct RepoFileEntry: Equatable, Sendable {
    var path: String
    var type: String // "blob" or "tree"
    var size: Int?
}

struct FileContents: Equatable, Sendable {
    var path: String
    var text: String
    var sha: String
    var truncated: Bool
}

struct CodeSearchHit: Equatable, Sendable {
    var path: String
    var snippet: String?
}

struct CommitResult: Equatable, Sendable {
    var path: String
    var branch: String
    var commitSHA: String
}

struct PullRequestResult: Equatable, Sendable {
    var number: Int
    var url: String
    var title: String
}

enum GitHubError: LocalizedError, Equatable {
    case missingToken
    case noRepositoryConfigured
    case http(status: Int, message: String)
    case notFound(String)
    case decoding(String)
    /// Raised by the safety guard, never by GitHub itself.
    case protectedBranch(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No GitHub token. Add a personal access token in Settings."
        case .noRepositoryConfigured:
            return "No repository configured. Set owner/repo in Settings."
        case .http(let status, let message):
            return "GitHub HTTP \(status): \(message)"
        case .notFound(let what):
            return "GitHub could not find \(what)."
        case .decoding(let detail):
            return "Unexpected GitHub response: \(detail)"
        case .protectedBranch(let branch):
            return "Refusing to write to protected branch '\(branch)'. Create a branch and open a pull request instead."
        }
    }
}
