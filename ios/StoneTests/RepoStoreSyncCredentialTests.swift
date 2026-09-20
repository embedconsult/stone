import XCTest
@testable import Stone

/// Regression tests for the silent-sync bug the maintainer found by hand:
/// "Sync complete" used to mean nothing more than "the round trip finished,"
/// even when a misconfigured remote (no username for a set password) meant
/// nothing was actually pushed. See Stone Plan ticket c4eb202ff0. Fixed on
/// trunk via `RepoStore.StoreError.passwordNeedsUsername` (credential
/// validation) and `RepoStore.parseArtifactCounts` (surfacing the real
/// sent/received counts instead of a blanket success).
///
/// These exercise `RepoStore.urlWithPassword` directly with explicit
/// password strings -- not via `CredentialStore`/the Keychain and not via a
/// real `sync()` network call. An earlier version of this file went through
/// `CredentialStore.setPassword` + `store.sync(repo)`, which depends on a
/// real Keychain write succeeding; that's not reliable for an unsigned test
/// build (mac-acceptance-test.sh runs with CODE_SIGNING_ALLOWED=NO), so a
/// silently-failed `SecItemAdd` left the password `nil`, `urlWithPassword`
/// never threw, and the test fell through to a real, doomed network request
/// to example.com instead -- reported as `.fossil("")`, not the credential
/// error this test is actually about. `urlWithPassword` is pure (no I/O), so
/// it doesn't need any of that.
final class RepoStoreSyncCredentialTests: XCTestCase {
    /// The exact bug: a password with no username in the remote's address
    /// must be rejected up front, not silently turned into a garbage
    /// empty-string-user credential that Fossil then syncs anonymously.
    func testPasswordWithoutUsernameInURLIsRejected() {
        XCTAssertThrowsError(
            try RepoStore.urlWithPassword("https://example.com/repo", password: "secret")
        ) { error in
            XCTAssertEqual(error as? RepoStore.StoreError, .passwordNeedsUsername)
        }
    }

    /// The fixed path: once a username IS present in the remote address, the
    /// password is accepted and embedded as the URL's userinfo.
    func testPasswordWithUsernameInURLIsAccepted() throws {
        let result = try RepoStore.urlWithPassword("https://alice@example.com/repo", password: "secret")
        XCTAssertEqual(result, "https://alice:secret@example.com/repo")
    }

    /// A remote with no password at all is intentionally anonymous -- no
    /// username is required to protect nothing, and the address must pass
    /// through unchanged.
    func testNoPasswordLeavesURLUnchangedAndDoesNotRequireUsername() throws {
        let result = try RepoStore.urlWithPassword("https://example.com/repo", password: nil)
        XCTAssertEqual(result, "https://example.com/repo")
    }

    func testEmptyPasswordStringIsTreatedTheSameAsNoPassword() throws {
        let result = try RepoStore.urlWithPassword("https://example.com/repo", password: "")
        XCTAssertEqual(result, "https://example.com/repo")
    }

    // MARK: - detectAuthFailure

    /// Ground truth (ticket 94ea2161f5): a stale/rotated remote password
    /// let `fossil sync` report a plausible "sent" count while the server
    /// silently refused the real push. This is the regression test for the
    /// fix -- these three phrasings are the actual signatures found in
    /// Fossil's own source (src/xfer.c) for the ways a rejected push shows
    /// up in sync's raw output.
    func testDetectAuthFailureRecognizesLoginFailed() {
        XCTAssertNotNil(RepoStore.detectAuthFailure("Error: login failed\n"))
    }

    func testDetectAuthFailureRecognizesNotAuthorized() {
        XCTAssertNotNil(RepoStore.detectAuthFailure("server says: not authorized to push\n"))
    }

    func testDetectAuthFailureRecognizesPullOnly() {
        XCTAssertNotNil(RepoStore.detectAuthFailure("pull only because ...\n"))
    }

    func testDetectAuthFailureReturnsNilForOrdinaryOutput() {
        XCTAssertNil(RepoStore.detectAuthFailure("Round-trips: 1   Artifacts sent: 3  received: 0\n"))
    }

    // MARK: - detectLocalSQLiteFailure (ticket f0c612c027)

