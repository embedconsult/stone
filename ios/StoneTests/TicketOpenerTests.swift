import XCTest
@testable import Stone

/// Coverage for ticket 98c06fb7a7's deep-link fix: a tapped notification
/// used to open View Ticket in a local Fossil clone that didn't actually
/// have the ticket ("ERROR: no such variable: tkt_uuid", "Ticket Hash:
/// Deleted (0)"). `TicketOpener.resolve` is the pure decision logic behind
/// that fix -- exercised here with injected `hasTicket`/`sync` stubs, no
/// real `.fossil` file or network sync.
///
/// Also covers this ticket's later acceptance addition: which surface a tap
/// lands on depends on the request's `Kind`, not just on whether the ticket
/// is in this clone -- a merge card's Approve control lives on the served
/// console, decision/try-this open the local ticket view with the reply
/// composer focused.
@MainActor
final class TicketOpenerTests: XCTestCase {
    private func makeRepo(remoteURL: String? = "https://example.com/myrepo") -> Repo {
        Repo(name: "repo-a", fileName: "repo-a.fossil", remoteURL: remoteURL)
    }

    // MARK: - decision/try-this: local ticket view, composer focused

    func testTicketPresentLocallyRoutesLocalWithoutSyncing() async {
        var syncCalled = false
        let repo = makeRepo()
        let destination = await TicketOpener.resolve(
            repo: repo,
            ticketUUID: "t1",
            kind: .decision,
            hasTicket: { true },
            sync: { syncCalled = true })

        XCTAssertEqual(destination, .local(repoID: repo.id, path: "/tktview/t1", focusComposer: true, note: nil))
        XCTAssertFalse(syncCalled)
    }

    func testMissingTicketSyncsThenRoutesLocalIfSyncBringsItIn() async {
        var hasTicketCallCount = 0
        var syncCalled = false
        let repo = makeRepo()

        let destination = await TicketOpener.resolve(
            repo: repo,
            ticketUUID: "t1",
            kind: .tryThis,
            hasTicket: {
                hasTicketCallCount += 1
                return hasTicketCallCount > 1 // missing on the first check, present after the sync
            },
            sync: { syncCalled = true })

        XCTAssertTrue(syncCalled)
        XCTAssertEqual(destination, .local(repoID: repo.id, path: "/tktview/t1", focusComposer: true, note: nil))
    }

    /// The exact regression this ticket describes: a ticket still missing
    /// after a fresh sync must never resolve to the local page (which
    /// Fossil would render empty) -- it falls back to the remote instead.
    func testMissingTicketStillMissingAfterSyncOpensRemotePage() async {
        var syncCalled = false
        let repo = makeRepo(remoteURL: "https://user@example.com/myrepo")

        let destination = await TicketOpener.resolve(
            repo: repo,
            ticketUUID: "t1",
            kind: .decision,
            hasTicket: { false },
            sync: { syncCalled = true })

        XCTAssertTrue(syncCalled)
        XCTAssertEqual(destination, .remote(URL(string: "https://example.com/myrepo/tktview/t1")!))
    }

    /// No remote to fall back to: never silently reach for the local page
    /// either (it would still be the same empty ticket).
    func testNoRemoteAndMissingTicketReturnsUnavailableWithoutSyncing() async {
        var syncCalled = false
        let destination = await TicketOpener.resolve(
            repo: makeRepo(remoteURL: nil),
            ticketUUID: "t1",
            kind: .decision,
            hasTicket: { false },
            sync: { syncCalled = true })

        XCTAssertEqual(destination, .unavailable)
        XCTAssertFalse(syncCalled)
    }

    // MARK: - Kind pins the resolved target (acceptance: 2026-09-21 00:0xZ)

    /// Decision opens the local ticket view with the composer focused --
    /// pinned separately from try-this below even though both share the
    /// same underlying chain, since a future change that special-cases one
    /// of them must break exactly one of these, not both silently.
    func testDecisionKindOpensLocalTicketViewWithComposerFocused() async {
        let repo = makeRepo()
        let destination = await TicketOpener.resolve(
            repo: repo, ticketUUID: "t1", kind: .decision, hasTicket: { true }, sync: {})
        XCTAssertEqual(destination, .local(repoID: repo.id, path: "/tktview/t1", focusComposer: true, note: nil))
    }

