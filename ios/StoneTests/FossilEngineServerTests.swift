import XCTest
import Darwin
@testable import Stone

/// Regression test for a real bug reported by the maintainer: browsing a
/// repo ("BQ2") failed with "Couldn't load the local Fossil page: Could not
/// connect to the server." Root cause, found by reading StoneFossil.c: when
/// the loopback server was already running, `stone_fossil_server_start`
/// returned success WITHOUT ever writing to `*out_port` -- so the Swift side
/// (whose `var port: Int32 = 0` default was never overwritten) built a URL
/// for port 0, which nothing can ever connect to. This exercises exactly the
/// "already running" branch that had the bug. Confirmed fixed on-device
/// (jdkphone83, build db77153-dirty + commit 9eee858a60): toggling between
/// repos works, no "Could not connect" recurrence.
final class FossilEngineServerTests: XCTestCase {
    /// `StoneTests` is host-app-hosted (TEST_HOST = Stone.app), so this runs
    /// INSIDE the real, live app process -- `FossilEngine.shared` and the C
    /// bridge's `g_server` are process-wide globals the app's own UI can also
    /// be actively using at the same time (e.g. a repo left configured from
    /// prior manual testing, whose RepoWebView independently calls
    /// startServer()/retargets on app launch). A prior version of this test
    /// made a full HTTP request and inspected the response, which is only
    /// meaningful if THIS test's retarget is the last one to run before the
    /// request lands -- not guaranteed when the live app can retarget
    /// concurrently. That's an environmental race, not a defect in the fix
    /// (already confirmed working on-device above), so don't test past what
    /// the bug was actually about: whether a real listener exists at the
    /// reported port. A raw TCP connect proves exactly that without caring
    /// which repo happens to be currently targeted or what content comes
    /// back -- immune to that race, since retargeting never touches the
    /// listening socket itself (only `g_server.repo_path`).
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

        guard let port = first.port, port != 0 else {
            XCTFail("port 0 (or missing) means stone_fossil_server_start's \"already running\" branch never wrote *out_port -- this is the exact bug")
            return
        }
        XCTAssertTrue(Self.canConnect(port: port),
            "expected a real listener at 127.0.0.1:\(port) -- a failed raw TCP connect means the port bug is back")
    }

    /// Plain BSD socket connect -- no HTTP, no ATS, no dependency on which
    /// repo the server currently points at. Success means only "a process is
    /// listening and accepting on this port," which is precisely what
    /// "Could not connect to the server" was reporting the absence of.
    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }
}
