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
///
/// The maintainer's follow-up complaint ("notifications ... don't have
/// consistently appropriate actionable card links") added a second axis on
/// top of that: WHICH page a tap should land on depends on the request's
/// `Kind`, not just on whether the ticket exists locally. A merge card's
/// Approve control lives on the served console, never in Fossil's own
/// rendered ticket HTML, so that kind is routed there directly (falling back
/// to the local ticket view, with a visible note, only when there's no
/// remote to build that console link from); `.decision`/`.tryThis` still
/// open the local ticket view same as before, just with the reply composer
/// focused now.
@MainActor
enum TicketOpener {
    enum Destination: Equatable {
        /// Route to this repo's own embedded WebView. `focusComposer` asks
        /// the WebView to scroll to and focus Fossil's own ticket comment
        /// field once the page loads (decision/try-this); `note`, when
        /// non-nil, is shown once as a one-line banner (the merge-card
        /// offline fallback: "this page can't approve anything, use the
        /// console").
        case local(repoID: UUID, path: String, focusComposer: Bool, note: String?)
        /// Either the ticket isn't (yet) in this clone even after a fresh
        /// sync, or this is a merge card whose Approve action belongs on the
        /// served console -- either way, open this URL externally rather
        /// than a local page that can't do the job.
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
        kind: MaintainerRequest.Kind,
        hasTicket: () -> Bool,
        sync: () async -> Void
    ) async -> Destination {
        switch kind {
        case .mergeCard:
            return mergeCardDestination(repo: repo, ticketUUID: ticketUUID, hasTicket: hasTicket)
        case .decision, .tryThis:
            return await ticketViewDestination(repo: repo, ticketUUID: ticketUUID, hasTicket: hasTicket, sync: sync)
        }
    }

    /// A merge card's Approve control lives on the served console's
    /// merge-review page, never on Fossil's own rendered ticket HTML, so
    /// this never even checks `hasTicket()` when a remote is configured --
    /// there's nothing the local clone could offer that would help. Only
    /// when there's no remote (or its URL is malformed) does this fall back
    /// to the local ticket view, carrying a note that approval still needs
    /// the console; if the ticket isn't in this clone either, there is
    /// nothing safe to open at all.
    private static func mergeCardDestination(
        repo: Repo,
        ticketUUID: String,
        hasTicket: () -> Bool
    ) -> Destination {
        if let remoteURL = repo.remoteURL,
           let url = mergeReviewURL(remoteURL: remoteURL, ticketUUID: ticketUUID) {
            return .remote(url)
        }
        guard hasTicket() else { return .unavailable }
        return .local(
            repoID: repo.id,
            path: ticketPath(ticketUUID),
            focusComposer: false,
            note: "Approving this merge requires the console -- this local ticket page can't do it.")
    }

    /// The original verify-then-sync-then-remote-fallback chain, unchanged
    /// except that a local hit now asks for the reply composer to be
    /// focused, since `.decision`/`.tryThis` are exactly the two kinds a
    /// maintainer answers by replying on the ticket.
    private static func ticketViewDestination(
        repo: Repo,
        ticketUUID: String,
        hasTicket: () -> Bool,
        sync: () async -> Void
    ) async -> Destination {
        if hasTicket() {
            return .local(repoID: repo.id, path: ticketPath(ticketUUID), focusComposer: true, note: nil)
        }

        if repo.remoteURL != nil {
            await sync()
            if hasTicket() {
                return .local(repoID: repo.id, path: ticketPath(ticketUUID), focusComposer: true, note: nil)
            }
        }

        guard let remoteURL = repo.remoteURL,
              let url = remoteTicketURL(remoteURL: remoteURL, ticketUUID: ticketUUID) else {
            return .unavailable
        }
        return .remote(url)
    }

    private static func ticketPath(_ ticketUUID: String) -> String { "/tktview/\(ticketUUID)" }

    /// Resolves and routes: the real call site behind `resolve` above, wired
    /// to an actual clone on disk (`RepoStore`) and a real sync. Used by
    /// `NotificationManager`'s tap handler and `RequestsView`'s row tap --
    /// the same resolution either way, so a notification and a Requests-
    /// screen tap for the same ticket always land in the same place.
    static func open(repo: Repo, ticketUUID: String, kind: MaintainerRequest.Kind, store: RepoStore = .shared) async {
        let path = store.fileURL(for: repo).path
        let destination = await resolve(
            repo: repo,
            ticketUUID: ticketUUID,
            kind: kind,
            hasTicket: { MaintainerRequestScanner.hasTicket(fossilPath: path, uuid: ticketUUID) },
            sync: { _ = try? await store.sync(repo) }
        )
        switch destination {
        case .local(let repoID, let ticketPath, let focusComposer, let note):
            DeepLinkRouter.shared.route(repoID: repoID, path: ticketPath, focusComposer: focusComposer, note: note)
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

    /// `<remote base>/ext/chat?tkt=<uuid>` -- the served console's
    /// merge-review surface for a specific ticket, where the Approve button
    /// actually lives. Built the same way `remoteTicketURL` above builds a
    /// plain ticket link (userinfo stripped, path appended to whatever base
    /// path the remote already carries).
    ///
    /// NOT yet independently confirmed against ollama-codex's own
    /// `chat_cgi_app.cr` -- this checkout has no access to that repo (no
    /// peer declared), so `ext/chat` and the `tkt` query parameter name are
    /// this client's best-effort match to the coordinator's own description
    /// of the route, following this app's existing query-item convention
    /// (RemoteSession, RepoWebView's fpid/name parsing) rather than a
    /// confirmed server contract. Revisit once that contract is confirmed.
    nonisolated static func mergeReviewURL(remoteURL: String, ticketUUID: String) -> URL? {
        guard var comps = URLComponents(string: remoteURL) else { return nil }
        comps.user = nil
        comps.password = nil
        let base = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = "\(base)/ext/chat"
        comps.queryItems = [URLQueryItem(name: "tkt", value: ticketUUID)]
        return comps.url
    }
}
