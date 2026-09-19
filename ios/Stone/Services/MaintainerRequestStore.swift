import Foundation

/// Owns the "have we already told the maintainer about this?" bookkeeping
/// (ticket 1a55c5d8b8) and the badge count, across both the foreground
/// auto-sync loop and background sync tasks.
///
/// Runs the actual per-repo scan (`MaintainerRequestScanner`) after every
/// "Sync All", whichever triggered it, so background and foreground share
/// one code path and one seen-set -- there is no separate "background
/// notifications" feature, just one scan step that both callers invoke.
@MainActor
final class MaintainerRequestStore: ObservableObject {
    static let shared = MaintainerRequestStore()

    /// Total count of tickets currently matching either request kind, across
    /// every repo -- independent of whether they're "new". This is exactly
    /// what the ticket calls "the badge count."
    @Published private(set) var openRequestCount = 0

    /// One "new since last time we looked" batch, grouped per repo, so the
    /// caller can coalesce them into one notification per repo.
    struct ScanOutcome {
        let repo: Repo
        let newRequests: [MaintainerRequest]
    }

    private let defaults: UserDefaults
    private static let seenDefaultsKey = "maintainerRequestsSeenV1"

    /// repo id (UUID string) -> ticket uuid -> last-seen tkt_mtime.
    private var seenByRepo: [String: [String: String]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.seenByRepo = Self.loadSeen(from: defaults)
    }

    /// Scan every repo's local `.fossil` file and refresh both the seen-set
    /// and `openRequestCount`. Call this after any "Sync All" run (foreground
    /// loop or a background task) -- never before a sync, since it reads
    /// whatever the repo's local clone currently has on disk.
    func scanAfterSync(repos: [Repo], fossilPath: (Repo) -> String) async -> [ScanOutcome] {
        var outcomes: [ScanOutcome] = []
        var totalOpen = 0
        var updatedSeen = seenByRepo

        for repo in repos {
            let path = fossilPath(repo)
            let matches = await Task.detached(priority: .utility) {
                MaintainerRequestScanner.scan(fossilPath: path)
            }.value
            totalOpen += matches.count

            let repoKey = repo.id.uuidString
            let (newOnes, nextSeen) = Self.diff(current: matches, previouslySeen: updatedSeen[repoKey] ?? [:])
            updatedSeen[repoKey] = nextSeen
            if !newOnes.isEmpty {
                outcomes.append(ScanOutcome(repo: repo, newRequests: newOnes))
            }
        }

        seenByRepo = updatedSeen
        persistSeen()
        openRequestCount = totalOpen
        return outcomes
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

    private static func loadSeen(from defaults: UserDefaults) -> [String: [String: String]] {
        guard let data = defaults.data(forKey: seenDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistSeen() {
        guard let data = try? JSONEncoder().encode(seenByRepo) else { return }
        defaults.set(data, forKey: Self.seenDefaultsKey)
    }
}
