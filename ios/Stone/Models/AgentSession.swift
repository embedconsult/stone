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
/// **Speculative shape.** Unlike `AgentThreadPost` above, this is not one of
/// the two contracts the maintainer had settled as of 2026-06-18; it is
/// Stone's best guess at the still-open session-status API (design doc
/// contract C-E, Ollama-Codex ticket `1e647f91f1`). `AgentSessionClient`
/// decodes it defensively and surfaces a distinct "not available yet" error
/// (see `AgentSessionClient.ClientError.sessionsNotAvailable`) rather than a
/// generic decode failure, so the list screen degrades cleanly against a
/// server that doesn't expose this yet and needs no client change once the
/// real shape is confirmed to match.
struct AgentSessionSummary: Codable, Identifiable, Hashable {
    var id: String { root }
    /// The bound forum thread's root post hash.
    let root: String
    let title: String
    let status: String
    let lastActivity: String?

    enum CodingKeys: String, CodingKey {
        case root, title, status
        case lastActivity = "last_activity"
    }
}

struct AgentSessionsResponse: Codable {
    let ok: Bool
    let sessions: [AgentSessionSummary]
}
