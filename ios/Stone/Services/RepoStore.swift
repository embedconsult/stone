import Foundation

/// Outcome of syncing a single repository as part of a "Sync All" run.
enum RepoSyncStatus: Equatable {
    case syncing
    /// A nonzero exit code only means the round-trip completed -- it does
    /// NOT mean anything was pushed. Carrying the real counts (see
    /// RepoStore.parseArtifactCounts) is what lets the UI show that, rather
    /// than a bare checkmark implying "your write went out."
    case success(sent: Int, received: Int)
    /// Ground truth (ticket 94ea2161f5): a stale/rotated remote password
    /// can make `fossil sync` exit 0 with a plausible-looking "sent"
    /// count while the server silently refused the actual content push --
    /// see RepoStore.detectAuthFailure. This is deliberately its own case,
    /// not folded into .failure, so the UI can make it visually distinct
    /// from both "it worked" and "the command errored."
    case authFailed(String)
    case failure(String)
}

/// Owns the set of repositories: where their files live, their metadata, and
/// the high-level operations (create, clone, sync, delete).
///
/// It coordinates the other components but performs no Fossil work itself —
/// that is delegated to `FossilEngine`, with secrets via `CredentialStore`.
@MainActor
final class RepoStore: ObservableObject {
    /// One store for the app's whole lifetime, so the background-sync task
    /// handlers (BackgroundSyncScheduler, registered at launch before any
    /// SwiftUI view exists to hand them a `@StateObject` reference) and the
    /// foreground UI operate on the exact same in-memory repo list rather
    /// than two independently-loaded copies drifting apart. `StoneApp`'s
    /// `@StateObject` is seeded from this same instance.
    static let shared = RepoStore()

    @Published private(set) var repos: [Repo] = []
    @Published var lastSyncLog: String = ""

    /// Per-repo outcome of the most recent "Sync All" run, keyed by repo id.
    @Published private(set) var syncStatuses: [UUID: RepoSyncStatus] = [:]
    @Published private(set) var isSyncingAll = false
    @Published private(set) var syncAllSummary: String?

    /// Per-repo "Artifacts received" tally from the most recent `syncAll()`
    /// run -- every repo `sync(_:)` touches merges its count in here, and
    /// `syncAll()` resets this to `[:]` right before its loop so, once the
    /// loop finishes, it reflects exactly that run and nothing older. Read
    /// by `BackgroundSyncScheduler.scanAndNotify` (via `RepoListView`/
    /// `BackgroundSyncScheduler.runOnce`, both of which call `syncAll()`
    /// immediately before reading it) to skip the maintainer-request scan
    /// for repos that couldn't possibly have anything new this round
    /// (ticket d4d02c604f). A single-repo sync (`RepoWebView.runSync`) does
    /// NOT use this property -- it builds its own one-entry
    /// `[repo.id: received]` map instead, so an unrelated repo's tally from
    /// some earlier `syncAll()` can never leak into that decision.
    @Published private(set) var lastSyncReceivedCounts: [UUID: Int] = [:]

    /// Clears `lastSyncReceivedCounts` -- called at the start of `syncAll()`
    /// so a leftover count from an earlier run doesn't survive into this
    /// one for a repo that, say, gets skipped this time (no remote).
    private func resetReceivedTally() {
        lastSyncReceivedCounts = [:]
    }

    private let engine = FossilEngine.shared
    private let fileManager = FileManager.default

    init() {
        load()
    }

    // MARK: - Locations

