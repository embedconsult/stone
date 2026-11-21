import Foundation

/// A record of each time Stone stopped answering: the main thread didn't
/// run a small task within a second. Each entry says when it started, what
/// Stone had been doing just before (sync phases, conversation scans,
/// reloads, sends), and, when it ends, how long it lasted.
///
/// Why: the maintainer reported the app hanging, and the sync log can't
/// show it, because that log is written when a sync finishes, not while the
/// app hangs (stone forum aff1da83ce and 58ad319939, Nov 20). The watchdog
/// runs on its own thread and appends to a file the moment a hang passes a
/// second, so the entry is there even if the app is closed while hung.
///
/// It only watches while Stone is in front: a suspended app also stops
/// answering, and that isn't a hang.
final class HangLog: @unchecked Sendable {
    static let shared = HangLog()

    static let threshold: TimeInterval = 1
    private static let recentCount = 8
    private static let keptLines = 400

    private let lock = NSLock()
    private var recent: [String] = []
    private var watching = false
    /// Changes each time Stone comes to the front, so a check that spanned
    /// a suspension is never counted as a hang.
    private var generation = 0
    private var thread: Thread?

    private let fileURL: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("hang-log.txt")

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d h:mm:ss a"
        return f
    }()

    /// Notes what Stone is doing now. A hang's entry lists the last few.
    static func doing(_ what: String) {
        shared.note(what)
    }

    private func note(_ what: String) {
        let line = "\(Self.clock.string(from: Date())) \(what)"
        lock.lock(); defer { lock.unlock() }
        recent.append(line)
        if recent.count > Self.recentCount { recent.removeFirst(recent.count - Self.recentCount) }
    }

    /// Stone came to the front (true) or left it (false).
    func setWatching(_ on: Bool) {
        lock.lock()
        watching = on
        if on { generation += 1 }
        let needsThread = on && thread == nil
        lock.unlock()
        if needsThread { startThread() }
        note(on ? "came to the front" : "left the front")
    }

    /// The whole log, oldest first.
    func text() -> String {
        guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        return text
    }

    private func startThread() {
        trim()
        let t = Thread { [weak self] in self?.run() }
        t.name = "HangLog"
        t.qualityOfService = .userInitiated
        lock.lock(); thread = t; lock.unlock()
        t.start()
    }

    private func current() -> (watching: Bool, generation: Int, recent: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (watching, generation, recent)
    }

    private func run() {
        while true {
            let before = current()
            guard before.watching else {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let answered = DispatchSemaphore(value: 0)
            let sent = Date()
            DispatchQueue.main.async { answered.signal() }
            if answered.wait(timeout: .now() + Self.threshold) == .success {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let now = current()
            guard now.watching, now.generation == before.generation else {
                answered.wait()
                continue
            }
            append("\(Self.stamp.string(from: sent)): Stone stopped answering. Just before: "
                   + (now.recent.isEmpty ? "nothing noted" : now.recent.joined(separator: "; ")))
            answered.wait()
            let seconds = Date().timeIntervalSince(sent)
            append("\(Self.stamp.string(from: Date())): answering again after "
                   + String(format: "%.1f", seconds) + " s"
                   + (current().generation == before.generation ? "" : " (it had left the front meanwhile)"))
        }
    }

    private func append(_ line: String) {
        guard let fileURL, let data = (line + "\n").data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Keeps the newest lines only, so the file can't grow without bound.
    private func trim() {
        let lines = text().split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > Self.keptLines, let fileURL else { return }
        let kept = lines.suffix(Self.keptLines).joined(separator: "\n")
        try? kept.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
