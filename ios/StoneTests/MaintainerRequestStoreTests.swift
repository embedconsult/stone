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

    // MARK: - receivedCounts skips repos with nothing new (ticket d4d02c604f)

    /// A repo whose tally is zero this round can't have anything new in its
    /// ticket table, so its previously-scanned rows must be carried over
    /// unchanged rather than dropped -- passing `receivedCounts` must never
    /// make another repo's requests vanish, the same guarantee the "always
    /// pass every repo" doc comment already makes for the plain `repos` list.
    func testZeroReceivedCarriesOverExistingRowsWithoutRescanning() async throws {
        let pathA = try makeFixture(rows: [(uuid: "a1", mtime: "1", designInput: "confirm")])
        let pathB = try makeFixture(rows: [(uuid: "b1", mtime: "1", designInput: "confirm")])
        let repoA = makeRepo(named: "repo-a", at: pathA)
        let repoB = makeRepo(named: "repo-b", at: pathB)
        let paths: [UUID: String] = [repoA.repo.id: repoA.path, repoB.repo.id: repoB.path]

        let store = MaintainerRequestStore(defaults: defaults)
        _ = await store.scanAfterSync(repos: [repoA.repo, repoB.repo], fossilPath: { paths[$0.id]! })
        XCTAssertEqual(store.openRequestCount, 2)

        // Repo B resolved its ticket server-side, but its tally is zero this
        // round (nothing received), so scanAfterSync must not notice --
        // fed a path that would report zero rows if it were actually
        // rescanned, to prove it wasn't.
        let resolvedPathB = try makeFixture(rows: [])
        let pathsAfter: [UUID: String] = [repoA.repo.id: pathA, repoB.repo.id: resolvedPathB]
        _ = await store.scanAfterSync(
            repos: [repoA.repo, repoB.repo],
            receivedCounts: [repoA.repo.id: 1, repoB.repo.id: 0],
            fossilPath: { pathsAfter[$0.id]! }
        )

        XCTAssertEqual(store.openRequestCount, 2)
        XCTAssertEqual(Set(store.visibleRequests.map(\.request.ticketUUID)), ["a1", "b1"])
    }

    /// The other half: when a repo's tally IS nonzero, it must actually be
    /// rescanned (not just carried over), so a resolved ticket really does
    /// disappear.
    func testNonzeroReceivedActuallyRescansAndPicksUpChanges() async throws {
        let path = try makeFixture(rows: [
            (uuid: "a1", mtime: "1", designInput: "confirm"),
            (uuid: "a2", mtime: "1", designInput: "confirm"),
        ])
        let repo = makeRepo(named: "repo-a", at: path)

        let store = MaintainerRequestStore(defaults: defaults)
        _ = await store.scanAfterSync(repos: [repo.repo], fossilPath: { _ in repo.path })
        XCTAssertEqual(store.openRequestCount, 2)

        let resolvedPath = try makeFixture(rows: [(uuid: "a2", mtime: "1", designInput: "confirm")])
        _ = await store.scanAfterSync(
            repos: [repo.repo],
            receivedCounts: [repo.repo.id: 1],
            fossilPath: { _ in resolvedPath }
        )

        XCTAssertEqual(store.openRequestCount, 1)
        XCTAssertEqual(store.visibleRequests.map(\.request.ticketUUID), ["a2"])
    }
}
