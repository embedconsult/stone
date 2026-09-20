import Foundation
import SQLite3

/// One thing in a repo's ticket table the maintainer needs to look at:
/// either a decision (`design_input = 'confirm'`, which includes the
/// OCX-MERGE-GATE merge-card case) or a "try this" (`human_verify` set to
/// anything other than empty/`none`). See MaintainerRequestScanner's doc for
/// where these come from.
struct MaintainerRequest: Identifiable, Equatable {
    var id: String { ticketUUID }
    let ticketUUID: String
    let title: String
    /// Fossil's `tkt_mtime`, kept as the raw SQLite text form (an ISO-ish
    /// julian/date string) rather than parsed into a `Date` -- it is only
    /// ever compared for equality against a previously-seen value
    /// (MaintainerRequestStore), never displayed or arithmetic'd on, so
    /// there is nothing parsing would buy and something it could lose
    /// (SQLite's date functions aren't perfectly round-trip stable across
    /// representations).
    let mtime: String
    let isMergeGate: Bool
    /// True when this row matched `design_input = 'confirm'` (a subset of
    /// which is `isMergeGate`). Defaulted so existing call sites/tests that
    /// only care about the merge-gate distinction don't need updating.
    let isDecision: Bool = true
    /// True when this row matched on `human_verify`, not `design_input`.
    let isTryThis: Bool = false

    /// Ticket 4c75227cc7: the Requests screen groups rows by this, one of
    /// "decision" (design_input=confirm), "merge card" (that plus an
    /// OCX-MERGE-GATE comment), or "try-this" (human_verify). Merge card
    /// takes priority over plain decision since it's the narrower, more
    /// specific case; a row can't otherwise be both a decision and a
    /// try-this at once in practice, but if the data somehow says so,
    /// decision wins (it's the one requiring resolution to close the ticket).
    enum Kind: Equatable {
        case mergeCard
        case decision
        case tryThis

        var displayName: String {
            switch self {
            case .mergeCard: return "Merge card"
            case .decision: return "Decision"
            case .tryThis: return "Try this"
            }
        }

        var systemImage: String {
            switch self {
            case .mergeCard: return "arrow.triangle.merge"
            case .decision: return "questionmark.circle"
            case .tryThis: return "checkmark.seal"
            }
        }
    }

    var kind: Kind {
        if isMergeGate { return .mergeCard }
        if isDecision { return .decision }
        return .tryThis
    }
}

/// Scans a Fossil repository's local `.fossil` file for open maintainer
/// requests, straight from the SQLite file on disk.
///
/// Deliberately does NOT go through `FossilEngine`/`stone_fossil_run`: the
/// only Fossil CLI command that can run an arbitrary read query (`fossil
/// sql`) hands off to the vendored sqlite3 command-line shell, whose
/// argument/stdin handling is not something `StoneFossil.c`'s one-shot,
/// stdin-unredirected `invoke_fossil` can drive safely -- a query passed as
/// a bare positional argument is indistinguishable, to that shell, from a
/// database *filename* to open (see sqlcmd.c's `cmd_sqlite3`: `-R`'s value
/// is stripped from argv before the remaining positional argument reaches
/// the sqlite3 shell), and a query passed via stdin would need a real pipe
/// this bridge doesn't wire up. Either way risks the single process-wide
/// Fossil lock (StoneFossil.c's `g_fossil_lock`) being held by something
/// waiting on input that will never arrive -- exactly the "wedged"
/// FossilEngine failure mode this unit's ticket warns against.
///
/// A `.fossil` file is a plain SQLite database, so a second, independent,
/// read-only `sqlite3_open_v2` connection (via the system libsqlite3, a
/// different library instance than the one statically linked inside
/// FossilCore.xcframework) is both simpler and safe: SQLite supports
/// concurrent readers against one file, and `SQLITE_OPEN_READONLY` here
/// never takes a write lock that could contend with the embedded server or
/// a sync in progress.
enum MaintainerRequestScanner {
    /// `design_input`/`human_verify` are custom ticket fields this project's
    /// own Fossil repos are configured with (RepoStore.pullTicketConfig
    /// pulls that schema into every local clone) -- NOT part of Fossil's
    /// stock ticket table. A repo whose remote never configured them simply
    /// won't have the columns; that is not an error, it is "this repo has
    /// nothing to report" (per the ticket: "Repos without the design_input
    /// column simply contribute nothing").
    static func scan(fossilPath: String) -> [MaintainerRequest] {
        var db: OpaquePointer?
        // Immutable + read-only: this must never block on, or contend
        // with, a write lock the embedded Fossil engine or an in-flight
        // sync might be holding.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(fossilPath, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let columns = Set(tableColumns(db, table: "ticket"))
        let hasDesignInput = columns.contains("design_input")
        let hasHumanVerify = columns.contains("human_verify")
        guard hasDesignInput || hasHumanVerify else { return [] }

        var predicates: [String] = []
        if hasDesignInput { predicates.append("design_input = 'confirm'") }
        if hasHumanVerify {
            predicates.append("(human_verify IS NOT NULL AND human_verify <> '' AND human_verify <> 'none')")
        }

        // Optional columns are appended in this fixed order, so their result
        // indices are computed once here rather than re-derived per row.
        let designInputIndex: Int32? = hasDesignInput ? 4 : nil
        let humanVerifyIndex: Int32? = hasHumanVerify ? (hasDesignInput ? 5 : 4) : nil

        let sql = """
        SELECT tkt_uuid, title, tkt_mtime, comment\(hasDesignInput ? ", design_input" : "")\(hasHumanVerify ? ", human_verify" : "")
        FROM ticket
        WHERE \(predicates.joined(separator: " OR "))
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var results: [MaintainerRequest] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = text(stmt, 0)
            guard !uuid.isEmpty else { continue }
            let title = text(stmt, 1)
            let mtime = text(stmt, 2)
            let comment = text(stmt, 3)
            let designInput = designInputIndex.map { text(stmt, $0) } ?? ""
            let humanVerify = humanVerifyIndex.map { text(stmt, $0) } ?? ""
            let isDecision = hasDesignInput && designInput == "confirm"
            let isMergeGate = isDecision && comment.contains("OCX-MERGE-GATE")
            let isTryThis = hasHumanVerify && !humanVerify.isEmpty && humanVerify != "none"
            results.append(MaintainerRequest(
                ticketUUID: uuid,
                title: title.isEmpty ? "(untitled ticket)" : title,
                mtime: mtime,
                isMergeGate: isMergeGate,
                isDecision: isDecision,
                isTryThis: isTryThis))
        }
        return results
    }

    /// Read-only existence check for a single ticket uuid, on the same
    /// second-connection discipline as `scan` above -- used by `TicketOpener`
    /// (ticket 98c06fb7a7) to verify a deep link's target actually exists in
    /// this clone before routing a WebView to it, since Fossil renders an
    /// empty ticket page rather than erroring when it doesn't.
    static func hasTicket(fossilPath: String, uuid: String) -> Bool {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(fossilPath, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM ticket WHERE tkt_uuid = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return false }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self) // SQLITE_TRANSIENT
        sqlite3_bind_text(stmt, 1, uuid, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func tableColumns(_ db: OpaquePointer, table: String) -> [String] {
        var stmt: OpaquePointer?
        // `table` is always the literal "ticket" from this file -- never
        // caller/user input -- so string interpolation into PRAGMA (which
        // does not accept bound parameters for identifiers) is safe here.
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.append(text(stmt, 1)) // column 1 of table_info is "name"
        }
        return names
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}
