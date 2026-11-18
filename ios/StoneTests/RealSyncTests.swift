import XCTest
@testable import Stone

/// Real syncs over the network, through the app's own sync path
/// (RepoStore.cloneRepo, then RepoStore.sync), so a change to how Stone
/// connects is tried for real at build time.
///
/// Why: the sync relay (9438612e2c) passed every automatic check and still
/// broke every sync on the maintainer's phone, because no test sent a real
/// sync anywhere (maintainer, Nov 17 11:03 pm). The remote is stone-media on
/// ollama: public, anonymous pull, about 2 MB.
///
/// Needs the network. Runs inside the host app, so it uses its own
/// repository name and deletes it again.
@MainActor
final class RealSyncTests: XCTestCase {
    static let remote = "https://ollama.openbeagle.org/stone-media"

    private func cloneTestRepo(_ store: RepoStore) async throws -> Repo {
        let name = "real-sync-test-\(UUID().uuidString.prefix(8))"
        try await store.cloneRepo(named: name, remoteURL: Self.remote, password: nil)
        return try XCTUnwrap(store.repos.first { $0.name == name })
    }

    /// Fails when a sync can't reach the server, as every sync did under
    /// the relay.
    func testRealSyncReachesTheServer() async throws {
        let store = RepoStore()
        let repo = try await cloneTestRepo(store)
        defer { store.delete(repo) }

        let output = try await store.sync(repo, trigger: .syncAll)
        XCTAssertNil(RepoStore.detectConnectionFailure(output), output)
        guard case .success = RepoStore.status(forOutput: output) else {
            return XCTFail("a real sync did not succeed:\n\(output)")
        }
    }

    /// The other half: a sync that can't connect must come back as a
    /// failure, never as Synced (1ab5b0c9cb).
    func testUnreachableServerIsAFailedSync() async throws {
        let store = RepoStore()
        let cloned = try await cloneTestRepo(store)
        defer { store.delete(cloned) }
        // Nothing listens on port 9 here: the connection is refused.
        store.updateRemote(cloned, remoteURL: "https://127.0.0.1:9/stone-media", password: nil)
        let repo = try XCTUnwrap(store.repos.first { $0.id == cloned.id })

        do {
            let output = try await store.sync(repo, trigger: .syncAll)
            XCTFail("a refused connection came back as a finished sync:\n\(output)")
        } catch {
            if case .success = RepoStore.status(for: error) {
                XCTFail("a refused connection was recorded as Synced")
            }
        }
    }
}
