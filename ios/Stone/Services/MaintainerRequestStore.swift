import Foundation

/// Owns the "have we already told the maintainer about this?" bookkeeping
/// (ticket 1a55c5d8b8), the Requests screen's rows, and the badge count,
/// across both the foreground auto-sync loop and background sync tasks.
///
/// Runs the actual per-repo scan (`MaintainerRequestScanner`) after every
/// "Sync All", whichever triggered it, so background and foreground share
/// one code path and one seen-set -- there is no separate "background
/// notifications" feature, just one scan step that both callers invoke.
@MainActor
final class MaintainerRequestStore: ObservableObject {
    static let shared = MaintainerRequestStore()

    /// One row in the Requests screen (ticket 4c75227cc7): a request plus
    /// which repo it came from and when it was first seen. Recomputed from
    /// scratch on every scan -- never mutated in place -- so it can never
    /// drift from what the current scan actually found.
    struct Row: Identifiable, Equatable {
        let repo: Repo
        let request: MaintainerRequest
        let firstSeenAt: Date
        var id: String { "\(repo.id.uuidString)/\(request.ticketUUID)" }
    }

    /// Every currently-visible request, across every repo -- i.e. everything
    /// the scan just found, minus anything dismissed on this phone for its
    /// current `tkt_mtime`. This is exactly what the Requests screen shows.
    @Published private(set) var visibleRequests: [Row] = []

    /// The number of rows in `visibleRequests` -- the badge count. Ticket
    /// 4c75227cc7: "the badge number is the number of rows currently shown,
    /// never an accumulated count." Recomputed alongside `visibleRequests`
    /// on every scan and every dismiss/clear-all, never incremented.
    @Published private(set) var openRequestCount = 0

    /// One "new since last time we looked" batch, grouped per repo, so the
    /// caller can coalesce them into one notification per repo.
    struct ScanOutcome {
        let repo: Repo
        let newRequests: [MaintainerRequest]
    }

    private let defaults: UserDefaults
    private static let seenDefaultsKey = "maintainerRequestsSeenV1"
    private static let firstSeenDefaultsKey = "maintainerRequestsFirstSeenV1"
    private static let dismissedDefaultsKey = "maintainerRequestsDismissedV1"

    /// repo id (UUID string) -> ticket uuid -> last-seen tkt_mtime. Used only
    /// for the "is this new" notification diff -- unaffected by dismissal.
    private var seenByRepo: [String: [String: String]]

    private struct FirstSeen: Codable, Equatable {
        let mtime: String
        let seenAt: Date
    }
    /// repo id -> ticket uuid -> the mtime it was seen at, and when. Kept
    /// separate from `seenByRepo` (which drives notifications, not display)
    /// so a ticket's displayed "first seen" date survives even once a
    /// notification for it has already fired and stopped being "new".
    private var firstSeenByRepo: [String: [String: FirstSeen]]

    /// repo id -> ticket uuid -> the mtime it was dismissed at. A row is
    /// hidden exactly as long as its current mtime still matches this --
    /// ticket 4c75227cc7: "a swipe-to-dismiss hides a row on this phone
    /// until the ticket's mtime changes again."
    private var dismissedByRepo: [String: [String: String]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.seenByRepo = Self.load(from: defaults, key: Self.seenDefaultsKey)
        self.firstSeenByRepo = Self.load(from: defaults, key: Self.firstSeenDefaultsKey)
        self.dismissedByRepo = Self.load(from: defaults, key: Self.dismissedDefaultsKey)
    }

