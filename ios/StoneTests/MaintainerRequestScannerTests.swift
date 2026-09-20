import SQLite3
import XCTest
@testable import Stone

/// Coverage for ticket 98c06fb7a7's rescope: `MaintainerRequestScanner` reads
/// the server-synced `needs_you` custom ticket field alone (no more local
/// re-derivation from `design_input`/`human_verify`) against a fixture
/// SQLite file standing in for a repo's `.fossil` file, plus
/// `hasTicket`'s existence check (ticket 98c06fb7a7's deep-link fix) and
/// `MaintainerRequestStore.diff`'s seen-set logic against plain in-memory
/// data, with no file I/O at all.
final class MaintainerRequestScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintainerRequestScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture building

    /// Rows as (uuid, title, mtime, needsYou). `needsYou` of `nil` omits
    /// that column from the table entirely, standing in for a repo whose
    /// remote never configured ticket 98c06fb7a7's `needs_you` field.
    private func makeFixture(
        rows: [(uuid: String, title: String, mtime: String, needsYou: String?)]
    ) throws -> String {
        let path = tempDir.appendingPathComponent("\(UUID().uuidString).fossil").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            XCTFail("could not create fixture db")
            return path
        }
        defer { sqlite3_close(db) }

        var columns = ["tkt_id INTEGER PRIMARY KEY", "tkt_uuid TEXT", "tkt_mtime TEXT",
                        "title TEXT", "comment TEXT", "status TEXT"]
        let includesNeedsYou = rows.contains { $0.needsYou != nil }
        if includesNeedsYou { columns.append("needs_you TEXT") }

        exec(db, "CREATE TABLE ticket(\(columns.joined(separator: ", ")))")

        for row in rows {
            var fields = ["tkt_uuid", "tkt_mtime", "title", "comment", "status"]
            var values = [quote(row.uuid), quote(row.mtime), quote(row.title), quote(""), quote("Open")]
            if includesNeedsYou {
                fields.append("needs_you")
                values.append(quote(row.needsYou ?? ""))
            }
            exec(db, "INSERT INTO ticket(\(fields.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))")
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

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: - Column presence

    func testRepoWithoutNeedsYouColumnContributesNothing() throws {
        let path = try makeFixture(rows: [
            (uuid: "abc123", title: "Just a ticket", mtime: "2026-09-19", needsYou: nil)
        ])
        XCTAssertEqual(MaintainerRequestScanner.scan(fossilPath: path), [])
    }

    // MARK: - needs_you gates which values ever notify

    func testDecisionValueIsFoundWhenColumnPresent() throws {
        let path = try makeFixture(rows: [
            (uuid: "confirm1", title: "Pick an option", mtime: "2026-09-19T10:00:00", needsYou: "decision"),
            (uuid: "confirm2", title: "Not ready yet", mtime: "2026-09-19T10:00:00", needsYou: "none"),
        ])
        let results = MaintainerRequestScanner.scan(fossilPath: path)
        XCTAssertEqual(results.map(\.ticketUUID), ["confirm1"])
        XCTAssertEqual(results.first?.title, "Pick an option")
    }

    func testMergeValueIsFound() throws {
        let path = try makeFixture(rows: [
            (uuid: "gate1", title: "Merge candidate A", mtime: "2026-09-19", needsYou: "merge"),
        ])
        XCTAssertEqual(MaintainerRequestScanner.scan(fossilPath: path).map(\.ticketUUID), ["gate1"])
    }

    func testTryThisValueIsFound() throws {
        let path = try makeFixture(rows: [
            (uuid: "verify1", title: "Try this build", mtime: "2026-09-19", needsYou: "try-this"),
        ])
        XCTAssertEqual(MaintainerRequestScanner.scan(fossilPath: path).map(\.ticketUUID), ["verify1"])
    }

    /// The exact case the ticket calls out: a merge delegated to the
    /// coordinator (needs_you = "coordinator") must never notify -- it is
    /// structurally excluded, not merely filtered out of the UI.
    func testCoordinatorValueNeverNotifies() throws {
        let path = try makeFixture(rows: [
            (uuid: "delegated1", title: "Delegated merge", mtime: "2026-09-19", needsYou: "coordinator"),
        ])
        XCTAssertEqual(MaintainerRequestScanner.scan(fossilPath: path), [])
    }

    func testNoneValueNeverNotifies() throws {
        let path = try makeFixture(rows: [
            (uuid: "quiet1", title: "Nothing to do", mtime: "2026-09-19", needsYou: "none"),
        ])
        XCTAssertEqual(MaintainerRequestScanner.scan(fossilPath: path), [])
    }

    func testUnrecognizedValueNeverNotifies() throws {
        let path = try makeFixture(rows: [
            (uuid: "odd1", title: "Unexpected", mtime: "2026-09-19", needsYou: "something-new"),
        ])
        XCTAssertEqual(MaintainerRequestScanner.scan(fossilPath: path), [])
    }

    func testAllFiveValuesFilterToOnlyTheThreeThatNotify() throws {
        let path = try makeFixture(rows: [
            (uuid: "a", title: "Decision", mtime: "1", needsYou: "decision"),
            (uuid: "b", title: "Merge", mtime: "1", needsYou: "merge"),
            (uuid: "c", title: "Try this", mtime: "1", needsYou: "try-this"),
            (uuid: "d", title: "Delegated", mtime: "1", needsYou: "coordinator"),
            (uuid: "e", title: "Nothing", mtime: "1", needsYou: "none"),
        ])
        let results = Set(MaintainerRequestScanner.scan(fossilPath: path).map(\.ticketUUID))
        XCTAssertEqual(results, ["a", "b", "c"])
    }

    // MARK: - Kind classification (ticket 4c75227cc7 / 98c06fb7a7)

    func testKindIsMergeCardForMergeValue() throws {
        let path = try makeFixture(rows: [
            (uuid: "gate1", title: "Merge candidate A", mtime: "2026-09-19", needsYou: "merge"),
        ])
        XCTAssertEqual(MaintainerRequestScanner.scan(fossilPath: path).map(\.kind), [.mergeCard])
    }

    func testKindIsDecisionForDecisionValue() throws {
        let path = try makeFixture(rows: [
            (uuid: "plain1", title: "Plain decision", mtime: "2026-09-19", needsYou: "decision"),
        ])
        XCTAssertEqual(MaintainerRequestScanner.scan(fossilPath: path).map(\.kind), [.decision])
    }

    func testKindIsTryThisForTryThisValue() throws {
        let path = try makeFixture(rows: [
            (uuid: "verify1", title: "Try this build", mtime: "2026-09-19", needsYou: "try-this"),
        ])
        XCTAssertEqual(MaintainerRequestScanner.scan(fossilPath: path).map(\.kind), [.tryThis])
    }

    // MARK: - hasTicket (TicketOpener's deep-link existence check)

    func testHasTicketTrueWhenTheUuidIsInTheClone() throws {
        let path = try makeFixture(rows: [
            (uuid: "present1", title: "Present", mtime: "1", needsYou: nil),
        ])
        XCTAssertTrue(MaintainerRequestScanner.hasTicket(fossilPath: path, uuid: "present1"))
    }

    func testHasTicketFalseWhenTheUuidIsNotInTheClone() throws {
        let path = try makeFixture(rows: [
            (uuid: "present1", title: "Present", mtime: "1", needsYou: nil),
        ])
        XCTAssertFalse(MaintainerRequestScanner.hasTicket(fossilPath: path, uuid: "missing1"))
    }

    // MARK: - Seen-set diffing (MaintainerRequestStore.diff)

    private func request(_ uuid: String, mtime: String) -> MaintainerRequest {
        MaintainerRequest(ticketUUID: uuid, title: "t-\(uuid)", mtime: mtime, kind: .decision)
    }

    func testFirstScanReportsEveryMatchAsNew() {
        let (new, seen) = MaintainerRequestStore.diff(
            current: [request("a", mtime: "1"), request("b", mtime: "1")],
            previouslySeen: [:])
        XCTAssertEqual(Set(new.map(\.ticketUUID)), ["a", "b"])
        XCTAssertEqual(seen, ["a": "1", "b": "1"])
    }

    func testUnchangedTicketIsNotReportedAgain() {
        let (new, _) = MaintainerRequestStore.diff(
            current: [request("a", mtime: "1")],
            previouslySeen: ["a": "1"])
        XCTAssertTrue(new.isEmpty)
    }

    func testTicketEditedAgainIsReportedAsNewOnMtimeChange() {
        let (new, seen) = MaintainerRequestStore.diff(
            current: [request("a", mtime: "2")],
            previouslySeen: ["a": "1"])
        XCTAssertEqual(new.map(\.ticketUUID), ["a"])
        XCTAssertEqual(seen, ["a": "2"])
    }

    func testResolvedTicketDropsOutOfSeenSetSoItCanNotifyAgainIfReopened() {
        // "a" no longer matches (e.g. the maintainer resolved it) -- it must
        // not linger in the returned seen-set.
        let (_, seenAfterResolve) = MaintainerRequestStore.diff(
            current: [request("b", mtime: "1")],
            previouslySeen: ["a": "1", "b": "1"])
        XCTAssertNil(seenAfterResolve["a"])

        // If "a" reappears later (same uuid, new mtime -- reopened), it must
        // be reported as new rather than silently remembered from before.
        let (new, _) = MaintainerRequestStore.diff(
            current: [request("a", mtime: "9")],
            previouslySeen: seenAfterResolve)
        XCTAssertEqual(new.map(\.ticketUUID), ["a"])
    }
}
