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

    /// One console card's answer, as JSON text, from `stone_fossil_card`
    /// over `repos`; nil when the definition isn't a card or a repository
    /// can't be read. The meaning is all in the bridge, which Linux checks
    /// against OCX's shared examples (scripts/linux-cards-driver.c).
    static func card(_ repos: [String], name: String, definition: String,
                     viewer: String, now: String) -> String? {
        guard !repos.isEmpty else { return nil }
        let cStrings: [UnsafeMutablePointer<CChar>?] = repos.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var outPtr: UnsafeMutablePointer<CChar>?
        let rc = cStrings.withUnsafeBufferPointer { buf -> Int32 in
            let base = UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            return stone_fossil_card(base, Int32(repos.count), name, definition, viewer, now, &outPtr)
        }
        defer { if let outPtr { free(outPtr) } }
        guard rc == 0, let outPtr else { return nil }
        return String(cString: outPtr)
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
