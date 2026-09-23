import Foundation

/// Read-only SQL against a repo's `.fossil` file through
/// `stone_fossil_query` -- Fossil's own bundled SQLite, never a second SQLite
/// library in the process (ticket f0c612c027; see MaintainerRequestScanner's
/// doc for why that matters).
enum FossilQuery {
    /// Runs `sql` and splits the bridge's encoding (rows separated by the
    /// ASCII Record Separator, columns by the ASCII Unit Separator -- never
    /// '\n'/'\t', since post and comment text can contain either) into
    /// `[[String]]`. Empty on any failure: a missing file, bad SQL, or a table
    /// this clone doesn't have all read as "nothing here".
    static func rows(_ fossilPath: String, _ sql: String) -> [[String]] {
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

    /// Column names of `table`, empty when the table doesn't exist.
    static func columns(_ fossilPath: String, table: String) -> Set<String> {
        Set(rows(fossilPath, "PRAGMA table_info(\(table))").compactMap { $0.count > 1 ? $0[1] : nil })
    }

    /// `value` as a single-quoted SQL literal. The bridge offers no bound
    /// parameters, so anything interpolated goes through here.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
