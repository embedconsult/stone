import Foundation

/// Turn-lifecycle events parsed from the OC `:8443` live-events SSE stream
/// (docs/design/agent-client-scoping.md Gap 2.3). Named events per the
/// design doc; anything else decodes as `.other` so an event type this
/// client doesn't yet know about still shows up as "something happened"
/// instead of being dropped silently.
enum AgentTurnEvent: Equatable {
    case turnStarted(String)
    case turnHeartbeat(String)
    case turnFinished(String)
    case other(event: String, data: String)
}

/// Long-lived `text/event-stream` consumer for a session's live-events URL
/// (minted by `AgentSessionClient.liveEventsURL`, which carries the
/// per-project HMAC token -- no separate auth needed on the stream itself).
///
/// iOS has no first-class SSE API, so this parses `event:`/`data:` frames by
/// hand out of the response body's line stream, per the design doc's own
/// description of the mechanism (Gap 2.3). Reconnect/backoff and the
/// poll-on-offline fallback are the caller's job (view lifecycle owns them);
/// this type is deliberately just a dumb pipe plus a pure, testable parser.
enum AgentEventStream {
    /// Accumulates raw SSE lines into complete frames. Kept as its own value
    /// type, separate from the network I/O in `run(url:onEvent:)`, so the
    /// part that actually changes when the wire format is confirmed -- frame
    /// shape, field names -- is unit-testable without a live connection.
    struct FrameParser {
        private var eventName = "message"
        private var dataLines: [String] = []

        /// Feeds one line; returns a decoded event once `line` completes a
        /// frame (SSE's blank-line frame terminator), else `nil`.
        mutating func feed(_ line: String) -> AgentTurnEvent? {
            if line.isEmpty {
                guard !dataLines.isEmpty else { return nil }
                let event = AgentEventStream.parse(event: eventName, data: dataLines.joined(separator: "\n"))
                eventName = "message"
                dataLines = []
                return event
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
            // Other SSE fields (id:, retry:, ":" comments) are unused here.
            return nil
        }
    }

    static func parse(event: String, data: String) -> AgentTurnEvent {
        switch event {
        case "turn_started": return .turnStarted(data)
        case "turn_heartbeat": return .turnHeartbeat(data)
        case "turn_finished": return .turnFinished(data)
        default: return .other(event: event, data: data)
        }
    }

    /// Connects to `url` and invokes `onEvent` for each decoded event until
    /// the connection drops or throws. Deliberately runs entirely inside the
    /// *caller's* task rather than spawning a separate one internally: the
    /// caller cancelling its own task (e.g. a view tearing this down on
    /// disappear) then reliably cancels the underlying connection too, since
    /// `URLSession`'s async `bytes(for:)` observes its own task's
    /// cancellation directly. Routing through a second, internally-owned
    /// task (e.g. behind an `AsyncThrowingStream`) would decouple that
    /// cancellation from the caller's, leaving the connection dangling.
    static func run(url: URL, onEvent: (AgentTurnEvent) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        var parser = FrameParser()
        for try await line in bytes.lines {
            if let event = parser.feed(line) {
                onEvent(event)
            }
        }
    }
}
