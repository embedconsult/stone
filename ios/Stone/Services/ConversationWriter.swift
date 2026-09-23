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
