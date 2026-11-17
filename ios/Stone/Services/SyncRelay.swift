import Foundation
import Network

/// A small HTTPS tunnel on 127.0.0.1 that Stone's syncs go through
/// (`fossil sync --proxy`), so a server connection that goes quiet is closed
/// after `idleLimit` instead of holding Fossil forever.
///
/// Why: Fossil 2.26's client has no time limit on a connection, and Stone
/// runs one Fossil command at a time. A sync on a connection that died
/// without closing (a Wi-Fi handoff, a lock) held that turn for minutes,
/// and Send waited behind it (maintainer's hang, ocx-console 31d624b3d5).
/// Fossil itself stays unchanged: `--proxy` with an https remote sends a
/// plain CONNECT, then TLS runs end to end through this tunnel, which only
/// copies bytes and watches the clock.
final class SyncRelay: @unchecked Sendable {
    static let shared = SyncRelay()

    /// No byte either way for this long ends the tunnel. A slow but moving
    /// sync is never cut: every byte resets the clock.
    static let idleLimit: TimeInterval = 60

    private let queue = DispatchQueue(label: "SyncRelay")
    private var listener: NWListener?
    private var port: UInt16?
    private var waiting: [(UInt16?) -> Void] = []

    /// `--proxy` arguments for a sync of `remote`, starting the relay if
    /// needed. Empty, so the sync goes direct as before, when the remote
    /// isn't https or the relay can't listen.
    func proxyArguments(for remote: String) async -> [String] {
        guard remote.lowercased().hasPrefix("https://") else { return [] }
        let port: UInt16? = await withCheckedContinuation { done in
            queue.async { self.start { done.resume(returning: $0) } }
        }
        guard let port else { return [] }
        return ["--proxy", "http://127.0.0.1:\(port)"]
    }

    // MARK: Listening (on `queue`)

    private func start(_ done: @escaping (UInt16?) -> Void) {
        if let port, listener?.state == .ready { return done(port) }
        waiting.append(done)
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return finish(nil) }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue
                self.finish(self.port)
            case .failed, .cancelled:
                // iOS can take the socket while the app is suspended: the
                // next sync starts a fresh listener.
                listener.cancel()
                if self.listener === listener { self.listener = nil; self.port = nil }
                self.finish(nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] client in self?.accept(client) }
        listener.start(queue: queue)
    }

    private func finish(_ port: UInt16?) {
        let calls = waiting
        waiting = []
        calls.forEach { $0(port) }
    }

    // MARK: One tunnel (on `queue`)

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        Tunnel(client: client, queue: queue).readRequest()
    }
}

/// One CONNECT: read the request line, open the server, answer 200, then
/// copy bytes both ways until either side ends or `idleLimit` passes quietly.
/// Before the 200, every way out answers with a status first: Fossil reads
/// the CONNECT reply until a blank line and would spin on a bare close.
private final class Tunnel: @unchecked Sendable {
    let client: NWConnection
    let queue: DispatchQueue
    var server: NWConnection?
    var header = Data()
    var established = false
    var closed = false
    var refused = false
    var lastActivity = Date()
    var timer: DispatchSourceTimer?

    init(client: NWConnection, queue: DispatchQueue) {
        self.client = client
        self.queue = queue
    }

    func readRequest() {
        startClock()
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, isComplete, error in
            if let data { header.append(data); lastActivity = Date() }
            guard let end = header.range(of: Data("\r\n\r\n".utf8)) else {
                if error != nil || isComplete || header.count > 16384 { return refuse("400 Bad Request") }
                return readRequest()
            }
            let line = String(decoding: header[..<end.lowerBound], as: UTF8.self)
                .split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "CONNECT" else { return refuse("405 Method Not Allowed") }
            let target = parts[1]
            guard let colon = target.lastIndex(of: ":"),
                  let number = UInt16(target[target.index(after: colon)...]),
                  let port = NWEndpoint.Port(rawValue: number) else {
                return refuse("400 Bad Request")
            }
            let host = String(target[..<colon])
            let early = header[end.upperBound...]
            connect(host: host, port: port, early: Data(early))
        }
    }

    private func connect(host: String, port: NWEndpoint.Port, early: Data) {
        let server = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.server = server
        server.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard !established, !closed else { return }
                established = true
                lastActivity = Date()
                let ok = Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8)
                client.send(content: ok, completion: .contentProcessed { [self] error in
                    if error != nil { return close() }
                    if !early.isEmpty { server.send(content: early, completion: .idempotent) }
                    pump(from: client, to: server)
                    pump(from: server, to: client)
                })
            case .failed, .waiting:
                // .waiting: no route right now. Fail at once rather than
                // let Fossil sit until the network comes back.
                if established { close() } else { refuse("502 Bad Gateway") }
            default:
                break
            }
        }
        server.start(queue: queue)
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if closed { return }
            if let data, !data.isEmpty {
                lastActivity = Date()
                sink.send(content: data, completion: .contentProcessed { [self] error in
                    if error != nil { return close() }
                    if isComplete { return close() }
                    pump(from: source, to: sink)
                })
                return
            }
            if error != nil || isComplete { return close() }
            pump(from: source, to: sink)
        }
    }

    private func startClock() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [self] in
            guard Date().timeIntervalSince(lastActivity) > SyncRelay.idleLimit else { return }
            if established { close() } else { refuse("504 Gateway Timeout") }
        }
        timer.resume()
        self.timer = timer
    }

    /// Answers the CONNECT with `status`, then closes.
    private func refuse(_ status: String) {
        guard !closed, !refused else { return }
        refused = true
        client.send(content: Data("HTTP/1.1 \(status)\r\n\r\n".utf8), completion: .contentProcessed { [self] _ in
            close()
        })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        server?.cancel()
        client.cancel()
    }
}
