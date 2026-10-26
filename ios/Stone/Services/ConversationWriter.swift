import Foundation

/// Writes a reply into the repo's local clone as an ordinary Fossil artifact,
/// so it works offline and the next sync pushes it like anything else.
///
/// Fossil has no command-line verb for posting to the forum, so the artifact
/// is composed here (ConversationArtifact, per Fossil's file format) and
/// stored with two stock commands: `fossil bundle append` wraps the file into
/// a bundle, and `fossil bundle import --publish` stores it, crosslinks it
/// into the forum/ticket tables, and makes it public so sync sends it.
/// `--force` is needed only because a bundle built by `append` carries no
/// project code to match. Ticket replies go the same way, so both kinds of
/// reply share one path and one failure mode.
enum ConversationWriter {
    enum WriteError: LocalizedError {
        case emptyBody
        case fossil(String)

        var errorDescription: String? {
            switch self {
            case .emptyBody: return "Nothing to send."
            case .fossil(let output): return "Couldn't save the reply in this phone's clone: \(output)"
            }
        }
    }

    /// Replies in `conversation`. For a thread, the reply answers `target`
    /// (or, with no target, the latest post). A ticket has no reply-to link,
    /// so replying to an earlier comment quotes its first line instead.
    static func reply(in conversation: ConversationID, to target: ConversationPost?,
                      latest: ConversationPost, login: String, body: String,
                      fossilPath: String) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WriteError.emptyBody }
        let artifact: String
        switch conversation.kind {
        case .thread:
            artifact = ConversationArtifact.forumReply(
                thread: conversation.key, inReplyTo: (target ?? latest).hash, user: login, body: trimmed)
        case .ticket:
            var comment = trimmed
            if let target, target.hash != latest.hash {
                comment = "> \(target.author): \(PostText.preview(target.body ?? ""))\n\n" + trimmed
            }
            artifact = ConversationArtifact.ticketComment(ticket: conversation.key, user: login, comment: comment)
        }
        try await store(artifact, fossilPath: fossilPath)
    }

    static func store(_ artifact: String, fossilPath: String) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("reply.txt")
        let bundle = dir.appendingPathComponent("reply.bundle")
        try Data(artifact.utf8).write(to: file)

        let engine = FossilEngine.shared
        let append = await engine.run(["bundle", "append", bundle.path, file.path, "-R", fossilPath])
        guard append.succeeded else { throw WriteError.fossil(append.output) }
        let imported = await engine.run(["bundle", "import", bundle.path, "-R", fossilPath, "--publish", "--force"])
        guard imported.succeeded else { throw WriteError.fossil(imported.output) }
    }
}

/// Screenshots for replies: a forum post can't hold an image, so the picture
/// becomes a Fossil attachment on the repo's "Screenshots" wiki page (created
/// the first time), and the reply shows it from `../raw/HASH`. All stock
/// commands on the local clone, so it works offline and the next sync sends
/// it: `wiki create`, `attachment add`, both with `-U LOGIN` as the author.
extension ConversationWriter {
    static let screenshotsPage = "Screenshots"

    /// Attaches `data` and returns the Markdown that shows it, for the reply.
    static func attachScreenshot(_ data: Data, fileExtension: String, mimeType: String,
                                 login: String, fossilPath: String) async throws -> String {
        let engine = FossilEngine.shared
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let name = "screenshot-\(stamp.replacingOccurrences(of: "T", with: "-")).\(fileExtension)"
        let file = dir.appendingPathComponent(name)
        try data.write(to: file)

        // -U needs the login in this clone's own user table; a clone made
        // under another login may not have it. Adding it is local only:
        // the user table doesn't sync.
        let hasUser = FossilQuery.rows(fossilPath, "SELECT 1 FROM user WHERE login = \(FossilQuery.quote(login))")
        if hasUser.isEmpty {
            let made = await engine.run(["user", "new", login, "", UUID().uuidString, "-R", fossilPath])
            guard made.succeeded else { throw WriteError.fossil(made.output) }
        }

        let page = FossilQuery.rows(fossilPath, "SELECT 1 FROM tag WHERE tagname = \(FossilQuery.quote("wiki-" + screenshotsPage))")
        if page.isEmpty {
            let text = dir.appendingPathComponent("page.md")
            try "Screenshots attached to replies from Stone. Each one is linked from the post it was sent with.\n"
                .write(to: text, atomically: true, encoding: .utf8)
            let created = await engine.run(["wiki", "create", screenshotsPage, text.path,
                                             "--mimetype", "text/x-markdown", "-U", login, "-R", fossilPath])
            guard created.succeeded else { throw WriteError.fossil(created.output) }
        }

        let attached = await engine.run(["attachment", "add", screenshotsPage, file.path, "-U", login, "-R", fossilPath])
        guard attached.succeeded else { throw WriteError.fossil(attached.output) }

        let rows = FossilQuery.rows(fossilPath, """
            SELECT src FROM attachment WHERE target = \(FossilQuery.quote(screenshotsPage))
            AND filename = \(FossilQuery.quote(name)) ORDER BY mtime DESC LIMIT 1
            """)
        guard let hash = rows.first?.first, !hash.isEmpty else {
            throw WriteError.fossil("the screenshot was attached but couldn't be found again")
        }
        // Relative, not "/raw/...": Fossil's markdown doesn't prefix image
        // sources with the repo's root, and posts and tickets are shown one
        // level down (/forumpost/HASH, /tktview/HASH), so "../raw/HASH" is
        // the repo's own /raw on the server and in the app alike.
        return "![Screenshot](../raw/\(hash)?m=\(mimeType))"
    }

    /// Hashes of the images a post shows with `![...](../raw/HASH...)` (or
    /// `/raw/HASH`).
    static func imageHashes(in body: String) -> [String] {
        let pattern = #"!\[[^\]]*\]\((?:\.\./|/)raw/([0-9a-f]{40,64})[^)]*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            Range(match.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    /// `body` without its attached images, which the bubble shows as
    /// pictures instead.
    static func removingImages(from body: String) -> String {
        body.replacingOccurrences(of: #"!\[[^\]]*\]\((?:\.\./|/)raw/[0-9a-f]{40,64}[^)]*\)"#, with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

