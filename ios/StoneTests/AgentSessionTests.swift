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

    // MARK: - sessions.json decoding

    func testDecodesSessionsResponse() throws {
        let json = """
        {
            "ok": true,
            "sessions": [
                {"root_hash": "abc123", "runner_id": "r1", "runner_login": "runner-bot", "runner_type": "codex", "resume_id": "res1", "state": "active", "pending_posts": 0, "last_post": "def000", "last_post_author": "jkridner", "last_post_at": "2026-09-12T09:05:00Z", "workspace": "/tmp/w1"},
                {"root_hash": "def456", "runner_id": null, "runner_login": null, "runner_type": null, "resume_id": null, "state": "idle", "pending_posts": 1, "last_post": null, "last_post_author": null, "last_post_at": null, "workspace": null}
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AgentSessionsResponse.self, from: json)

        XCTAssertEqual(decoded.sessions.count, 2)
        XCTAssertEqual(decoded.sessions[0].root, "abc123")
        XCTAssertEqual(decoded.sessions[0].state, "active")
        XCTAssertEqual(decoded.sessions[0].lastActivity, "2026-09-12T09:05:00Z")
        XCTAssertEqual(decoded.sessions[0].title, "runner-bot · abc123")
        XCTAssertNil(decoded.sessions[1].lastActivity)
        XCTAssertEqual(decoded.sessions[1].title, "def456")
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

    // MARK: - AgentThreadView.plainText(fromHTML:)

    /// Regression coverage for the string-conversion half of ticket
    /// 9626caf291's fix. The actual crash (a TestFlight SIGABRT, App Store
    /// Connect crash AGyIBIjJ62ZvfowyfSXovyU) was calling this synchronously
    /// from inside AgentThreadView's List row closure, not a bug in the
    /// conversion logic itself -- that half isn't unit-testable (it needs a
    /// real SwiftUI/AttributeGraph view hierarchy to reproduce), so the fix
    /// there is structural: the call moved to loadPosts(), see that
    /// function's and plainText(fromHTML:)'s doc comments. This just guards
    /// the conversion itself doesn't regress separately.
    func testPlainTextStripsHTMLTags() {
        XCTAssertEqual(AgentThreadView.plainText(fromHTML: "<p>Fix the thing</p>"), "Fix the thing")
    }

    func testPlainTextHandlesEmptyString() {
        XCTAssertEqual(AgentThreadView.plainText(fromHTML: ""), "")
    }
}