    /// Directory holding every `.fossil` file plus the metadata index.
    private var repositoriesDir: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Repositories", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL {
        repositoriesDir.appendingPathComponent("index.json")
    }

    /// Absolute location of a repository's `.fossil` database file.
    func fileURL(for repo: Repo) -> URL {
        repositoriesDir.appendingPathComponent(repo.fileName)
    }

    // MARK: - Persistence of the metadata index

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Repo].self, from: data)
        else { return }
        repos = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(repos) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Operations

    /// Create a brand-new empty repository.
    func createRepo(named name: String) async throws {
        let fileName = Self.fileName(for: name)
        let path = repositoriesDir.appendingPathComponent(fileName).path
        let result = await engine.run(["init", path])
        guard result.succeeded else { throw StoreError.fossil(result.output) }
        var repo = Repo(name: name, fileName: fileName)
        repo.remoteURL = nil
        repos.append(repo)
        save()
    }

    /// Clone a remote repository into a new local `.fossil` file.
    func cloneRepo(named name: String, remoteURL: String, password: String?) async throws {
        let fileName = Self.fileName(for: name)
        let path = repositoriesDir.appendingPathComponent(fileName).path
        let id = UUID()
        let authURL = try Self.urlWithPassword(remoteURL, password: password)
        let result = await engine.run(["clone", authURL, path])
        guard result.succeeded else { throw StoreError.fossil(result.output) }
        await disableLocalauthSetting(at: path)
        await pullTicketConfig(authURL: authURL, path: path)
        await pullSkinConfig(authURL: authURL, path: path)
        if let password, !password.isEmpty {
            CredentialStore.setPassword(password, for: id)
        }
        // Both pulls just ran above, so record them now -- otherwise this
        // repo's very first real `sync()` would see `nil` timestamps and
        // immediately consider both "due", pulling a second time for no
        // reason seconds after the clone already fetched them fresh.
        let now = Date()
        repos.append(Repo(id: id, name: name, fileName: fileName, remoteURL: remoteURL,
                           lastTicketConfigPullAt: now, lastSkinPullAt: now))
        save()
    }

    /// Force this clone's own "localauth" repository setting to off.
    ///
    /// Verified against Fossil's real source (vendor/fossil-src-2.26): the
    /// embedded local server's `--localauth` flag only grants full Setup
    /// capability to loopback connections (src/login.c
    /// login_check_credentials()) when THIS repository's own "localauth"
    /// setting reads 0/off (src/db.c's documented condition 1 of 4).
    /// Fossil's own default is already off, but nothing else in Stone ever
    /// set it explicitly, so a clone that somehow inherited or was given a
    /// non-default value would silently defeat the whole --localauth
    /// mechanism for local writes (forum posts, wiki edits, etc.) -- this
    /// makes the value unconditional rather than assumed.
    ///
    /// NOTE (ticket 94ea2161f5): this was originally written chasing a
    /// moderation-queue theory for that ticket's "edit never synced"
    /// report. The actual root cause there turned out to be a stale/
    /// rotated remote password (see RepoStore.detectAuthFailure) --
    /// unrelated to --localauth or local capability entirely. This fix is
    /// kept anyway: it is still a real, independently-correct hardening
    /// measure for the local-server capability grant, just not what closed
    /// that specific ticket. Best-effort: a failure here doesn't block the
    /// clone, since browsing/most local writes don't depend on it.
    func disableLocalauthSetting(at path: String) async {
        _ = await engine.run(["settings", "localauth", "off", "-R", path])
    }

    /// Minimum time between proactive (not error-triggered) `configuration
    /// pull` refreshes of either ticket config or skin, per repo (ticket
    /// d4d02c604f). A wall-clock cap rather than comparing against the
    /// remote's actual config hash: learning the remote's current hash
    /// needs its own round trip to the server, which costs as much as just
    /// doing the pull -- there is no cheaper "is it stale" check available,
    /// so capping how often we bother asking is what actually saves time.
    static let configPullMinInterval: TimeInterval = 24 * 60 * 60

    /// Whether it has been long enough since `lastPullAt` (or it has never
    /// happened) to allow another proactive `configuration pull`.
    nonisolated static func isConfigPullDue(lastPullAt: Date?, now: Date = Date()) -> Bool {
        guard let lastPullAt else { return true }
        return now.timeIntervalSince(lastPullAt) >= configPullMinInterval
    }

    /// Whether `sync`'s raw output shows the specific failure ticket
    /// 11018cb484 was about: this clone's local TICKET table is missing a
    /// column the incoming ticket artifact's crosslinker just tried to
    /// write, because `configuration pull ticket` was never run against
    /// this clone (or the remote's schema changed since it last was).
    /// Fossil surfaces this as a plain SQLite "no such column: ..." error
    /// out of the crosslinking step (src/tkt.c).
    nonisolated static func indicatesMissingTicketColumn(_ output: String) -> Bool {
        output.lowercased().contains("no such column")
    }

    /// Formats a one-line summary of how long each phase of a sync took and
    /// appends it to Fossil's own output, so the maintainer can see where
    /// the wall-clock time actually goes (ticket d4d02c604f: sync got ~5x
    /// slower once a ticket-config pull, and the rebuild it triggers, ran
    /// before every sync). This is meant to stay in every build permanently,
    /// not be a one-off debug print.
    nonisolated static func appendPhaseTimings(
        to output: String,
        ticketConfigPullSeconds: TimeInterval?,
        syncSeconds: TimeInterval,
        skinPullSeconds: TimeInterval?
    ) -> String {
        func phase(_ name: String, _ seconds: TimeInterval?) -> String {
            guard let seconds else { return "\(name) skipped" }
            return "\(name) \(String(format: "%.2f", seconds))s"
        }
        let line = "[Stone timing] " + [
            phase("ticket-config pull", ticketConfigPullSeconds),
            phase("sync", syncSeconds),
            phase("skin pull", skinPullSeconds),
        ].joined(separator: " | ")
        return output.isEmpty ? line : output + "\n\n" + line
    }

    /// Appends the maintainer-request scan's own timing to `lastSyncLog`,
    /// right after whichever repo's sync-phase timings are already there, so
    /// the "View Log" sheet shows where a whole "Sync All" spent its time,
    /// not just the last repo's own sync/config-pull phases.
    func appendRequestScanTiming(ran: Bool, seconds: TimeInterval) {
        let line = ran
            ? "[Stone timing] request scan \(String(format: "%.2f", seconds))s"
            : "[Stone timing] request scan skipped (nothing received)"
        lastSyncLog = lastSyncLog.isEmpty ? line : lastSyncLog + "\n" + line
    }

    /// Pull + push against the repository's configured remote.
    ///
    /// Ticket config used to be pulled (with a full local TICKET table
    /// rebuild) before every single sync of every repo -- ticket 11018cb484
    /// fixed a real self-healing gap but made every sync pay for it, which
    /// is the bulk of the ~5x slowdown ticket d4d02c604f reports. Now the
    /// pull only happens when sync's own crosslinker proves it's actually
    /// needed (a missing column), or when a day has passed since the last
    /// refresh -- see `isConfigPullDue` and `indicatesMissingTicketColumn`.
    @discardableResult
    func sync(_ repo: Repo) async throws -> String {
        guard let remote = repo.remoteURL, !remote.isEmpty else {
            throw StoreError.noRemote
        }
        let password = CredentialStore.password(for: repo.id)
        let authURL = try Self.urlWithPassword(remote, password: password)
        let path = fileURL(for: repo).path

        var ticketConfigPullSeconds: TimeInterval?
        var skinPullSeconds: TimeInterval?

        var syncStartedAt = Date()
        var result = await engine.run(["sync", authURL, "-R", path])
        var syncSeconds = Date().timeIntervalSince(syncStartedAt)

        if !result.succeeded, Self.indicatesMissingTicketColumn(result.output) {
            // Self-heal (ticket 11018cb484's original case): sync itself
            // just proved this clone's schema is stale, so pull-and-rebuild
            // now and retry once, rather than leaving the repo broken until
            // some future once-a-day window opens.
            let pullStartedAt = Date()
            await pullTicketConfig(authURL: authURL, path: path)
            ticketConfigPullSeconds = Date().timeIntervalSince(pullStartedAt)
            recordTicketConfigPull(for: repo.id)

            syncStartedAt = Date()
            result = await engine.run(["sync", authURL, "-R", path])
            syncSeconds += Date().timeIntervalSince(syncStartedAt)
        } else if result.succeeded, Self.isConfigPullDue(lastPullAt: repo.lastTicketConfigPullAt) {
            // Not broken, but ticket config also carries report/edit setup
            // that can legitimately drift without ever producing a sync
            // error -- refresh it at most once a day so that isn't silently
            // stale forever either.
            let pullStartedAt = Date()
            await pullTicketConfig(authURL: authURL, path: path)
            ticketConfigPullSeconds = Date().timeIntervalSince(pullStartedAt)
            recordTicketConfigPull(for: repo.id)
        }

        guard result.succeeded else {
            lastSyncLog = Self.appendPhaseTimings(
                to: result.output,
                ticketConfigPullSeconds: ticketConfigPullSeconds,
                syncSeconds: syncSeconds,
                skinPullSeconds: nil
            )
            throw StoreError.fossil(lastSyncLog)
        }

        if Self.isConfigPullDue(lastPullAt: repo.lastSkinPullAt) {
            let pullStartedAt = Date()
            await pullSkinConfig(authURL: authURL, path: path)
            skinPullSeconds = Date().timeIntervalSince(pullStartedAt)
            recordSkinPull(for: repo.id)
        }

        let annotated = Self.appendPhaseTimings(
            to: result.output,
            ticketConfigPullSeconds: ticketConfigPullSeconds,
            syncSeconds: syncSeconds,
            skinPullSeconds: skinPullSeconds
        )
        lastSyncLog = annotated
        lastSyncReceivedCounts[repo.id] = Self.parseArtifactCounts(result.output)?.received ?? 0
        return annotated
    }

    private func recordTicketConfigPull(for id: UUID, at date: Date = Date()) {
        guard let idx = repos.firstIndex(where: { $0.id == id }) else { return }
        repos[idx].lastTicketConfigPullAt = date
        save()
    }

    private func recordSkinPull(for id: UUID, at date: Date = Date()) {
        guard let idx = repos.firstIndex(where: { $0.id == id }) else { return }
        repos[idx].lastSkinPullAt = date
        save()
    }

    /// Pulls the remote's ticket configuration (schema + report/edit
    /// setup) into this clone, overwriting whatever it has -- including
    /// rebuilding the local TICKET table, which `configuration pull`
    /// triggers automatically once it touches the ticket area
    /// (configure.c's configure_rebuild()/ticket_rebuild()). `--overwrite`
    /// is required: a plain pull is `INSERT OR IGNORE` and no-ops on
    /// every key this clone already has, i.e. all of them past the first
    /// clone. Best-effort, matching disableLocalauthSetting's precedent:
    /// a failure here doesn't block the clone/sync itself.
    private func pullTicketConfig(authURL: String, path: String) async {
        _ = await engine.run(["configuration", "pull", "ticket", authURL, "--overwrite", "-R", path])
    }

    /// Pulls the remote's skin configuration into this clone. Same
    /// `--overwrite` reasoning as pullTicketConfig(_:_:).
    private func pullSkinConfig(authURL: String, path: String) async {
        _ = await engine.run(["configuration", "pull", "skin", authURL, "--overwrite", "-R", path])
    }

    /// Detect the specific ground-truth failure mode behind ticket
    /// 94ea2161f5: a stale/rotated remote password. Confirmed against
    /// Fossil's real source (src/xfer.c): the server rejects a bad login
    /// with a plain "error login failed" card, which the client prints as
    /// "Error: login failed" -- but for a non-autosync `fossil sync` (what
    /// RepoStore.sync() runs) that IS a hard error, so it should already
    /// surface via the thrown .fossil(...) case. The more insidious path is
    /// src/xfer.c's server-sent "pull only ..." message: the client obeys
    /// it (silently disables pushing for the rest of the session) WITHOUT
    /// ever printing it, so a sync can still report a plausible-looking
    /// "Artifacts sent" count from an earlier round (e.g. a bookkeeping
    /// cluster) while the real content never goes out -- exactly "sent 1"
    /// with nothing actually delivered. Scanned against BOTH a successful
    /// sync's raw output and a thrown failure's message, so this catches
    /// the case whichever exit path Fossil actually takes.
    nonisolated static func detectAuthFailure(_ output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("login failed") {
            return "the server rejected the login -- the saved password for this remote is probably wrong or has been changed"
        }
        if lower.contains("not authorized") {
            return "the server said this login is not authorized to push"
        }
        if lower.range(of: "pull only", options: .caseInsensitive) != nil {
            return "the server put this sync in pull-only mode"
        }
        return nil
    }

    /// Parses Fossil's non-interactive sync summary line
    /// (`Round-trips: N   Artifacts sent: X  received: Y`, src/xfer.c
    /// `zBriefFormat`, printed exactly once when stdout isn't a tty) out of a
    /// `sync`/`clone` command's raw output. `nil` if the line isn't present
    /// (e.g. the command failed before any round-trip).
    ///
    /// This exists because a successful exit code alone does not mean
    /// anything was actually pushed: a remote identity lacking write
    /// capability makes Fossil silently decline to send content while still
    /// exiting 0. Surfacing the real sent/received counts, rather than a
    /// blanket "Sync complete," makes that silent no-op visible.
    nonisolated static func parseArtifactCounts(_ output: String) -> (sent: Int, received: Int)? {
        guard let regex = try? NSRegularExpression(
            pattern: "Artifacts sent:\\s*(\\d+)\\s+received:\\s*(\\d+)"
        ) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let sentRange = Range(match.range(at: 1), in: output),
              let receivedRange = Range(match.range(at: 2), in: output),
              let sent = Int(output[sentRange]),
              let received = Int(output[receivedRange])
        else { return nil }
        return (sent, received)
    }

    /// Sync every repository that has a remote configured, one at a time (the
    /// same `sync(_:)` used by the per-repo screen). Repos without a remote
    /// are skipped. Runs sequentially so we never hammer a remote with
    /// concurrent requests.
    ///
    /// `shouldContinue` is polled before each repo's sync starts (ticket
    /// 1a55c5d8b8: a BGTask's expiration handler needs a way to stop this
    /// loop early). It is deliberately never consulted *during* a repo's
    /// sync -- Swift `Task` cancellation cannot interrupt the synchronous C
    /// call inside `FossilEngine.run` once it has started, and `StoneFossil.c`
    /// only ever leaves its process-wide lock held for the duration of one
    /// in-flight `fossil_main()` call (see invoke_fossil's comment). So the
    /// one safe place to stop is between repos, after the current command has
    /// already returned and released the lock normally -- never mid-command.
    func syncAll(shouldContinue: () -> Bool = { true }) async {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        syncAllSummary = nil
        syncStatuses = [:]
        resetReceivedTally()
        defer { isSyncingAll = false }

        var succeeded = 0
        var authFailed = 0
        var failed = 0
        var skipped = 0
        var stopped = 0
        var totalSent = 0
        var totalReceived = 0

        for repo in repos {
            guard shouldContinue() else {
                stopped = repos.count - succeeded - authFailed - failed - skipped
                break
            }
            guard repo.remoteURL != nil else {
                skipped += 1
                continue
            }
            syncStatuses[repo.id] = .syncing
            do {
                let output = try await sync(repo)
                // Ground truth (ticket 94ea2161f5): check for a rejected
                // push before trusting the sent/received counts -- see
                // RepoStore.detectAuthFailure and RepoWebView.runSync's
                // matching check on the single-repo path.
                if let reason = Self.detectAuthFailure(output) {
                    syncStatuses[repo.id] = .authFailed(reason)
                    authFailed += 1
                } else {
                    let counts = Self.parseArtifactCounts(output) ?? (sent: 0, received: 0)
                    syncStatuses[repo.id] = .success(sent: counts.sent, received: counts.received)
                    totalSent += counts.sent
                    totalReceived += counts.received
                    succeeded += 1
                }
            } catch {
                if case .fossil(let msg)? = error as? StoreError,
                   let reason = Self.detectAuthFailure(msg) {
                    syncStatuses[repo.id] = .authFailed(reason)
                    authFailed += 1
                } else {
                    syncStatuses[repo.id] = .failure(error.localizedDescription)
                    failed += 1
                }
            }
        }

        // Report real totals, not just a repo count -- a "synced" repo that
        // pushed nothing (e.g. the remote identity lacks write capability,
        // see ticket c4eb202ff0) needs to be visibly distinguishable from one
        // that actually sent something.
        var parts = ["\(succeeded) synced (\(totalSent) sent, \(totalReceived) received)"]
        if authFailed > 0 { parts.append("\(authFailed) rejected by server") }
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped (no remote)") }
        if stopped > 0 { parts.append("\(stopped) not reached (background time expired)") }
        syncAllSummary = parts.joined(separator: ", ")
    }

    func dismissSyncAllSummary() {
        syncAllSummary = nil
    }

    /// Rename a repository. Only the display label changes; the `.fossil` file
    /// keeps its (UUID-suffixed) name, so nothing on disk needs to move.
    func rename(_ repo: Repo, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        repos[idx].name = trimmed
        save()
    }

    func updateRemote(_ repo: Repo, remoteURL: String?, password: String?) {
        guard let idx = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        repos[idx].remoteURL = (remoteURL?.isEmpty == true) ? nil : remoteURL
        if let password, !password.isEmpty {
            CredentialStore.setPassword(password, for: repo.id)
        }
        save()
    }

    func delete(_ repo: Repo) {
        try? fileManager.removeItem(at: fileURL(for: repo))
        CredentialStore.delete(for: repo.id)
        repos.removeAll { $0.id == repo.id }
        save()
    }

    // MARK: - Helpers

    enum StoreError: LocalizedError, Equatable {
        case fossil(String)
        case noRemote
        case passwordNeedsUsername

        var errorDescription: String? {
            switch self {
            case .fossil(let msg): return msg.isEmpty ? "Fossil command failed." : msg
            case .noRemote: return "This repository has no remote configured."
            case .passwordNeedsUsername:
                return "A password needs a username in the remote URL first — e.g. https://user@host/repo, not just https://host/repo."
            }
        }
    }

    private static func fileName(for name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? "repo" : safe
        return "\(base)-\(UUID().uuidString.prefix(8)).fossil"
    }

    /// Inject a password into a remote URL's userinfo so Fossil can authenticate
    /// non-interactively. Username, if any, must already be part of `remote`
    /// (e.g. `https://user@host/repo`) -- a password with no username would
    /// silently become an empty-username credential, which Fossil rejects, so
    /// that combination is refused up front instead.
    ///
    /// Internal rather than private so tests can exercise this pure
    /// validation logic directly, without going through the real Keychain
    /// (CredentialStore) or a network call -- see
    /// RepoStoreSyncCredentialTests, which used to inject the password via
    /// CredentialStore.setPassword() and hit `sync()`'s real network path.
    /// That depended on the Keychain write actually succeeding, which is not
    /// reliable for an unsigned test target (mac-acceptance-test.sh runs
    /// with CODE_SIGNING_ALLOWED=NO); a silently-failed SecItemAdd left
    /// password() returning nil, so this function never threw and the test
    /// fell through to a real, doomed network request instead.
    ///
    /// `nonisolated`, matching combinedRemoteURL/splitRemoteURL/
    /// parseArtifactCounts below: this is pure string/URL manipulation with
    /// no UI dependency, but RepoStore itself is @MainActor, and a `static
    /// func` on a @MainActor type is actor-isolated by default unless told
    /// otherwise -- without this, the compiler correctly rejects calling it
    /// from a synchronous, non-isolated context (exactly what
    /// RepoStoreSyncCredentialTests' non-async XCTAssertThrowsError call
    /// sites are).
    nonisolated static func urlWithPassword(_ remote: String, password: String?) throws -> String {
        guard let password, !password.isEmpty else { return remote }
        guard var comps = URLComponents(string: remote) else { return remote }
        guard let user = comps.user, !user.isEmpty else {
            throw StoreError.passwordNeedsUsername
        }
        comps.password = password
        return comps.string ?? remote
    }

    /// Combines a bare server URL and a username into one URL string with the
    /// username as userinfo (e.g. host `https://host/repo` + username `stone`
    /// -> `https://stone@host/repo`). An empty username leaves `host`
    /// unchanged (anonymous). Used by the add/edit-remote UI so the username
    /// is its own field rather than something the operator has to know to
    /// type into the URL by hand.
    nonisolated static func combinedRemoteURL(host: String, username: String) -> String {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, var comps = URLComponents(string: host) else { return host }
        comps.user = trimmedUser
        return comps.string ?? host
    }

    /// The inverse of `combinedRemoteURL`: splits a stored remote URL (which
    /// may carry a username as userinfo) into its bare host/path form and the
    /// username, for prefilling edit UI. Never returns a password -- that
    /// only ever lives in the Keychain via `CredentialStore`.
    nonisolated static func splitRemoteURL(_ remote: String) -> (host: String, username: String) {
        guard var comps = URLComponents(string: remote) else { return (remote, "") }
        let username = comps.user ?? ""
        comps.user = nil
        comps.password = nil
        return (comps.string ?? remote, username)
    }
}
