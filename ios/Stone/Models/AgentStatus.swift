import Foundation

/// Whether the agent answering a thread is working, idle or stopped, as OCX
/// reports it at `<repo>/ext/ocx/status?thread=<root>` (the contract is in
/// docs/ocx-status-endpoint.md). Only OCX on the server knows this; the
/// synced thread itself can't tell a busy agent from a stopped one.
struct AgentStatus: Decodable, Equatable {
    enum State: String, Decodable {
        case working
        case idle
        case stopped
    }

    let login: String
    let state: State
    /// When the agent entered `state`, ISO 8601 (UTC). Optional: a status
    /// without it still shows, just without a time.
    let since: String?

    /// The line under the conversation title: "opus is working", "opus idle
    /// since 22:47", "opus stopped at 21:10".
    func label(timeZone: TimeZone = .current) -> String {
        let time = sinceDate.map { date -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        switch state {
        case .working: return "\(login) is working"
        case .idle: return time.map { "\(login) idle since \($0)" } ?? "\(login) is idle"
        case .stopped: return time.map { "\(login) stopped at \($0)" } ?? "\(login) stopped"
        }
    }

    var sinceDate: Date? {
        guard let since else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: since) ?? ISO8601DateFormatter().date(from: since)
    }

    /// Decodes a status response; nil for anything else (a 404 page, HTML,
    /// an unknown state), so an absent or older endpoint shows nothing.
    static func decode(_ data: Data) -> AgentStatus? {
        try? JSONDecoder().decode(AgentStatus.self, from: data)
    }
}
