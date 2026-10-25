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

    /// At most one wake sync per repo this often. Events that arrive in
    /// between are taken by the next one, so a repo where agents commit
    /// and post every few seconds syncs twice a minute, not continuously.
    static let minimumGap: TimeInterval = 30

    /// A first answer slower than this waited for a new event; a quicker
    /// one is the newest row the server already had.
    static let waited: TimeInterval = 2

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
        // table has one: a starting point without the whole history. That
        // answer is old news and wakes nothing; only when the table was
        // empty does it wait, and then its row is new.
        var last = -1
        var errorAnswers = 0
        var failures = 0
        var lastWake = Date.distantPast
        while !Task.isCancelled {
            do {
                let asked = Date()
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
                let first = last < 0
                if let id = answer.lastID { last = id }
                guard answer.rows > 0, !first || Date().timeIntervalSince(asked) >= waited else { continue }
                let sinceLast = Date().timeIntervalSince(lastWake)
                if sinceLast < minimumGap {
                    try? await Task.sleep(for: .seconds(minimumGap - sinceLast))
                    if Task.isCancelled { return }
                }
                lastWake = Date()
                await onWake()
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

/// The foreground's automatic syncs: Automatic Sync's timer, and a wake per
/// repo (RemoteWake). StoneApp starts them when the app becomes active and
/// stops them when it goes to the background, whatever screen is showing.
/// (They used to run in the home list's `.task`, which SwiftUI cancels when
/// a repo or conversation is pushed on top. Coming back restarted the
/// timer's wait, so the timer seldom fired, and every wake started over.)
/// Background syncs are BackgroundSyncScheduler's; `isSyncingAll` keeps the
/// two from running a Sync All at once.
@MainActor
final class ForegroundSync {
    static let shared = ForegroundSync()

    private var timer: Task<Void, Never>?
    private var wakes: Task<Void, Never>?

    func start(store: RepoStore) {
        guard timer == nil else { return }
        timer = Task { await Self.runTimer(store: store) }
        wakes = Task { await Self.runWakes(store: store) }
    }

    func stop() {
        timer?.cancel()
        wakes?.cancel()
        timer = nil
        wakes = nil
    }

    /// Whether Automatic Sync is on, and not held back by Low Power Mode.
    /// Read from UserDefaults each time, so a change in Settings counts at
    /// once.
    private static var allowed: Bool {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: SettingsView.autoSyncEnabledKey) as? Bool ?? false
        let skipsLowPower = defaults.object(forKey: SettingsView.autoSyncSkipsLowPowerKey) as? Bool ?? true
        return enabled && !(skipsLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// A Sync All every Automatic Sync interval, per the maintainer's
    /// request for a programmable interval with a Low Power Mode opt-out.
    private static func runTimer(store: RepoStore) async {
        while !Task.isCancelled {
            let minutes = UserDefaults.standard.object(forKey: SettingsView.autoSyncIntervalKey) as? Int
                ?? SettingsView.defaultAutoSyncIntervalMinutes
            try? await Task.sleep(for: .seconds(max(minutes, 1) * 60))
            guard !Task.isCancelled, allowed else { continue }
            guard !store.isSyncingAll, store.repos.contains(where: { $0.remoteURL != nil }) else { continue }
            await store.syncAll(trigger: .timer)
            // Same post-sync scan/notify step a background task runs.
            await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: store.lastSyncReceivedCounts)
        }
    }

    /// One RemoteWake per repo with a remote while Automatic Sync is
    /// allowed. The set of repos and the settings are read again every
    /// minute.
    private static func runWakes(store: RepoStore) async {
        var following: [UUID: Task<Void, Never>] = [:]
        defer { following.values.forEach { $0.cancel() } }
        while !Task.isCancelled {
            let wanted = allowed ? store.repos.filter { $0.remoteURL != nil } : []
            let wantedIDs = Set(wanted.map(\.id))
            for (id, task) in following where !wantedIDs.contains(id) {
                task.cancel()
                following[id] = nil
            }
            for repo in wanted where following[repo.id] == nil {
                let id = repo.id
                following[id] = Task { await RemoteWake.follow(repo) { await wakeSync(id, store: store) } }
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// One repo's sync after its server woke us: skipped while a Sync All
    /// runs, which covers it.
    private static func wakeSync(_ id: UUID, store: RepoStore) async {
        guard !store.isSyncingAll, let repo = store.repos.first(where: { $0.id == id }) else { return }
        guard let output = try? await store.sync(repo, trigger: .wake) else { return }
        let received = RepoStore.parseArtifactCounts(output)?.received ?? 0
        await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: [repo.id: received])
    }
}
