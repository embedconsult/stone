import Foundation

/// One answer from Fossil's `/chat-poll`, the long-poll that OCX's layers
/// design uses to wake listeners (ollama wiki "Layers design", section 4).
/// With the repository's `chat-timeline-user` setting on, every timeline
/// event (check-in, forum post, ticket change, tag, wiki edit, local or
/// arriving by sync) adds a chat row, and a request waiting on
/// `/chat-poll?name=N` is answered with every row newer than N. Checked
/// against Fossil 2.27 on Linux, 2026-10-25: see docs/chat-poll-wake.md.
struct ChatPollAnswer: Equatable {
    /// The largest `msgid` in the answer; nil when it held no rows (the
    /// server's chat-poll-timeout passed with nothing new).
    let lastID: Int?
    let rows: Int
    /// Fossil answers 200 with one row marked `isError` when the login lacks
    /// the chat capability (C) or its cookie has expired.
    let isError: Bool

    static func parse(_ data: Data) -> ChatPollAnswer? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgs = object["msgs"] as? [[String: Any]] else { return nil }
        if msgs.contains(where: { ($0["isError"] as? Bool) == true }) {
            return ChatPollAnswer(lastID: nil, rows: 0, isError: true)
        }
        let ids = msgs.compactMap { $0["msgid"] as? Int }
        return ChatPollAnswer(lastID: ids.max(), rows: msgs.count, isError: false)
    }
}

/// Keeps one `/chat-poll` request waiting per repository and calls `onWake`
/// when the server records something new, so the foreground sync happens
/// within seconds instead of at the next Automatic Sync interval. It only
/// wakes: the sync itself is the usual RepoStore.sync, and the interval loop
/// stays as the fallback for a server or login where this can't work.
enum RemoteWake {
    /// Longer than any chat-poll-timeout a server is likely to set (Fossil's
    /// default is 420 s; OCX's design suggests 60 s), so the server, not
    /// URLSession, ends a quiet wait.
    static let requestTimeout: TimeInterval = 480

    /// Follows `repo` until the task is cancelled. Returns early, leaving
    /// the repo to the interval loop, when it has no remote or saved
    /// password, or when the server keeps answering with an error (no chat
    /// capability, or chat-timeline-user not set so nothing ever arrives
    /// but chat itself).
    static func follow(_ repo: Repo, onWake: @escaping @Sendable () async -> Void) async {
        guard let remote = repo.remoteURL,
              let password = CredentialStore.password(for: repo.id),
              let session = RemoteSession(remoteURL: remote, password: password) else { return }

        // -1 asks for the newest row alone, answered at once when the chat
        // table has one: a starting point without the whole history. Its
        // answer wakes one sync, which is harmless.
        var last = -1
        var errorAnswers = 0
        var failures = 0
        while !Task.isCancelled {
            do {
                let data = try await session.longPoll(
                    "chat-poll",
                    query: [URLQueryItem(name: "name", value: String(last))],
                    referer: "chat",
                    timeout: requestTimeout)
                guard let answer = ChatPollAnswer.parse(data) else { throw RemoteSession.RemoteError.badResponse }
                failures = 0
                if answer.isError {
                    // Once for an expired cookie; twice means the login
                    // lacks C, which no retry will change.
                    errorAnswers += 1
                    if errorAnswers >= 2 { return }
                    await session.forgetLogin()
                    continue
                }
                errorAnswers = 0
                if let id = answer.lastID { last = id }
                if answer.rows > 0 { await onWake() }
            } catch {
                if Task.isCancelled { return }
                // Offline, a dropped connection, a server restart: back off
                // up to five minutes, then wait again from the same row, so
                // nothing recorded meanwhile is missed.
                failures += 1
                try? await Task.sleep(for: .seconds(min(15 * failures, 300)))
            }
        }
    }
}