    func testTryThisKindOpensLocalTicketViewWithComposerFocused() async {
        let repo = makeRepo()
        let destination = await TicketOpener.resolve(
            repo: repo, ticketUUID: "t1", kind: .tryThis, hasTicket: { true }, sync: {})
        XCTAssertEqual(destination, .local(repoID: repo.id, path: "/tktview/t1", focusComposer: true, note: nil))
    }

    /// The maintainer's own complaint this acceptance item answers: a merge
    /// card's tap must land where the Approve control actually is, not on
    /// Fossil's own rendered ticket page. Never even consults `hasTicket`
    /// when a remote is configured -- there's nothing local to check for.
    func testMergeCardKindOpensConsoleMergeReviewPageWhenRemoteConfigured() async {
        var hasTicketCalled = false
        let repo = makeRepo(remoteURL: "https://stone@example.com/myrepo")
        let destination = await TicketOpener.resolve(
            repo: repo, ticketUUID: "t1", kind: .mergeCard,
            hasTicket: { hasTicketCalled = true; return true }, sync: {})

        XCTAssertEqual(destination, .remote(URL(string: "https://example.com/myrepo/ext/chat?tkt=t1")!))
        XCTAssertFalse(hasTicketCalled)
    }

    // MARK: - Offline fallback (acceptance: 2026-09-21 00:0xZ)

    /// No remote configured at all: a merge card falls back to the local
    /// ticket view, but carries a note that this page can't approve
    /// anything -- never a silent, indistinguishable-from-decision local
    /// open.
    func testMergeCardKindWithNoRemoteFallsBackToLocalWithApprovalNote() async {
        let repo = makeRepo(remoteURL: nil)
        let destination = await TicketOpener.resolve(
            repo: repo, ticketUUID: "t1", kind: .mergeCard, hasTicket: { true }, sync: {})

        guard case .local(let repoID, let path, let focusComposer, let note) = destination else {
            return XCTFail("expected .local, got \(destination)")
        }
        XCTAssertEqual(repoID, repo.id)
        XCTAssertEqual(path, "/tktview/t1")
        XCTAssertFalse(focusComposer)
        XCTAssertNotNil(note)
    }

    /// No remote AND the ticket isn't in this clone either: there is
    /// nothing safe to open, same as the decision/try-this "unavailable"
    /// case above.
    func testMergeCardKindWithNoRemoteAndNoLocalTicketIsUnavailable() async {
        let destination = await TicketOpener.resolve(
            repo: makeRepo(remoteURL: nil), ticketUUID: "t1", kind: .mergeCard, hasTicket: { false }, sync: {})
        XCTAssertEqual(destination, .unavailable)
    }

    // MARK: - URL building

    func testRemoteTicketURLStripsCredentialsAndAppendsTicketPath() {
        let url = TicketOpener.remoteTicketURL(
            remoteURL: "https://stone@example.com/myrepo",
            ticketUUID: "abc123")
        XCTAssertEqual(url, URL(string: "https://example.com/myrepo/tktview/abc123"))
    }

    func testRemoteTicketURLHandlesTrailingSlash() {
        let url = TicketOpener.remoteTicketURL(
            remoteURL: "https://example.com/myrepo/",
            ticketUUID: "abc123")
        XCTAssertEqual(url, URL(string: "https://example.com/myrepo/tktview/abc123"))
    }

    func testMergeReviewURLStripsCredentialsAndCarriesTicketAsQueryItem() {
        let url = TicketOpener.mergeReviewURL(
            remoteURL: "https://stone@example.com/myrepo",
            ticketUUID: "abc123")
        XCTAssertEqual(url, URL(string: "https://example.com/myrepo/ext/chat?tkt=abc123"))
    }

    func testMergeReviewURLHandlesTrailingSlash() {
        let url = TicketOpener.mergeReviewURL(
            remoteURL: "https://example.com/myrepo/",
            ticketUUID: "abc123")
        XCTAssertEqual(url, URL(string: "https://example.com/myrepo/ext/chat?tkt=abc123"))
    }
}
