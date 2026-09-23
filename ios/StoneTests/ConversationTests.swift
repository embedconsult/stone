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
