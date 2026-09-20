import XCTest
@testable import Stone

/// Coverage for ticket 98c06fb7a7's deep-link fix: a tapped notification
/// used to open View Ticket in a local Fossil clone that didn't actually
/// have the ticket ("ERROR: no such variable: tkt_uuid", "Ticket Hash:
/// Deleted (0)"). `TicketOpener.resolve` is the pure decision logic behind
/// that fix -- exercised here with injected `hasTicket`/`sync` stubs, no
/// real `.fossil` file or network sync.
@MainActor
final class TicketOpenerTests: XCTestCase {
    private func makeRepo(remoteURL: String? = "https://example.com/myrepo") -> Repo {
        Repo(name: "repo-a", fileName: "repo-a.fossil", remoteURL: remoteURL)
    }

    func testTicketPresentLocallyRoutesLocalWithoutSyncing() async {
        var syncCalled = false
        let repo = makeRepo()
        let destination = await TicketOpener.resolve(
            repo: repo,
            ticketUUID: "t1",
            hasTicket: { true },
            sync: { syncCalled = true })

        XCTAssertEqual(destination, .local(repoID: repo.id, path: "/tktview/t1"))
        XCTAssertFalse(syncCalled)
    }

    func testMissingTicketSyncsThenRoutesLocalIfSyncBringsItIn() async {
        var hasTicketCallCount = 0
        var syncCalled = false
        let repo = makeRepo()

        let destination = await TicketOpener.resolve(
            repo: repo,
            ticketUUID: "t1",
            hasTicket: {
                hasTicketCallCount += 1
                return hasTicketCallCount > 1 // missing on the first check, present after the sync
            },
            sync: { syncCalled = true })

        XCTAssertTrue(syncCalled)
        XCTAssertEqual(destination, .local(repoID: repo.id, path: "/tktview/t1"))
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
            hasTicket: { false },
            sync: { syncCalled = true })

        XCTAssertEqual(destination, .unavailable)
        XCTAssertFalse(syncCalled)
    }

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
}
