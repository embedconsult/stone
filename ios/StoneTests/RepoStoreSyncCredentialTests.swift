import XCTest
@testable import Stone

/// Regression tests for the silent-sync bug the maintainer found by hand:
/// "Sync complete" used to mean nothing more than "the round trip finished,"
/// even when a misconfigured remote (no username for a set password) meant
/// nothing was actually pushed. See Stone Plan ticket c4eb202ff0. Fixed on
/// trunk via `RepoStore.StoreError.passwordNeedsUsername` (credential
/// validation) and `RepoStore.parseArtifactCounts` (surfacing the real
/// sent/received counts instead of a blanket success).
@MainActor
final class RepoStoreSyncCredentialTests: XCTestCase {
    private var store: RepoStore!
    private var repo: Repo!

    override func setUp() {
        super.setUp()
        store = RepoStore()
        repo = Repo(name: "sync-credential-test",
                    fileName: "sync-credential-test-\(UUID().uuidString).fossil")
    }

    override func tearDown() {
        CredentialStore.delete(for: repo.id)
        super.tearDown()
    }

    /// The exact bug: a password with no username in the remote's address
    /// must be rejected up front, not silently turned into a garbage
    /// empty-string-user credential that Fossil then syncs anonymously.
    func testPasswordWithoutUsernameInURLIsRejected() async {
        repo.remoteURL = "https://example.com/repo"
        CredentialStore.setPassword("secret", for: repo.id)

        do {
            _ = try await store.sync(repo)
            XCTFail("expected sync to reject a password with no username in the remote address")
        } catch RepoStore.StoreError.passwordNeedsUsername {
            // expected
        } catch {
            XCTFail("expected .passwordNeedsUsername, got \(error)")
        }
    }

    /// The fixed path: once a username IS present in the remote address, the
    /// credential is accepted by validation and sync proceeds to actually
    /// attempt the network round trip. Nothing is listening on this loopback
    /// port, so the round trip itself fails -- that failure is expected and
    /// is a DIFFERENT error; this test only proves credential validation no
    /// longer misclassifies a present username as missing.
    func testPasswordWithUsernameInURLIsAccepted() async {
        repo.remoteURL = "http://alice@127.0.0.1:1/repo"
        CredentialStore.setPassword("secret", for: repo.id)

        do {
            _ = try await store.sync(repo)
            XCTFail("expected sync to fail against an address nothing is listening on")
        } catch RepoStore.StoreError.passwordNeedsUsername {
            XCTFail("a username IS present in the address -- this must not be reported as missing")
        } catch {
            // any other failure (connection refused, invalid repo path, etc.)
            // is expected here and is not what this test checks.
        }
    }

    /// A remote with no password at all is intentionally anonymous -- no
    /// username is required to protect nothing, and cloning/syncing must not
    /// be blocked by this validation in that case.
    func testNoPasswordDoesNotRequireUsername() async {
        repo.remoteURL = "http://127.0.0.1:1/repo"
        // No CredentialStore password set.

        do {
            _ = try await store.sync(repo)
            XCTFail("expected sync to fail against an address nothing is listening on")
        } catch RepoStore.StoreError.passwordNeedsUsername {
            XCTFail("no password was configured -- this must never be reported as missing a username")
        } catch {
            // expected: a plain connection failure, not a credential complaint.
        }
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
