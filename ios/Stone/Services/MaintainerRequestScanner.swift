import Foundation

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
    var isDecision: Bool = true
    /// True when this row matched on `human_verify`, not `design_input`.
    var isTryThis: Bool = false

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
    /// `design_input`/`human_verify` are custom ticket fields this project's
    /// own Fossil repos are configured with (RepoStore.pullTicketConfig
    /// pulls that schema into every local clone) -- NOT part of Fossil's
    /// stock ticket table. A repo whose remote never configured them simply
    /// won't have the columns; that is not an error, it is "this repo has
    /// nothing to report" (per the ticket: "Repos without the design_input
    /// column simply contribute nothing").
    static func scan(fossilPath: String) -> [MaintainerRequest] {
        let columns = Set(queryRows(fossilPath, "PRAGMA table_info(ticket)").map { $0[1] })
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
        let designInputIndex: Int? = hasDesignInput ? 4 : nil
        let humanVerifyIndex: Int? = hasHumanVerify ? (hasDesignInput ? 5 : 4) : nil

        let sql = """
        SELECT tkt_uuid, title, tkt_mtime, comment\(hasDesignInput ? ", design_input" : "")\(hasHumanVerify ? ", human_verify" : "")
        FROM ticket
        WHERE \(predicates.joined(separator: " OR "))
        """

        var results: [MaintainerRequest] = []
        for row in queryRows(fossilPath, sql) {
            let uuid = row[0]
            guard !uuid.isEmpty else { continue }
            let title = row[1]
            let mtime = row[2]
            let comment = row[3]
            let designInput = designInputIndex.map { row[$0] } ?? ""
            let humanVerify = humanVerifyIndex.map { row[$0] } ?? ""
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

    /// Runs `sql` against `fossilPath` through `stone_fossil_query` and
    /// splits its result encoding (rows separated by the ASCII Record
    /// Separator, columns within a row by the ASCII Unit Separator -- never
    /// '\n'/'\t', since ticket text can legitimately contain either) into
    /// `[[String]]`. Empty array on any failure (missing file, bad SQL,
    /// unreadable, no design_input/human_verify support) -- matches this
    /// scanner's existing "nothing to report" behavior for absent/
    /// incompatible repos.
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
