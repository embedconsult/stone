import Foundation

/// Fetches AgentStatus from the repo's remote. Logged in when a password is
/// saved (the endpoint may need read access to the thread), anonymous
/// otherwise. Every failure -- offline, 404 on a server without the
/// endpoint, a refused login -- is just "no status", never an error shown to
/// the maintainer.
enum AgentStatusClient {
    static func fetch(repo: Repo, thread: String) async -> AgentStatus? {
        guard let remote = repo.remoteURL else { return nil }
        let query = [URLQueryItem(name: "thread", value: thread)]
        let password = CredentialStore.password(for: repo.id)
        if password != nil, let session = RemoteSession(remoteURL: remote, password: password) {
            guard let data = try? await session.get("ext/ocx/status", query: query) else { return nil }
            return AgentStatus.decode(data)
        }
        guard var comps = URLComponents(string: remote) else { return nil }
        comps.user = nil
        comps.password = nil
        comps.path = (comps.path as NSString).appendingPathComponent("ext/ocx/status")
        comps.queryItems = query
        guard let url = comps.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return AgentStatus.decode(data)
    }
}
