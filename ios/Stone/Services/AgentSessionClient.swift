import Foundation

/// Reads the `/ext/agent` JSON surface (docs/design/agent-client-scoping.md
/// Gap 2.1) through an already-authenticated `RemoteSession`. Kept separate
/// from `RemoteSession` itself so the endpoint shapes -- `session_posts`,
/// `session_live_url`, and the dedicated `sessions.json` PATH_INFO endpoint
/// (see `AgentSessionSummary`) -- live in one place that can change without
/// touching the generic HTTP/login/CSRF plumbing.
struct AgentSessionClient {
    enum ClientError: LocalizedError {
        case sessionsNotAvailable
        case badResponse

        var errorDescription: String? {
            switch self {
            case .sessionsNotAvailable:
                return "This server doesn't expose a session list yet."
            case .badResponse:
                return "The agent endpoint returned an unreadable response."
            }
        }
    }

    let session: RemoteSession

    /// Lists sessions bound to forum threads on this repo, via the settled
    /// `sessions.json` PATH_INFO endpoint (see `AgentSessionSummary`'s doc).
    /// `ext/agent?sessions=1` is a different, HTML-rendered developer page --
    /// not this JSON contract -- so it must not be used here. Decoding
    /// failure reports `.sessionsNotAvailable` rather than a raw decode
    /// error, since an older server may simply not support this yet.
    func fetchSessions() async throws -> [AgentSessionSummary] {
        let data = try await session.get("ext/agent/sessions.json")
        guard let decoded = try? JSONDecoder().decode(AgentSessionsResponse.self, from: data),
              decoded.ok else {
            throw ClientError.sessionsNotAvailable
        }
        return decoded.sessions
    }

    /// Fetches the posts of the thread bound to session `root`.
    func fetchPosts(root: String) async throws -> [AgentThreadPost] {
        let data = try await session.get("ext/agent", query: [URLQueryItem(name: "session_posts", value: root)])
        guard let decoded = try? JSONDecoder().decode(AgentThreadPostsResponse.self, from: data) else {
            throw ClientError.badResponse
        }
        return decoded.posts
    }

    /// Mints the signed `:8443` live-events URL for session `root`. The URL
    /// carries its own per-project HMAC token (per the design doc), so the
    /// SSE connection itself needs no separate auth.
    func liveEventsURL(root: String) async throws -> URL {
        let data = try await session.get("ext/agent", query: [URLQueryItem(name: "session_live_url", value: root)])
        struct Envelope: Codable {
            let ok: Bool
            let url: String
        }
        guard let decoded = try? JSONDecoder().decode(Envelope.self, from: data),
              decoded.ok, let url = URL(string: decoded.url) else {
            throw ClientError.badResponse
        }
        return url
    }
}