    /// The exact bug: this LOCAL SQLite authorizer message contains "not
    /// authorized", which detectAuthFailure alone would misclassify as the
    /// server refusing the push. detectLocalSQLiteFailure must recognize it
    /// first.
    func testDetectLocalSQLiteFailureRecognizesSQLiteAuth() {
        let output = #"SQLITE_AUTH(23): not authorized in "DELETE FROM unsent""#
        let reason = RepoStore.detectLocalSQLiteFailure(output)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("DELETE FROM unsent") == true)
    }

    /// Not just SQLITE_AUTH -- any SQLite error surfaced in Fossil's
    /// "SQLITE_<NAME>(<code>): <msg>" formatting is equally a local failure.
    func testDetectLocalSQLiteFailureRecognizesOtherSQLiteCodes() {
        XCTAssertNotNil(RepoStore.detectLocalSQLiteFailure("SQLITE_BUSY(5): database is locked"))
        XCTAssertNotNil(RepoStore.detectLocalSQLiteFailure("SQLITE_CORRUPT(11): database disk image is malformed"))
    }

    func testDetectLocalSQLiteFailureReturnsNilForOrdinaryOutput() {
        XCTAssertNil(RepoStore.detectLocalSQLiteFailure("Round-trips: 1   Artifacts sent: 3  received: 0\n"))
    }

    func testDetectLocalSQLiteFailureReturnsNilForRealServerRefusal() {
        XCTAssertNil(RepoStore.detectLocalSQLiteFailure("server says: not authorized to push\n"))
    }

    /// The full regression: given the maintainer's actual sync log, a
    /// caller checking detectLocalSQLiteFailure first (as every call site
    /// must -- RepoStore.syncAll, RepoWebView.runSync) gets the local
    /// classification and never falls through to detectAuthFailure's
    /// "server refused" text.
    func testLocalSQLiteAuthErrorIsNeverReportedAsServerRefusal() {
        let output = #"SQLITE_AUTH(23): not authorized in "DELETE FROM unsent""#
        XCTAssertNotNil(RepoStore.detectLocalSQLiteFailure(output))
        // detectAuthFailure would (correctly, by design) still match this
        // text in isolation -- which is exactly why callers must check
        // detectLocalSQLiteFailure FIRST and only fall back to
        // detectAuthFailure when it returns nil.
        XCTAssertNotNil(RepoStore.detectAuthFailure(output))
    }

    // MARK: - parseArtifactCounts

    /// The other half of the fix: even once auth is correct, "the command
    /// exited 0" still isn't "something was pushed." This is what makes that
    /// distinction visible in the UI (RepoWebView's sync alert, syncAll's
    /// summary) instead of a blanket "Sync complete."
    func testParseArtifactCountsReadsFossilsSummaryLine() {
        let output = """
        Round-trips: 2   Artifacts sent: 3  received: 0
        """
        let counts = RepoStore.parseArtifactCounts(output)
        XCTAssertEqual(counts?.sent, 3)
        XCTAssertEqual(counts?.received, 0)
    }

    func testParseArtifactCountsReturnsNilWhenSummaryLineIsAbsent() {
        XCTAssertNil(RepoStore.parseArtifactCounts("some unrelated output\nwith no summary line"))
    }

    // MARK: - combinedRemoteURL / splitRemoteURL

    func testCombinedAndSplitRemoteURLRoundTrip() {
        let combined = RepoStore.combinedRemoteURL(host: "https://example.com/repo", username: "alice")
        XCTAssertEqual(combined, "https://alice@example.com/repo")

        let split = RepoStore.splitRemoteURL(combined)
        XCTAssertEqual(split.host, "https://example.com/repo")
        XCTAssertEqual(split.username, "alice")
    }

    func testCombinedRemoteURLWithEmptyUsernameLeavesHostUnchanged() {
        XCTAssertEqual(RepoStore.combinedRemoteURL(host: "https://example.com/repo", username: "  "),
                       "https://example.com/repo")
    }

    // MARK: - indicatesMissingTicketColumn (ticket d4d02c604f)

    /// The exact ticket 11018cb484 case: sync's crosslinker fails to write
    /// an incoming ticket change because this clone's local TICKET table
    /// doesn't have a column the change names -- Fossil surfaces this as a
    /// plain SQLite "no such column" error.
    func testIndicatesMissingTicketColumnRecognizesSQLiteError() {
        XCTAssertTrue(RepoStore.indicatesMissingTicketColumn("SQLITE_ERROR: no such column: foo\n"))
    }

    func testIndicatesMissingTicketColumnIsCaseInsensitive() {
        XCTAssertTrue(RepoStore.indicatesMissingTicketColumn("Error: No Such Column: foo"))
    }

    func testIndicatesMissingTicketColumnReturnsFalseForOrdinaryOutput() {
        XCTAssertFalse(RepoStore.indicatesMissingTicketColumn("Round-trips: 1   Artifacts sent: 3  received: 0\n"))
    }

    // MARK: - isConfigPullDue

    func testConfigPullIsDueWhenNeverPulledBefore() {
        XCTAssertTrue(RepoStore.isConfigPullDue(lastPullAt: nil))
    }

    func testConfigPullIsNotDueLessThanADayAfterLastPull() {
        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-2 * 60 * 60)
        XCTAssertFalse(RepoStore.isConfigPullDue(lastPullAt: twoHoursAgo, now: now))
    }

    func testConfigPullIsDueAfterMoreThanADay() {
        let now = Date()
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 60 * 60)
        XCTAssertTrue(RepoStore.isConfigPullDue(lastPullAt: twoDaysAgo, now: now))
    }

    func testConfigPullIsDueAtExactlyTheMinimumInterval() {
        let now = Date()
        let exactlyADayAgo = now.addingTimeInterval(-RepoStore.configPullMinInterval)
        XCTAssertTrue(RepoStore.isConfigPullDue(lastPullAt: exactlyADayAgo, now: now))
    }

    // MARK: - appendPhaseTimings

    /// The maintainer's ask: every sync's log should say where the time
    /// went, not just whether it succeeded.
    func testAppendPhaseTimingsIncludesAllThreePhases() {
        let annotated = RepoStore.appendPhaseTimings(
            to: "Round-trips: 1   Artifacts sent: 0  received: 0",
            ticketConfigPullSeconds: 1.5,
            syncSeconds: 0.25,
            skinPullSeconds: nil
        )
        XCTAssertTrue(annotated.contains("Round-trips: 1"))
        XCTAssertTrue(annotated.contains("ticket-config pull 1.50s"))
        XCTAssertTrue(annotated.contains("sync 0.25s"))
        XCTAssertTrue(annotated.contains("skin pull skipped"))
    }

    func testAppendPhaseTimingsMarksSkippedPhasesAsNil() {
        let annotated = RepoStore.appendPhaseTimings(
            to: "ok",
            ticketConfigPullSeconds: nil,
            syncSeconds: 0.1,
            skinPullSeconds: nil
        )
        XCTAssertTrue(annotated.contains("ticket-config pull skipped"))
        XCTAssertTrue(annotated.contains("skin pull skipped"))
    }
}
