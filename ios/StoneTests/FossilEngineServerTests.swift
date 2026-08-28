import XCTest
@testable import Stone

/// Regression test for a real bug reported by the maintainer: browsing a
/// repo ("BQ2") failed with "Couldn't load the local Fossil page: Could not
/// connect to the server." Root cause, found by reading StoneFossil.c: when
/// the loopback server was already running, `stone_fossil_server_start`
/// returned success WITHOUT ever writing to `*out_port` -- so the Swift side
/// (whose `var port: Int32 = 0` default was never overwritten) built a URL
/// for port 0, which nothing can ever connect to. This exercises exactly the
/// "already running" branch that had the bug.
final class FossilEngineServerTests: XCTestCase {
    /// Note: FossilEngine's loopback server binds/listens before it ever
    /// touches repo content, so a nonexistent repo path is fine here -- this
    /// test is about the socket/port bookkeeping, not Fossil's own request
    /// handling.
    func testRetargetingAnAlreadyRunningServerReportsARealWorkingPort() async throws {
        let engine = FossilEngine.shared

        let first = try await engine.startServer(repoPath: "/tmp/stone-test-repo-a.fossil")
        let second = try await engine.startServer(repoPath: "/tmp/stone-test-repo-b.fossil")

        XCTAssertEqual(first, second,
            "retargeting an already-running server must report the same real port, not silently fall back to an unset one")
        XCTAssertNotEqual(first.port, 0,
            "port 0 means stone_fossil_server_start's \"already running\" branch never wrote *out_port -- this is the exact bug")

        // Prove the port is actually connectable, not just nonzero.
        var request = URLRequest(url: first)
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertNotNil(response as? HTTPURLResponse,
            "expected an HTTP response from the loopback server -- a thrown \"cannot connect to host\" error here means the port bug is back")
    }
}
