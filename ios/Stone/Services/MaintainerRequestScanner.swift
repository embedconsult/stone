import Foundation
import SQLite3

/// One thing in a repo's ticket table the maintainer needs to look at, per
/// the server-synced `needs_you` custom ticket field (ollama ticket
/// a6fb296ac3). See MaintainerRequestScanner's doc for how that field
/// reaches this clone.
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
    let kind: Kind

    /// Ticket 98c06fb7a7: the console -- not this phone -- decides who needs
    /// to act, and writes that verdict into one synced `needs_you` ticket
    /// field with five possible values: `decision`, `merge`, `try-this`,
    /// `coordinator`, `none`. Only the first three ever produce a row here;
    /// `coordinator` (a merge delegated away from the maintainer) and `none`
    /// never notify -- see `Kind.init(needsYouValue:)`. There is deliberately
    /// no local re-derivation from `design_input`/`human_verify` anymore:
    /// this field alone is the source of truth, so this phone can never show
    /// a card the console itself no longer shows.
    enum Kind: Equatable {
        case mergeCard
        case decision
        case tryThis

        /// `nil` for any value that must never notify (`coordinator`,
        /// `none`, or anything unrecognized) -- callers drop the row
        /// entirely rather than guessing a kind for it.
        init?(needsYouValue: String) {
            switch needsYouValue {
            case "merge": self = .mergeCard
            case "decision": self = .decision
            case "try-this": self = .tryThis
            default: return nil
            }
        }

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
    /// `needs_you` is a custom ticket field this project's own Fossil repos
    /// are configured with (RepoStore.pullTicketConfig pulls that schema
    /// into every local clone, and an ordinary ticket sync brings each
    /// ticket's current value in) -- NOT part of Fossil's stock ticket
    /// table, and NOT derived here from any other field. A repo whose
    /// remote never configured it simply won't have the column; that is not
    /// an error, it is "this repo has nothing to report".
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
        guard columns.contains("needs_you") else { return [] }

        let sql = """
        SELECT tkt_uuid, title, tkt_mtime, needs_you
        FROM ticket
        WHERE needs_you IN ('decision', 'merge', 'try-this')
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var results: [MaintainerRequest] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = text(stmt, 0)
            // The WHERE clause above already excludes `coordinator`/`none`/
            // anything else, but `Kind.init?` is the actual gate a delegated
            // merge card never notifies through -- belt and suspenders
            // against a future change to this SQL.
            guard !uuid.isEmpty, let kind = MaintainerRequest.Kind(needsYouValue: text(stmt, 3)) else { continue }
            let title = text(stmt, 1)
            let mtime = text(stmt, 2)
            results.append(MaintainerRequest(
                ticketUUID: uuid,
                title: title.isEmpty ? "(untitled ticket)" : title,
                mtime: mtime,
                kind: kind))
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
