import XCTest
@testable import Stone

/// The pure rules behind the conversations screens (Models/Conversation.swift):
/// composing artifacts Fossil accepts, reading them back, assembling threads,
/// and the unread/notification bookkeeping.
final class ConversationTests: XCTestCase {
    private let thread = "e320232451a750cd3fb527cfb0930f01bd85b50622ca21a97751c8aa3f86f49e"
    private let replyTo = "23206426577fb3bb111c28cac57a03d39ae8f8eeadd4a9b44e20a83fd90fd91b"
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Composing

    /// The expected text, checksum included, is what `fossil bundle import`
    /// accepted and crosslinked as a reply in this thread when checked
    /// against a copy of the stone repo with Fossil 2.27.
    func testForumReplyMatchesAnArtifactFossilAccepted() {
        let artifact = ConversationArtifact.forumReply(
            thread: thread, inReplyTo: replyTo, user: "opus",
            body: "Two lines\nwith ünïcode and a \\ backslash", date: date)
        XCTAssertEqual(artifact, """
        D 2026-09-21T14:13:20.000
        G \(thread)
        I \(replyTo)
        N text/x-markdown
        U opus
        W 42
        Two lines
        with ünïcode and a \\ backslash
        Z df3318cfb2a098548691f2a29b9324a6

        """)
    }

    /// Likewise checked with `fossil bundle import`: it landed in
    /// `ticketchng` as a markdown comment by opus, newlines and double
    /// spaces intact.
    func testTicketCommentMatchesAnArtifactFossilAccepted() {
        let artifact = ConversationArtifact.ticketComment(
            ticket: "207fe6ff87913d1822fe9839a4c9dbd4d9b58a84", user: "opus",
            comment: "phone reply\n\nsecond para with  spaces", date: date)
        XCTAssertEqual(artifact, """
        D 2026-09-21T14:13:20.000
        J +icomment phone\\sreply\\n\\nsecond\\spara\\swith\\s\\sspaces
        J login opus
        J mimetype text/x-markdown
        K 207fe6ff87913d1822fe9839a4c9dbd4d9b58a84
        U opus
        Z f96dab5bcfaf9dcc8cc592a053860fd3

        """)
    }

