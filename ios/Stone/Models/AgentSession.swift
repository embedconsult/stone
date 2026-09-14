import Foundation

/// One post in a forum thread bound to an Ollama-Codex runner session, as
/// returned by `GET <repo>/ext/agent?session_posts=<root>` -- the contract
/// settled by the maintainer 2026-06-18 (docs/design/agent-client-scoping.md
/// Gap 2.1).
struct AgentThreadPost: Codable, Identifiable, Equatable {
    var id: String { hash }
    let hash: String
    let user: String
    let mtime: String
    let role: String
    let html: String
}

struct AgentThreadPostsResponse: Codable {
    let ok: Bool
    let posts: [AgentThreadPost]
}

/// One runner session bound 1:1 to a forum thread, addressed by its root
/// post's hash -- the same identifier `session_posts` and `session_live_url`
/// key on.
///
/// Matches the settled `GET ext/agent/sessions.json` contract (Ollama-Codex
/// ticket `27e48399eb`, design doc contract C-E): the server emits
/// `root_hash`, `runner_login`, `state`, `last_post_author`, `last_post_at`
/// (plus other fields Stone doesn't need yet, like `pending_posts` and
/// `workspace`). There is no server-side `title` -- `title` below derives a
/// headline client-side instead of blocking on a server change.
struct AgentSessionSummary: Codable, Identifiable, Hashable {
    var id: String { root }
    /// The bound forum thread's root post hash.
    let root: String
    let runnerLogin: String?
    let state: String
    let lastPostAuthor: String?
    let lastActivity: String?

    enum CodingKeys: String, CodingKey {
        case root = "root_hash"
        case runnerLogin = "runner_login"
        case state
        case lastPostAuthor = "last_post_author"
        case lastActivity = "last_post_at"
    }

    /// Headline for the list/thread screens. No server-side title exists, so
    /// this heads with whoever owns the session and the root hash's first 12
    /// characters, falling back to whoever posted last if no runner has
    /// claimed the session yet.
    var title: String {
        if let runnerLogin, !runnerLogin.isEmpty {
            return "\(runnerLogin) · \(root.prefix(12))"
        }
        if let lastPostAuthor, !lastPostAuthor.isEmpty {
            return "\(lastPostAuthor) · \(root.prefix(12))"
        }
        return String(root.prefix(12))
    }
}

struct AgentSessionsResponse: Codable {
    let ok: Bool
    let sessions: [AgentSessionSummary]
}