    /// Scan every repo and refresh the seen-set, `visibleRequests`, and
    /// `openRequestCount`. Call this after any "Sync All" run (foreground
    /// loop or a background task) -- never before a sync, since the local
    /// fallback reads whatever the repo's local clone currently has on disk.
    /// Always pass every repo in the store, never a subset: both
    /// `visibleRequests` and `openRequestCount` are replaced wholesale from
    /// what's passed in, so scanning only some repos would make the others'
    /// requests vanish until the next full scan.
    ///
    /// Ticket 98c06fb7a7: for each repo, `serverList` (the console
    /// dashboard's own Needs-you list -- `NeedsYouClient`, source of truth)
    /// is tried first; only when it returns `nil` (unreachable: no remote,
    /// network failure, or an older server without this endpoint) does this
    /// fall back to the local `.fossil` scan (`MaintainerRequestScanner`).
    /// Because each repo's `matches` wholesale-replaces whatever this store
    /// showed for it before, a repo whose server is reachable never keeps a
    /// local-scan-only match around (e.g. a merge card delegated away, or a
    /// ticket already cleared server-side but still sitting in a stale
    /// clone) -- it simply isn't in `matches` once the server list is used.
    func scanAfterSync(
        repos: [Repo],
        fossilPath: (Repo) -> String,
        serverList: (Repo) async -> [MaintainerRequest]? = Self.defaultServerList
    ) async -> [ScanOutcome] {
        var outcomes: [ScanOutcome] = []
        var updatedSeen = seenByRepo
        var updatedFirstSeen = firstSeenByRepo
        var updatedDismissed = dismissedByRepo
        var rows: [Row] = []

        for repo in repos {
            let matches: [MaintainerRequest]
            if let serverMatches = await serverList(repo) {
                matches = serverMatches
            } else {
                let path = fossilPath(repo)
                matches = await Task.detached(priority: .utility) {
                    MaintainerRequestScanner.scan(fossilPath: path)
                }.value
            }

            let repoKey = repo.id.uuidString

            let (newOnes, nextSeen) = Self.diff(current: matches, previouslySeen: updatedSeen[repoKey] ?? [:])
            updatedSeen[repoKey] = nextSeen
            if !newOnes.isEmpty {
                outcomes.append(ScanOutcome(repo: repo, newRequests: newOnes))
            }

            // Drop bookkeeping for tickets that no longer match at all
            // (resolved, or the repo's schema changed) -- otherwise both
            // dicts would grow forever, and a stale dismissed-mtime could
            // theoretically collide with a much-later, unrelated ticket
            // reusing... well, uuids don't get reused, but there's no
            // reason to keep it around once the ticket itself is gone.
            let currentUUIDs = Set(matches.map(\.ticketUUID))
            var firstSeenForRepo = (updatedFirstSeen[repoKey] ?? [:]).filter { currentUUIDs.contains($0.key) }
            var dismissedForRepo = (updatedDismissed[repoKey] ?? [:]).filter { currentUUIDs.contains($0.key) }

            for request in matches {
                let seenAt: Date
                if let existing = firstSeenForRepo[request.ticketUUID], existing.mtime == request.mtime {
                    seenAt = existing.seenAt
                } else {
                    seenAt = Date()
                }
                firstSeenForRepo[request.ticketUUID] = FirstSeen(mtime: request.mtime, seenAt: seenAt)

                let isDismissed = dismissedForRepo[request.ticketUUID] == request.mtime
                if !isDismissed {
                    rows.append(Row(repo: repo, request: request, firstSeenAt: seenAt))
                }
            }

            updatedFirstSeen[repoKey] = firstSeenForRepo
            updatedDismissed[repoKey] = dismissedForRepo
        }

        seenByRepo = updatedSeen
        firstSeenByRepo = updatedFirstSeen
        dismissedByRepo = updatedDismissed
        persist(seenByRepo, key: Self.seenDefaultsKey)
        persist(firstSeenByRepo, key: Self.firstSeenDefaultsKey)
        persist(dismissedByRepo, key: Self.dismissedDefaultsKey)

        visibleRequests = rows
        openRequestCount = rows.count
        return outcomes
    }

    /// Real network implementation of `scanAfterSync`'s `serverList`
    /// parameter: fetches the console's Needs-you cards for `repo` over its
    /// configured remote (`NeedsYouClient`). Returns `nil` -- "unreachable,
    /// fall back to the local scan" -- for a repo with no remote, a failed
    /// login, a network error, or a server that doesn't serve this endpoint;
    /// never for "the server said there's nothing to show," which is a
    /// legitimate empty array. `nonisolated` (not actor-isolated despite
    /// living on this `@MainActor` type, matching `RepoStore`'s pure static
    /// helpers) so it can serve as a plain default-parameter value.
    nonisolated static func defaultServerList(for repo: Repo) async -> [MaintainerRequest]? {
        guard let remoteURL = repo.remoteURL, !remoteURL.isEmpty,
              let session = RemoteSession(remoteURL: remoteURL, password: CredentialStore.password(for: repo.id))
        else { return nil }
        return try? await NeedsYouClient(session: session).fetchCards()
    }

    /// Swipe-to-dismiss on the Requests screen: hides this one row on this
    /// phone until its ticket's mtime changes. Takes effect immediately --
    /// does not wait for the next sync.
    func dismiss(_ row: Row) {
        let repoKey = row.repo.id.uuidString
        var forRepo = dismissedByRepo[repoKey] ?? [:]
        forRepo[row.request.ticketUUID] = row.request.mtime
        dismissedByRepo[repoKey] = forRepo
        persist(dismissedByRepo, key: Self.dismissedDefaultsKey)

        visibleRequests.removeAll { $0.id == row.id }
        openRequestCount = visibleRequests.count
    }

    /// "Clear all" on the Requests screen: dismisses every row currently
    /// shown, same as swiping each one individually.
    func clearAll() {
        for row in visibleRequests {
            let repoKey = row.repo.id.uuidString
            var forRepo = dismissedByRepo[repoKey] ?? [:]
            forRepo[row.request.ticketUUID] = row.request.mtime
            dismissedByRepo[repoKey] = forRepo
        }
        persist(dismissedByRepo, key: Self.dismissedDefaultsKey)

        visibleRequests = []
        openRequestCount = 0
    }

    /// Pure diffing logic, split out from `scanAfterSync` so it's directly
    /// unit-testable without a real `.fossil` file, sqlite, or `UserDefaults`
    /// (StoneTests: seen-set coverage). A ticket counts as "new" if its uuid
    /// wasn't seen before, or its `tkt_mtime` changed since it was --
    /// covering both "brand new request" and "same ticket, edited again
    /// (e.g. resolved then reopened, or a merge card updated)". Tickets that
    /// no longer match are dropped from the returned seen-set, so if one
    /// reappears later (same uuid) it notifies again rather than being
    /// remembered as seen forever.
    nonisolated static func diff(
        current: [MaintainerRequest],
        previouslySeen: [String: String]
    ) -> (new: [MaintainerRequest], updatedSeen: [String: String]) {
        var newOnes: [MaintainerRequest] = []
        var updated: [String: String] = [:]
        for request in current {
            if previouslySeen[request.ticketUUID] != request.mtime {
                newOnes.append(request)
            }
            updated[request.ticketUUID] = request.mtime
        }
        return (newOnes, updated)
    }

    private static func load<T: Decodable>(from defaults: UserDefaults, key: String) -> T where T: ExpressibleByDictionaryLiteral {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(T.self, from: data)
        else { return [:] }
        return decoded
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