    func testMD5KnownVectors() {
        XCTAssertEqual(MD5.hex([]), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hex(Array("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hex(Array("The quick brown fox jumps over the lazy dog".utf8)),
                       "9e107d9d372bb6826bd81d3542a419d6")
        XCTAssertEqual(MD5.hex(Array(String(repeating: "x", count: 200).utf8)),
                       "30a83621ce5422fbdfdd539777458c78")
    }

    func testFossilizeRoundTrips() {
        let text = "a b\tc\nd\\e\r"
        XCTAssertEqual(Fossilize.encode(text), "a\\sb\\tc\\nd\\\\e\\r")
        XCTAssertEqual(Fossilize.decode(Fossilize.encode(text)), text)
    }

    // MARK: Reading

    func testArtifactReadsBackWhatWasComposed() {
        let body = "First line\n\nW 3 inside the body is not a card"
        let artifact = FossilArtifact(text: ConversationArtifact.forumReply(
            thread: thread, inReplyTo: replyTo, user: "jane doe", body: body, date: date))
        XCTAssertEqual(artifact.wiki, body)
        XCTAssertEqual(artifact.first("G"), thread)
        XCTAssertEqual(artifact.first("I"), replyTo)
        XCTAssertEqual(artifact.first("U"), "jane doe")
        XCTAssertEqual(artifact.first("N"), "text/x-markdown")
        XCTAssertNotNil(artifact.first("Z"))
    }

    func testQuestionShapedPostOffersItsOptions() {
        let body = """
        Question: Which write path should Stone use?

        References:

        - [PLAN.md](https://example.org/doc/ocx/PLAN.md)

        Options:

        - **Bundle import** (recommended)
        - Bridge call
        2. Web form

        Stakes: something.

        For: jkridner, @opus
        """
        XCTAssertEqual(PostText.options(body), ["**Bundle import** (recommended)", "Bridge call", "Web form"])
        XCTAssertEqual(PostText.forLogins(body), ["jkridner", "opus"])
        XCTAssertEqual(PostText.preview(body), "Question: Which write path should Stone use?")
    }

    func testEmphasisedHeadingsAndNamesOnTheirOwnLine() {
        let body = "**Question:** Pick one\n\n**Options:**\n1) A\n2) B\n\n**For:**\n\nopus"
        XCTAssertEqual(PostText.options(body), ["A", "B"])
        XCTAssertEqual(PostText.forLogins(body), ["opus"])
    }

    /// Tolerant reader: an ordinary post has no options and names no one,
    /// and an `Options:` list without a question is not a question.
    func testOrdinaryPostsHaveNoOptions() {
        XCTAssertEqual(PostText.options("Is this session live?"), [])
        XCTAssertEqual(PostText.options("Options:\n- a\n- b"), [])
        XCTAssertEqual(PostText.forLogins("Is this session live?"), [])
    }

    // MARK: Threads

    func testThreadsKeepOrderAcrossEditsAndDropDeletions() {
        let rows = [
            row(1, root: 1, mtime: 1, user: "opus", comment: "Post: Stone chat"),
            row(2, root: 1, irt: 1, mtime: 2, user: "ec2-user", comment: "Reply: Stone chat"),
            row(3, root: 1, irt: 1, mtime: 3, user: "stone", comment: "Reply: Stone chat"),
            // 4 edits 2 later on: it keeps 2's place.
            row(4, root: 1, prev: 2, irt: 1, mtime: 5, user: "ec2-user", comment: "Edit reply: Stone chat"),
            // 5 deletes 3.
            row(5, root: 1, prev: 3, irt: 1, mtime: 6, user: "stone", comment: "Delete reply: Stone chat"),
            row(6, root: 6, mtime: 4, user: "fable", comment: "Post: Another thread"),
        ]
        let threads = ForumThreads.assemble(rows).sorted { $0.rootHash < $1.rootHash }
        XCTAssertEqual(threads.count, 2)
        let chat = threads[0]
        XCTAssertEqual(chat.title, "Stone chat")
        XCTAssertEqual(chat.posts.map(\.hash), ["h1", "h4"])
        XCTAssertEqual(chat.posts[1].mtime, 2)
        XCTAssertEqual(chat.posts[1].inReplyTo, "h1")
        XCTAssertEqual(threads[1].title, "Another thread")
    }

    // MARK: Unread and notifications

    func testUnreadCountsOnlyOthersPostsAfterTheMarker() {
        let posts = [post("a", "opus", 1), post("b", "stone", 2), post("c", "opus", 3), post("d", "opus", 4)]
        XCTAssertEqual(ConversationBook.unread(posts, login: "stone", lastRead: 2), 2)
        XCTAssertEqual(ConversationBook.unread(posts, login: "Stone", lastRead: 0), 3)
        XCTAssertEqual(ConversationBook.unread(posts, login: "stone", lastRead: 4), 0)
    }

    func testNotificationsDedupeByHashAndNeverFloodOnFirstScan() {
        let posts = [post("a", "opus", 1), post("b", "stone", 2), post("c", "opus", 3)]
        XCTAssertEqual(ConversationBook.newForNotification(posts, login: "stone", notified: nil), [])
        XCTAssertEqual(ConversationBook.newForNotification(posts, login: "stone", notified: ["a"]).map(\.hash), ["c"])
        XCTAssertEqual(ConversationBook.newForNotification(posts, login: "stone", notified: ["a", "c"]), [])
    }

    func testTakingPartMeansPostingOrBeingNamed() {
        let posts = [post("a", "opus", 1)]
        XCTAssertTrue(ConversationBook.participates(posts: posts, login: "opus", latestBody: nil))
        XCTAssertFalse(ConversationBook.participates(posts: posts, login: "stone", latestBody: "hello"))
        XCTAssertTrue(ConversationBook.participates(posts: posts, login: "stone", latestBody: "Question: x\n\nFor: stone"))
        XCTAssertFalse(ConversationBook.participates(posts: posts, login: "", latestBody: "For: "))
    }

    // MARK: Helpers

    private func row(_ rid: Int, root: Int, prev: Int = 0, irt: Int = 0, mtime: Double,
                     user: String, comment: String) -> ForumPostRow {
        ForumPostRow(rid: rid, rootRid: root, previousRid: prev, inReplyToRid: irt, mtime: mtime,
                     hash: "h\(rid)", user: user, comment: comment)
    }

    private func post(_ hash: String, _ author: String, _ mtime: Double) -> ConversationPost {
        ConversationPost(hash: hash, author: author, mtime: mtime, body: nil, mimetype: "", inReplyTo: nil)
    }
}

/// A session's status, read from its thread (AgentStatus.read), in both
/// protocols' shapes, and its steps from chat.
final class AgentStatusTests: XCTestCase {
    private let run = "6fe3e69bd7897f7f5d685a347bbf5e393938d994aa3950e1ebd9ca5b801e396e"

    private func message(_ json: String) -> String { "```json\n\(json)\n```" }

    private func post(_ hash: String, _ author: String, _ mtime: Double, _ body: String) -> ConversationPost {
        ConversationPost(hash: hash, author: author, mtime: mtime, body: body, mimetype: "text/x-markdown", inReplyTo: nil)
    }

    private var runPost: ConversationPost {
        post(run, "ec2-user", 1, message(#"{"ocx":2,"to":"x86-1","run":{"objective":"Fix it"}}"#))
    }

    private func started(by author: String = "x86-1", re: String? = nil) -> ConversationPost {
        post("s", author, 2, message(#"{"ocx":2,"re":"\#(re ?? run)","started":{"values":{"process_user":"run-fb38bc18"}}}"#))
    }

    func testNotASession() {
        XCTAssertNil(AgentStatus.read([post("a", "stone", 1, "Hello")]))
        XCTAssertNil(AgentStatus.read([]))
    }

    func testWaitingUntilItsNodeStartsIt() {
        XCTAssertEqual(AgentStatus.read([runPost])?.state, .waiting)
        // A started from anyone but the node, or for another run, doesn't count.
        XCTAssertEqual(AgentStatus.read([runPost, started(by: "mallory")])?.state, .waiting)
        XCTAssertEqual(AgentStatus.read([runPost, started(re: "0000")])?.state, .waiting)
    }

    func testTurns() {
        let working = AgentStatus.read([runPost, started()])
        XCTAssertEqual(working?.state, .working)
        XCTAssertEqual(working?.login, "run-fb38bc18")
        let answered = [runPost, started(), post("p", "run-fb38bc18", 3, "Done; merge?")]
        XCTAssertEqual(AgentStatus.read(answered)?.state, .yourTurn)
        XCTAssertEqual(AgentStatus.read(answered + [post("q", "stone", 4, "yes")])?.state, .working)
    }

    func testEnded() {
        let ended = post("e", "x86-1", 5, message(#"{"ocx":2,"re":"\#(run)","ended":{"outcome":"exited","exit":0}}"#))
        let status = AgentStatus.read([runPost, started(), ended, post("r", "stone", 6, "thanks")])
        XCTAssertEqual(status?.state, .ended(outcome: "exited"))
        XCTAssertEqual(status?.login, "run-fb38bc18")
    }

    func testProtocolOne() {
        let root = post(run, "ec2-user", 1, message(#"{"ocx":1,"kind":"run","node":"x86-1","objective":"x"}"#))
        let started = post("s", "x86-1", 2, message(#"{"ocx":1,"kind":"started","node":"x86-1","run":"\#(run)","values":{"user":"x86-1-stone"}}"#))
        let ended = post("e", "x86-1", 3, message(#"{"ocx":1,"kind":"ended","node":"x86-1","run":"\#(run)","outcome":"stopped"}"#))
        XCTAssertEqual(AgentStatus.read([root, started])?.login, "x86-1-stone")
        XCTAssertEqual(AgentStatus.read([root, started, ended])?.state, .ended(outcome: "stopped"))
    }

    /// Some projects carry `run` as a string (a run's hash): not a run.
    func testOtherShapesAreNotMessages() {
        XCTAssertNil(OCXMessage(message(#"{"ocx":2,"re":"abc","run":"abc"}"#)))
        XCTAssertNil(OCXMessage("```json\n{\"run\":{}}\n```"))
        XCTAssertNil(OCXMessage("A block that isn't last:\n```json\n{\"ocx\":2,\"run\":{}}\n```\nThen words."))
    }

    /// A question as `ocx2 post --for --options --stakes` writes it (ocx-console
    /// forum 7186524c37): words for people, then the message.
    private let questionPost = """
    **Question for ec2-user:** Should it start with this console?

    1. Yes, this console first *(recommended)*
    2. Not until I'm back

    ```json
    {
      "ocx": 2,
      "to": "ec2-user",
      "question": {
        "question": "Should it start with this console?",
        "options": ["Yes, this console first", "Not until I'm back"],
        "stakes": "Which program you can next update"
      }
    }
    ```
    """

    func testReadsAQuestion() throws {
        let question = try XCTUnwrap(OCXMessage(questionPost))
        XCTAssertEqual(question.kind, "question")
        XCTAssertEqual(question.to, "ec2-user")
        XCTAssertEqual(question.options.first, "Yes, this console first")
        XCTAssertEqual(question.said, "**Question for ec2-user:** Should it start with this console?\n\n1. Yes, this console first *(recommended)*\n2. Not until I'm back")
    }

    /// A decision is written in its question's shape, and read back as one.
    func testDecisionRoundTrips() throws {
        let question = try XCTUnwrap(OCXMessage(questionPost))
        let body = question.decision(on: run, note: "Yes, this console first")
        XCTAssertTrue(body.hasPrefix("**Decision:** Yes, this console first\n\n```json\n"))
        let decision = try XCTUnwrap(OCXMessage(body))
        XCTAssertEqual(decision.kind, "decision")
        XCTAssertEqual(decision.version, 2)
        XCTAssertEqual(decision.re, run)
        XCTAssertEqual(decision.note, "Yes, this console first")
        let posts = [post(run, "run-194d2a3d", 1, questionPost), post("d", "stone", 2, body)]
        XCTAssertEqual(OCXMessage.decided(in: posts), [run])

        let old = try XCTUnwrap(OCXMessage(message(#"{"ocx":1,"kind":"question","for":"stone","question":"Merge?","options":["Yes","No"]}"#)))
        let oldDecision = try XCTUnwrap(OCXMessage(old.decision(on: run, note: "Yes")))
        XCTAssertEqual(oldDecision.version, 1)
        XCTAssertEqual(oldDecision.re, run)
        // An early decision was a `response`.
        XCTAssertEqual(OCXMessage(message(#"{"ocx":1,"kind":"response","question":"abc","note":"No"}"#))?.kind, "decision")
    }

    func testBlockOnlyPostsSayALine() {
        XCTAssertEqual(OCXMessage(started().body ?? "")?.said, "*The session started.*")
        XCTAssertEqual(OCXMessage(runPost.body ?? "")?.said, "Fix it")
    }

    func testAQuestionForYouIsYours() {
        XCTAssertTrue(ConversationBook.participates(posts: [post("q", "run-194d2a3d", 1, questionPost)],
                                                    login: "ec2-user", latestBody: questionPost))
        XCTAssertFalse(ConversationBook.participates(posts: [post("q", "run-194d2a3d", 1, questionPost)],
                                                     login: "stone", latestBody: questionPost))
    }

    func testChatPollKeepsEveryLineWithItsSender() throws {
        let json = """
        {"msgs":[{"msgid":7,"mtime":"2026-11-05T12:00:00Z","xfrom":"run-fb38bc18","xmsg":"Reading src/main.cr"},
                 {"msgid":8,"mtime":"2026-11-05T12:00:02Z","xfrom":"TIMELINE","xmsg":"Forum post"}]}
        """
        let answer = try XCTUnwrap(ChatPollAnswer.parse(Data(json.utf8)))
        XCTAssertEqual(answer.lastID, 8)
        XCTAssertEqual(answer.rows, 2)
        XCTAssertEqual(answer.lines.map(\.login), ["run-fb38bc18", "TIMELINE"])
        XCTAssertEqual(answer.lines.first?.text, "Reading src/main.cr")
    }
}
