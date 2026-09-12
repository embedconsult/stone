import XCTest
@testable import Stone

/// Coverage for the Gap 2 (Sessions/thread UI + composer + SSE status,
/// ticket cd9d4bfcb2) pure-logic pieces: JSON decoding against the settled
/// `session_posts` contract (docs/design/agent-client-scoping.md) and the
/// hand-rolled SSE frame parser. Both are exercised directly, without a live
/// connection, since the network calls themselves need a real
/// `ollama.openbeagle.org` session to test end to end.
final class AgentSessionTests: XCTestCase {
    // MARK: - session_posts decoding

    func testDecodesThreadPostsResponse() throws {
        let json = """
        {
            "ok": true,
            "posts": [
                {"hash": "abc123", "user": "jkridner", "mtime": "2026-09-12T09:00:00Z", "role": "human", "html": "<p>Fix the thing</p>"},
                {"hash": "def456", "user": "runner", "mtime": "2026-09-12T09:05:00Z", "role": "agent", "html": "<p>Done.</p>"}
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AgentThreadPostsResponse.self, from: json)

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.posts.count, 2)
        XCTAssertEqual(decoded.posts[0].hash, "abc123")
        XCTAssertEqual(decoded.posts[0].role, "human")
        XCTAssertEqual(decoded.posts[1].role, "agent")
    }

    // MARK: - Speculative sessions-list decoding

    func testDecodesSessionsResponse() throws {
        let json = """
        {
            "ok": true,
            "sessions": [
                {"root": "abc123", "title": "Fix the widget", "status": "active", "last_activity": "2026-09-12T09:05:00Z"},
                {"root": "def456", "title": "Refactor auth", "status": "idle", "last_activity": null}
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AgentSessionsResponse.self, from: json)

        XCTAssertEqual(decoded.sessions.count, 2)
        XCTAssertEqual(decoded.sessions[0].root, "abc123")
        XCTAssertEqual(decoded.sessions[0].lastActivity, "2026-09-12T09:05:00Z")
        XCTAssertNil(decoded.sessions[1].lastActivity)
    }

    // MARK: - SSE frame parsing

    func testFrameParserDecodesNamedTurnEvents() {
        var parser = AgentEventStream.FrameParser()

        XCTAssertNil(parser.feed("event: turn_started"))
        XCTAssertNil(parser.feed("data: {\"turn\": 1}"))
        XCTAssertEqual(parser.feed(""), .turnStarted("{\"turn\": 1}"))

        XCTAssertNil(parser.feed("event: turn_heartbeat"))
        XCTAssertNil(parser.feed("data: still working"))
        XCTAssertEqual(parser.feed(""), .turnHeartbeat("still working"))

        XCTAssertNil(parser.feed("event: turn_finished"))
        XCTAssertNil(parser.feed("data: ok"))
        XCTAssertEqual(parser.feed(""), .turnFinished("ok"))
    }

    func testFrameParserJoinsMultiLineData() {
        var parser = AgentEventStream.FrameParser()

        XCTAssertNil(parser.feed("event: turn_heartbeat"))
        XCTAssertNil(parser.feed("data: line one"))
        XCTAssertNil(parser.feed("data: line two"))
        XCTAssertEqual(parser.feed(""), .turnHeartbeat("line one\nline two"))
    }

    func testFrameParserDefaultsUnnamedEventsToOther() {
        var parser = AgentEventStream.FrameParser()

        XCTAssertNil(parser.feed("data: hello"))
        XCTAssertEqual(parser.feed(""), .other(event: "message", data: "hello"))
    }

    func testFrameParserIgnoresBlankLineWithNoPendingData() {
        var parser = AgentEventStream.FrameParser()

        XCTAssertNil(parser.feed(""))
        XCTAssertNil(parser.feed("event: turn_started"))
        XCTAssertNil(parser.feed(""))
    }

    func testParseUnknownEventNameBecomesOther() {
        let event = AgentEventStream.parse(event: "something_new", data: "payload")
        XCTAssertEqual(event, .other(event: "something_new", data: "payload"))
    }
}
