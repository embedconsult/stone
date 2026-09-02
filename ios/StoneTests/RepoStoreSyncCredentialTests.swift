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
}
