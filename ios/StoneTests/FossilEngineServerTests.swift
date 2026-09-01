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
    /// Uses two real, freshly-`fossil init`'d repos in the sandbox's own
    /// temp directory (`NSTemporaryDirectory()`, not a hardcoded "/tmp" --
    /// that literal path is not guaranteed to be writable/valid inside an
    /// iOS app sandbox, simulator included) so the HTTP round-trip below
    /// exercises the same "serve a real repo" path the app actually uses.
    /// An earlier version of this test pointed at nonexistent repo files;
    /// on a real simulator Fossil's own handling of a missing repo can
    /// produce a response `URLSession` fails to parse (or none at all),
    /// which would fail this test for a reason that has nothing to do with
    /// the port/retarget fix being verified.
    func testRetargetingAnAlreadyRunningServerReportsARealWorkingPort() async throws {
        let engine = FossilEngine.shared
        let dir = NSTemporaryDirectory()
        let pathA = dir + "stone-test-repo-a-\(UUID().uuidString).fossil"
        let pathB = dir + "stone-test-repo-b-\(UUID().uuidString).fossil"

        for path in [pathA, pathB] {
            let result = await engine.run(["init", path])
            XCTAssertTrue(result.succeeded, "fossil init failed for \(path): \(result.output)")
        }

        let first = try await engine.startServer(repoPath: pathA)
        let second = try await engine.startServer(repoPath: pathB)

        XCTAssertEqual(first, second,
            "retargeting an already-running server must report the same real port, not silently fall back to an unset one")
        XCTAssertNotEqual(first.port, 0,
            "port 0 means stone_fossil_server_start's \"already running\" branch never wrote *out_port -- this is the exact bug")

        // Prove the port is actually connectable and speaking real HTTP, not
        // just nonzero. Any status code proves the TCP connection itself
        // succeeded, which is what "Could not connect to the server" was
        // about -- this isn't a check on Fossil's page content.
        var request = URLRequest(url: second)
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            XCTFail("expected an HTTP response from the loopback server -- a thrown \"cannot connect to host\" error, or a non-HTTP response, means the port bug is back")
            return
        }
        XCTAssertGreaterThan(http.statusCode, 0)
    }
}
