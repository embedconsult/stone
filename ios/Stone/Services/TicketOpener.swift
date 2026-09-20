import Foundation

/// Decides where a tap on a maintainer-request ticket (a notification, or a
/// Requests-screen row) should actually land -- ticket 98c06fb7a7.
///
/// The maintainer's report: tapping a notification opened View Ticket in the
/// local Fossil clone with "ERROR: no such variable: tkt_uuid" and "Ticket
/// Hash: Deleted (0)" -- an empty ticket page, because the clone that got
/// opened didn't actually have that ticket yet (wrong repo for the uuid, or
/// the clone hadn't synced it in). This never trusts "the caller says this
/// ticket is in this repo": it verifies against the clone's own `.fossil`
/// file first, syncs once if the ticket isn't there, and if it's still
/// missing after that, resolves to the server's own ticket page over https
/// instead -- never back to the empty local page.
@MainActor
enum TicketOpener {
    enum Destination: Equatable {
        /// Route to this repo's own embedded WebView, same as before.
        case local(repoID: UUID, path: String)
        /// The ticket isn't (yet) in this clone even after a fresh sync --
        /// open the remote's page instead of an empty local one.
        case remote(URL)
        /// No remote to fall back to (or a malformed one) and the ticket
        /// isn't local either -- there is nothing safe to open.
        case unavailable
    }

    /// Pure decision logic, with `hasTicket`/`sync` injected so this is
    /// testable without a real `.fossil` file or network sync (StoneTests).
    /// `hasTicket` is called again after `sync` runs, since a sync can be
    /// exactly what brings the ticket in.
    static func resolve(
        repo: Repo,
        ticketUUID: String,
        hasTicket: () -> Bool,
        sync: () async -> Void
    ) async -> Destination {
        if hasTicket() {
            return .local(repoID: repo.id, path: "/tktview/\(ticketUUID)")
        }

        if repo.remoteURL != nil {
            await sync()
            if hasTicket() {
                return .local(repoID: repo.id, path: "/tktview/\(ticketUUID)")
            }
        }

        guard let remoteURL = repo.remoteURL,
              let url = remoteTicketURL(remoteURL: remoteURL, ticketUUID: ticketUUID) else {
            return .unavailable
        }
        return .remote(url)
    }

    /// Resolves and routes: the real call site behind `resolve` above, wired
    /// to an actual clone on disk (`RepoStore`) and a real sync. Used by
    /// `NotificationManager`'s tap handler and `RequestsView`'s row tap --
    /// the same resolution either way, so a notification and a Requests-
    /// screen tap for the same ticket always land in the same place.
    static func open(repo: Repo, ticketUUID: String, store: RepoStore = .shared) async {
        let path = store.fileURL(for: repo).path
        let destination = await resolve(
            repo: repo,
            ticketUUID: ticketUUID,
            hasTicket: { MaintainerRequestScanner.hasTicket(fossilPath: path, uuid: ticketUUID) },
            sync: { _ = try? await store.sync(repo) }
        )
        switch destination {
        case .local(let repoID, let ticketPath):
            DeepLinkRouter.shared.route(repoID: repoID, path: ticketPath)
        case .remote(let url):
            DeepLinkRouter.shared.routeToRemote(url: url)
        case .unavailable:
            break
        }
    }

    /// `<remote base>/tktview/<uuid>`, with any userinfo (login credentials)
    /// stripped -- this URL is opened externally (Safari), which must not
    /// carry the sync password Fossil accepts as URL userinfo.
    nonisolated static func remoteTicketURL(remoteURL: String, ticketUUID: String) -> URL? {
        guard var comps = URLComponents(string: remoteURL) else { return nil }
        comps.user = nil
        comps.password = nil
        let base = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = "\(base)/tktview/\(ticketUUID)"
        return comps.url
    }
}
