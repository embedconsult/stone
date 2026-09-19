import SQLite3
import XCTest
@testable import Stone

/// Coverage for ticket 1a55c5d8b8's request scan: `MaintainerRequestScanner`
/// against a fixture SQLite file standing in for a repo's `.fossil` file
/// (both with and without the custom `design_input`/`human_verify` ticket
/// columns -- most Fossil repos won't have them, see the scanner's doc), and
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

    /// Rows as (uuid, title, mtime, comment, designInput, humanVerify).
    /// `designInput`/`humanVerify` of `nil` omits that column from the
    /// table entirely, standing in for a repo whose ticket configuration
    /// never added it.
    private func makeFixture(
        rows: [(uuid: String, title: String, mtime: String, comment: String,
                designInput: String?, humanVerify: String?)]
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
        let includesDesignInput = rows.contains { $0.designInput != nil }
        let includesHumanVerify = rows.contains { $0.humanVerify != nil }
        if includesDesignInput { columns.append("design_input TEXT") }
        if includesHumanVerify { columns.append("human_verify TEXT") }

        exec(db, "CREATE TABLE ticket(\(columns.joined(separator: ", ")))")

        for row in rows {
            var fields = ["tkt_uuid", "tkt_mtime", "title", "comment", "status"]
            var values = [quote(row.uuid), quote(row.mtime), quote(row.title), quote(row.comment), quote("Open")]
            if includesDesignInput {
                fields.append("design_input")
                values.append(quote(row.designInput ?? ""))
            }
            if includesHumanVerify {
                fields.append("human_verify")
                values.append(quote(row.humanVerify ?? ""))
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

    func testRepoWithoutEitherCustomColumnContributesNothing() throws {
        let path = try makeFixture(rows: [
            (uuid: "abc123", title: "Just a ticket", mtime: "2026-09-19", comment: "no custom fields here",
             designInput: nil, humanVerify: nil)
        ])
        XCTAssertEqual(MaintainerRequestScanner.scan(fossilPath: path), [])
    }

    func testDesignInputConfirmIsFoundWhenColumnPresent() throws {
        let path = try makeFixture(rows: [
            (uuid: "confirm1", title: "Pick an option", mtime: "2026-09-19T10:00:00",
             comment: "plain decision", designInput: "confirm", humanVerify: nil),
            (uuid: "confirm2", title: "Not ready yet", mtime: "2026-09-19T10:00:00",
             comment: "still drafting", designInput: "none", humanVerify: nil),
        ])
        let results = MaintainerRequestScanner.scan(fossilPath: path)
        XCTAssertEqual(results.map(\.ticketUUID), ["confirm1"])
        XCTAssertEqual(results.first?.title, "Pick an option")
    }

    func testMergeGateCommentIsFlaggedWithinDesignInputConfirm() throws {
        let path = try makeFixture(rows: [
            (uuid: "gate1", title: "Merge candidate A", mtime: "2026-09-19",
             comment: "OCX-MERGE-GATE: pick between A and B", designInput: "confirm", humanVerify: nil),
            (uuid: "plain1", title: "Plain decision", mtime: "2026-09-19",
             comment: "just asking for a call", designInput: "confirm", humanVerify: nil),
        ])
        let results = MaintainerRequestScanner.scan(fossilPath: path)
            .reduce(into: [String: Bool]()) { $0[$1.ticketUUID] = $1.isMergeGate }
        XCTAssertEqual(results["gate1"], true)
        XCTAssertEqual(results["plain1"], false)
    }

    func testHumanVerifyIsFoundOnlyWhenSetAndNotNone() throws {
        let path = try makeFixture(rows: [
            (uuid: "verify1", title: "Try this build", mtime: "2026-09-19",
             comment: "", designInput: nil, humanVerify: "please test on device"),
            (uuid: "verify2", title: "Nothing to verify", mtime: "2026-09-19",
             comment: "", designInput: nil, humanVerify: "none"),
            (uuid: "verify3", title: "Empty field", mtime: "2026-09-19",
             comment: "", designInput: nil, humanVerify: ""),
        ])
        let results = MaintainerRequestScanner.scan(fossilPath: path)
        XCTAssertEqual(results.map(\.ticketUUID), ["verify1"])
    }

    func testBothColumnsPresentUnionsBothKinds() throws {
        let path = try makeFixture(rows: [
            (uuid: "a", title: "Decision", mtime: "1", comment: "", designInput: "confirm", humanVerify: "none"),
            (uuid: "b", title: "Try this", mtime: "1", comment: "", designInput: "none", humanVerify: "go check it"),
            (uuid: "c", title: "Neither", mtime: "1", comment: "", designInput: "none", humanVerify: "none"),
        ])
        let results = Set(MaintainerRequestScanner.scan(fossilPath: path).map(\.ticketUUID))
        XCTAssertEqual(results, ["a", "b"])
    }

    // MARK: - Seen-set diffing (MaintainerRequestStore.diff)

    private func request(_ uuid: String, mtime: String) -> MaintainerRequest {
        MaintainerRequest(ticketUUID: uuid, title: "t-\(uuid)", mtime: mtime, isMergeGate: false)
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
