import Foundation
import SQLite3
import XCTest
@testable import Stone

/// Coverage for ticket 4c75227cc7's Requests screen bookkeeping:
/// `MaintainerRequestStore.scanAfterSync` recomputing `visibleRequests`/
/// `openRequestCount` wholesale on every scan (never accumulating), and
/// swipe-to-dismiss hiding a row until its ticket's mtime changes. Exercises
/// `scanAfterSync` against real fixture `.fossil` (SQLite) files, same as
/// MaintainerRequestScannerTests, but through the store rather than the
/// scanner directly, since the badge/dismiss bookkeeping lives there.
@MainActor
final class MaintainerRequestStoreTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintainerRequestStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        suiteName = "MaintainerRequestStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Fixture building (same shape as MaintainerRequestScannerTests)

    private func makeFixture(rows: [(uuid: String, mtime: String, designInput: String)]) throws -> String {
        let path = tempDir.appendingPathComponent("\(UUID().uuidString).fossil").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            XCTFail("could not create fixture db")
            return path
        }
        defer { sqlite3_close(db) }

        exec(db, """
        CREATE TABLE ticket(tkt_id INTEGER PRIMARY KEY, tkt_uuid TEXT, tkt_mtime TEXT,
                             title TEXT, comment TEXT, status TEXT, design_input TEXT)
        """)
        for row in rows {
            exec(db, """
            INSERT INTO ticket(tkt_uuid, tkt_mtime, title, comment, status, design_input)
            VALUES ('\(row.uuid)', '\(row.mtime)', 'Title \(row.uuid)', '', 'Open', '\(row.designInput)')
            """)
        }
        return path
    }

    private func exec(_ db: OpaquePointer, _ sql: String) {
        var errmsg: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
            let message = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            XCTFail("fixture SQL failed: \(message) (\(sql))")
        }
    }

    private func makeRepo(named name: String, at path: String) -> (repo: Repo, path: String) {
        (Repo(name: name, fileName: URL(fileURLWithPath: path).lastPathComponent), path)
    }

    // MARK: - Badge == visible rows, never accumulated

    func testBadgeEqualsVisibleRowCount() async throws {
        let pathA = try makeFixture(rows: [
            (uuid: "a1", mtime: "1", designInput: "confirm"),
            (uuid: "a2", mtime: "1", designInput: "confirm"),
        ])
        let pathB = try makeFixture(rows: [
            (uuid: "b1", mtime: "1", designInput: "confirm"),
        ])
        let repoA = makeRepo(named: "repo-a", at: pathA)
        let repoB = makeRepo(named: "repo-b", at: pathB)
        let paths: [UUID: String] = [repoA.repo.id: repoA.path, repoB.repo.id: repoB.path]

        let store = MaintainerRequestStore(defaults: defaults)
        _ = await store.scanAfterSync(repos: [repoA.repo, repoB.repo], fossilPath: { paths[$0.id]! })

        XCTAssertEqual(store.openRequestCount, 3)
        XCTAssertEqual(store.visibleRequests.count, 3)
    }

    /// The exact regression this ticket describes: a scan must never add to
    /// a running total -- rescanning the same, unchanged state must report
    /// the same count, not double it.
    func testRescanningUnchangedStateDoesNotAccumulateTheBadge() async throws {
        let path = try makeFixture(rows: [(uuid: "a1", mtime: "1", designInput: "confirm")])
        let repo = makeRepo(named: "repo-a", at: path)

        let store = MaintainerRequestStore(defaults: defaults)
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })

        XCTAssertEqual(store.openRequestCount, 1)
    }

    // MARK: - A resolved ticket vanishes from the list and the badge

    func testTicketResolvedBetweenScansVanishesFromListAndBadge() async throws {
        let path = try makeFixture(rows: [
            (uuid: "a1", mtime: "1", designInput: "confirm"),
            (uuid: "a2", mtime: "1", designInput: "confirm"),
        ])
        let repo = makeRepo(named: "repo-a", at: path)

        let store = MaintainerRequestStore(defaults: defaults)
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })
        XCTAssertEqual(store.openRequestCount, 2)

        // The maintainer resolved "a1" server-side; the next sync's local
        // clone no longer has it matching (simulated here by a fixture with
        // design_input reset to "none", same as a closed ticket would read).
        let resolvedPath = try makeFixture(rows: [
            (uuid: "a2", mtime: "1", designInput: "confirm"),
        ])
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in resolvedPath })

        XCTAssertEqual(store.openRequestCount, 1)
        XCTAssertEqual(store.visibleRequests.map(\.request.ticketUUID), ["a2"])
    }

    // MARK: - Dismiss hides until mtime changes

    func testDismissHidesRowImmediatelyAndBadgeDrops() async throws {
        let path = try makeFixture(rows: [
            (uuid: "a1", mtime: "1", designInput: "confirm"),
            (uuid: "a2", mtime: "1", designInput: "confirm"),
        ])
        let repo = makeRepo(named: "repo-a", at: path)

        let store = MaintainerRequestStore(defaults: defaults)
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })
        let row = try XCTUnwrap(store.visibleRequests.first { $0.request.ticketUUID == "a1" })

        store.dismiss(row)

        XCTAssertEqual(store.openRequestCount, 1)
        XCTAssertFalse(store.visibleRequests.contains { $0.request.ticketUUID == "a1" })
    }

    func testDismissedRowStaysHiddenAcrossAnUnchangedRescan() async throws {
        let path = try makeFixture(rows: [(uuid: "a1", mtime: "1", designInput: "confirm")])
        let repo = makeRepo(named: "repo-a", at: path)

        let store = MaintainerRequestStore(defaults: defaults)
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })
        let row = try XCTUnwrap(store.visibleRequests.first)
        store.dismiss(row)

        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })

        XCTAssertEqual(store.openRequestCount, 0)
        XCTAssertTrue(store.visibleRequests.isEmpty)
    }

    /// The other half of "until the ticket's mtime changes again": once the
    /// ticket is edited (new mtime), a dismissed row must reappear rather
    /// than staying hidden forever.
    func testDismissedRowReappearsOnceTheTicketsMtimeChanges() async throws {
        let path = try makeFixture(rows: [(uuid: "a1", mtime: "1", designInput: "confirm")])
        let repo = makeRepo(named: "repo-a", at: path)

        let store = MaintainerRequestStore(defaults: defaults)
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })
        let row = try XCTUnwrap(store.visibleRequests.first)
        store.dismiss(row)

        let editedPath = try makeFixture(rows: [(uuid: "a1", mtime: "2", designInput: "confirm")])
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in editedPath })

        XCTAssertEqual(store.openRequestCount, 1)
        XCTAssertEqual(store.visibleRequests.map(\.request.ticketUUID), ["a1"])
    }

    // MARK: - Clear all

    func testClearAllDismissesEveryVisibleRow() async throws {
        let path = try makeFixture(rows: [
            (uuid: "a1", mtime: "1", designInput: "confirm"),
            (uuid: "a2", mtime: "1", designInput: "confirm"),
        ])
        let repo = makeRepo(named: "repo-a", at: path)

        let store = MaintainerRequestStore(defaults: defaults)
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })

        store.clearAll()

        XCTAssertEqual(store.openRequestCount, 0)
        XCTAssertTrue(store.visibleRequests.isEmpty)

        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })
        XCTAssertEqual(store.openRequestCount, 0)
    }

    // MARK: - Server list is the source of truth (ticket 98c06fb7a7)

    /// The console dashboard's Needs-you list, not the local clone's own
    /// scan, is what the maintainer should see whenever the server is
    /// reachable -- even though the local `.fossil` file here has its own
    /// (different) matching ticket, the server's list wins outright.
    func testServerListBeatsLocalScanWhenReachable() async throws {
        let path = try makeFixture(rows: [(uuid: "local1", mtime: "1", designInput: "confirm")])
        let repo = makeRepo(named: "repo-a", at: path)
        let serverCards = [MaintainerRequest(ticketUUID: "server1", title: "From server", mtime: "1", isMergeGate: false)]

        let store = MaintainerRequestStore(defaults: defaults)
        let outcomes = await store.scanAfterSync(
            repos: [repo.repo],
            fossilPath: { _ in repo.path },
            serverList: { _ in serverCards })

        XCTAssertEqual(store.visibleRequests.map(\.request.ticketUUID), ["server1"])
        XCTAssertEqual(outcomes.first?.newRequests.map(\.ticketUUID), ["server1"])
    }

    /// A merge card whose merge is delegated to the coordinator is already
    /// excluded from the console's own Needs-you list (ticket c974ede9a4).
    /// The local clone here is stale and still has it flagged -- but once
    /// the server is reachable, it must never surface, in either the
    /// visible rows or a notification outcome.
    func testDelegatedMergeCardNeverNotifiesWhenServerOmitsIt() async throws {
        let path = try makeFixture(rows: [(uuid: "gate1", mtime: "1", designInput: "confirm")])
        let repo = makeRepo(named: "repo-a", at: path)

        let store = MaintainerRequestStore(defaults: defaults)
        let outcomes = await store.scanAfterSync(
            repos: [repo.repo],
            fossilPath: { _ in repo.path },
            serverList: { _ in [] })

        XCTAssertTrue(store.visibleRequests.isEmpty)
        XCTAssertEqual(store.openRequestCount, 0)
        XCTAssertTrue(outcomes.isEmpty)
    }

    /// A repo with no remote (or any other unreachable server) still falls
    /// back to the local scan -- the default `serverList` behavior,
    /// unchanged from every other test in this file that never passes one.
    func testFallsBackToLocalScanWhenServerListReturnsNil() async throws {
        let path = try makeFixture(rows: [(uuid: "a1", mtime: "1", designInput: "confirm")])
        let repo = makeRepo(named: "repo-a", at: path)

        let store = MaintainerRequestStore(defaults: defaults)
        let outcomes = await store.scanAfterSync(
            repos: [repo.repo],
            fossilPath: { _ in repo.path },
            serverList: { _ in nil })

        XCTAssertEqual(store.visibleRequests.map(\.request.ticketUUID), ["a1"])
        XCTAssertEqual(outcomes.first?.newRequests.map(\.ticketUUID), ["a1"])
    }
}
