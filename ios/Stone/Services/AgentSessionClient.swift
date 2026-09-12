import Foundation

/// Reads the `/ext/agent` JSON surface (docs/design/agent-client-scoping.md
/// Gap 2.1) through an already-authenticated `RemoteSession`. Kept separate
/// from `RemoteSession` itself so the endpoint shapes -- two settled
/// (`session_posts`, `session_live_url`), one still speculative (the
/// sessions list, see `AgentSessionSummary`) -- live in one place that can
/// change without touching the generic HTTP/login/CSRF plumbing.
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

    /// Lists sessions bound to forum threads on this repo. The endpoint
    /// shape here is speculative (see `AgentSessionSummary`'s doc) --
    /// decoding failure reports `.sessionsNotAvailable` rather than a raw
    /// decode error, since the server may simply not support this yet.
    func fetchSessions() async throws -> [AgentSessionSummary] {
        let data = try await session.get("ext/agent", query: [URLQueryItem(name: "sessions", value: "1")])
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
