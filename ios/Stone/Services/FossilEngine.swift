import Foundation

/// Thin, readable Swift face over the `StoneFossil` C bridge.
///
/// Single responsibility: turn Swift calls into Fossil invocations and back,
/// off the main thread. It owns no policy about repositories or UI — it only
/// runs commands and manages the lifetime of the loopback web server.
///
/// The underlying C bridge serializes everything internally, so the engine is
/// safe to call from anywhere; the dedicated queue keeps callers off the main
/// thread and gives us clean `async` ergonomics.
actor FossilEngine {
    static let shared = FossilEngine()

    /// The port the loopback server is currently listening on, if running.
    private(set) var serverPort: Int?

    /// Result of a one-shot Fossil command.
    struct CommandResult {
        let exitCode: Int32
        let output: String
        var succeeded: Bool { exitCode == 0 }
    }

    /// Run a Fossil command (without the leading "fossil"), capturing output.
    /// Example: `run(["clone", url, path])`.
    func run(_ args: [String]) -> CommandResult {
        withCArgv(args) { argc, argv in
            var outPtr: UnsafeMutablePointer<CChar>? = nil
            let code = stone_fossil_run(argc, argv, &outPtr)
            let text = outPtr.map { String(cString: $0) } ?? ""
            if let p = outPtr { free(p) }
            return CommandResult(exitCode: code, output: text)
        }
    }

    /// Start the IPv4 loopback web server for the given repository file, or —
    /// if it is already running — retarget it at this repo (same port).
    /// Returns the base URL the WebView should load.
    func startServer(repoPath: String) throws -> URL {
        if let port = serverPort {
            let rc = repoPath.withCString { stone_fossil_server_set_repo($0) }
            if rc == 0, let url = URL(string: "http://127.0.0.1:\(port)/") {
                return url
            }
            // The C-side accept loop can die on its own -- e.g. fd exhaustion
            // under the burst of concurrent connections a large repo's page
            // can open -- without this side finding out until the next
            // attempt to use it. Left alone, every later repo would also hit
            // this same failing retarget path forever, since serverPort never
            // gets corrected: the app would stay wedged for the rest of the
            // session. Forget the stale port and fall through to start a
            // fresh listener instead.
            serverPort = nil
        }
        var port: Int32 = 0
        let rc = repoPath.withCString { stone_fossil_server_start($0, &port) }
        guard rc == 0, let url = URL(string: "http://127.0.0.1:\(port)/") else {
            throw EngineError.serverFailed
        }
        serverPort = Int(port)
        return url
    }

    func stopServer() {
        stone_fossil_server_stop()
        serverPort = nil
    }

    /// Set the identity Fossil attributes clone/commit/sync operations to.
    func setUser(_ user: String) {
        user.withCString { stone_fossil_set_user($0) }
    }

    /// Point Fossil/OpenSSL at a CA bundle (PEM) for verifying https remotes.
    func setCACertificate(path: String) {
        path.withCString { stone_fossil_set_ca_file($0) }
    }

    /// Give Fossil a writable home for its global config DB (~/.fossil). On iOS
    /// the system HOME is the read-only sandbox container root, so we point
    /// FOSSIL_HOME at a writable directory instead.
    func setHome(path: String) {
        path.withCString { stone_fossil_set_home($0) }
    }

    enum EngineError: LocalizedError {
        case serverFailed

        var errorDescription: String? {
            switch self {
            case .serverFailed:
                return "Could not start the local Fossil server (failed to bind a loopback socket). Restarting the app usually clears this."
            }
        }
    }

    // MARK: - C argv marshaling

    /// Convert `[String]` into a C `argv` (NULL-terminated) for the duration of
    /// `body`, freeing all allocations afterward.
    private func withCArgv<R>(_ args: [String],
                              _ body: (Int32, UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        var cStrings: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cStrings.append(nil)
        defer { for p in cStrings where p != nil { free(p) } }
        return cStrings.withUnsafeBufferPointer { buf in
            let base = UnsafeRawPointer(buf.baseAddress!)
                .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            return body(Int32(args.count), base)
        }
    }
}
