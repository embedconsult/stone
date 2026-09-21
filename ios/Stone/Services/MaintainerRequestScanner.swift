import Foundation

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
    /// The `human_verify` custom field's current text, when the repo's
    /// remote configures that column -- the try-this instructions
    /// themselves, e.g. "Build 27, tap the Sync button twice." `nil` for a
    /// repo without the column, an empty value, or any kind other than
    /// `.tryThis` (nothing reads it otherwise). Carried on every request
    /// (not just try-this ones) so `MaintainerRequestScanner.scan`'s query
    /// shape doesn't have to branch per row.
    let humanVerify: String? = nil
    /// First line of the most recent ticket comment that isn't one of this
    /// project's own machine-generated `OCX-`-prefixed status blocks (see
    /// this ticket's own history for what those look like) -- used for a
    /// `.decision` notification's body, so it can ask the actual question
    /// rather than just naming its kind. `nil` when there's no such comment,
    /// or for any kind other than `.decision`.
    let latestCommentSummary: String? = nil

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

        /// Inverse of `init?(needsYouValue:)` -- round-trips a `Kind` back
        /// into the server's own `needs_you` vocabulary. Used to carry the
        /// kind through a local notification's `userInfo` dictionary
        /// (NotificationManager), which can only hold plist-safe types, not
        /// this enum itself.
        var needsYouValue: String {
            switch self {
            case .mergeCard: return "merge"
            case .decision: return "decision"
            case .tryThis: return "try-this"
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
/// Deliberately does NOT go through `FossilEngine.run`/`stone_fossil_run`
/// with a `fossil sql` command: the only Fossil CLI command that can run an
/// arbitrary read query hands off to the vendored sqlite3 command-line
/// shell, whose argument/stdin handling is not something `StoneFossil.c`'s
/// one-shot, stdin-unredirected `invoke_fossil` can drive safely -- a query
/// passed as a bare positional argument is indistinguishable, to that shell,
/// from a database *filename* to open (see sqlcmd.c's `cmd_sqlite3`: `-R`'s
/// value is stripped from argv before the remaining positional argument
/// reaches the sqlite3 shell), and a query passed via stdin would need a
/// real pipe this bridge doesn't wire up. Either way risks the single
/// process-wide Fossil lock (StoneFossil.c's `g_fossil_lock`) being held by
/// something waiting on input that will never arrive -- exactly the
/// "wedged" FossilEngine failure mode this unit's ticket warns against.
///
/// Instead, this goes through `stone_fossil_query` (ticket f0c612c027): a
/// small dedicated bridge entry point that opens the `.fossil` file
/// read-only using Fossil's OWN bundled SQLite -- the same library instance
/// `fossil_main()` itself uses. An earlier version of this scanner opened a
/// second, independent connection directly via iOS's system `libsqlite3`,
/// reasoning that two SQLite connections to one file are fine for
/// concurrent readers -- true in general, but not when they come from two
/// *different* SQLite library instances in the same process: Fossil's own
/// authorizer/protection state and the scanner's connection crossed wires,
/// and the first write Fossil attempted after a sync (its post-sync
/// `DELETE FROM unsent` cleanup) was refused with SQLITE_AUTH. Routing
/// through the bridge keeps exactly one SQLite in the process.
enum MaintainerRequestScanner {
    /// `needs_you` is a custom ticket field this project's own Fossil repos
    /// are configured with (RepoStore.pullTicketConfig pulls that schema
    /// into every local clone, and an ordinary ticket sync brings each
    /// ticket's current value in) -- NOT part of Fossil's stock ticket
    /// table, and NOT derived here from any other field. A repo whose
    /// remote never configured it simply won't have the column; that is not
    /// an error, it is "this repo has nothing to report".
    static func scan(fossilPath: String) -> [MaintainerRequest] {
        let columns = Set(queryRows(fossilPath, "PRAGMA table_info(ticket)").map { $0[1] })
        guard columns.contains("needs_you") else { return [] }
        let hasHumanVerify = columns.contains("human_verify")

        var selectColumns = ["tkt_uuid", "title", "tkt_mtime", "needs_you"]
        if hasHumanVerify { selectColumns.append("human_verify") }

        let sql = """
        SELECT \(selectColumns.joined(separator: ", "))
        FROM ticket
        WHERE needs_you IN ('decision', 'merge', 'try-this')
        """

        var results: [MaintainerRequest] = []
        for row in queryRows(fossilPath, sql) {
            let uuid = row[0]
            // The WHERE clause above already excludes `coordinator`/`none`/
            // anything else, but `Kind.init?` is the actual gate a delegated
            // merge card never notifies through -- belt and suspenders
            // against a future change to this SQL.
            guard !uuid.isEmpty, let kind = MaintainerRequest.Kind(needsYouValue: row[3]) else { continue }
            let title = row[1]
            let mtime = row[2]
            let humanVerify: String? = (hasHumanVerify && row.count > 4 && !row[4].isEmpty) ? row[4] : nil
            // Only a `.decision` notification's body ever reads this --
            // skip the extra ticketchng query for the other two kinds.
            let latestCommentSummary = kind == .decision ? latestNonOCXComment(fossilPath, uuid: uuid) : nil
            results.append(MaintainerRequest(
                ticketUUID: uuid,
                title: title.isEmpty ? "(untitled ticket)" : title,
                mtime: mtime,
                kind: kind,
                humanVerify: humanVerify,
                latestCommentSummary: latestCommentSummary))
        }
        return results
    }

    /// First line of the most recent comment on `uuid` that isn't one of
    /// this project's own `OCX-`-prefixed machine status blocks (see
    /// MaintainerRequest.latestCommentSummary's doc) -- feeds a `.decision`
    /// notification's body with the actual question rather than just
    /// "Decision". Fossil's ticket-change history lives in `ticketchng`, a
    /// separate table from `ticket` itself; a repo whose clone predates that
    /// table (shouldn't happen for a real Fossil repo, but this goes through
    /// the same failure-tolerant `queryRows` as everything else here) simply
    /// yields no summary rather than an error.
    private static func latestNonOCXComment(_ fossilPath: String, uuid: String) -> String? {
        let escaped = uuid.replacingOccurrences(of: "'", with: "''")
        let sql = """
        SELECT icomment FROM ticketchng
        WHERE tkt_uuid = '\(escaped)' AND icomment IS NOT NULL AND icomment != ''
        ORDER BY tkt_mtime DESC
        """
        for row in queryRows(fossilPath, sql) {
            guard let raw = row.first else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("OCX-") else { continue }
            let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return String(firstLine)
        }
        return nil
    }

    /// Read-only existence check for a single ticket uuid, through the same
    /// `stone_fossil_query` bridge as `scan` above -- used by `TicketOpener`
    /// (ticket 98c06fb7a7) to verify a deep link's target actually exists in
    /// this clone before routing a WebView to it, since Fossil renders an
    /// empty ticket page rather than erroring when it doesn't.
    static func hasTicket(fossilPath: String, uuid: String) -> Bool {
        // uuid always comes from the server's Needs-you list (TicketOpener),
        // never free-form user input, but it is still interpolated into the
        // query text below (stone_fossil_query has no bound-parameter
        // support), so a stray quote in it must not become a SQL break-out.
        let escaped = uuid.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT 1 FROM ticket WHERE tkt_uuid = '\(escaped)' LIMIT 1"
        return !queryRows(fossilPath, sql).isEmpty
    }

    /// Runs `sql` against `fossilPath` through `stone_fossil_query` and
    /// splits its result encoding (rows separated by the ASCII Record
    /// Separator, columns within a row by the ASCII Unit Separator -- never
    /// '\n'/'\t', since ticket text can legitimately contain either) into
    /// `[[String]]`. Empty array on any failure (missing file, bad SQL,
    /// unreadable, no `needs_you` column) -- matches this scanner's
    /// existing "nothing to report" behavior for absent/incompatible repos.
    private static func queryRows(_ fossilPath: String, _ sql: String) -> [[String]] {
        var outPtr: UnsafeMutablePointer<CChar>?
        let rc = fossilPath.withCString { pathC in
            sql.withCString { sqlC in
                stone_fossil_query(pathC, sqlC, &outPtr)
            }
        }
        defer { if let outPtr { free(outPtr) } }
        guard rc == 0, let outPtr else { return [] }
        let text = String(cString: outPtr)
        guard !text.isEmpty else { return [] }
        return text.split(separator: "\u{1E}").map {
            $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        }
    }
}
