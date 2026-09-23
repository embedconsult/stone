import Foundation

/// Reads conversations out of a repo's local clone: forum threads from the
/// `forumpost`/`event` tables Fossil fills in as it crosslinks, ticket
/// comments from `ticketchng`. Nothing here talks to a server or depends on a
/// custom ticket field.
enum ConversationReader {
    struct Loaded {
        let id: ConversationID
        let title: String
        /// Oldest first. Thread posts have `body == nil` until
        /// `fillBodies` reads them; ticket posts come with their bodies.
        var posts: [ConversationPost]
    }

    /// Every thread and every ticket with at least one comment. Cheap: SQL
    /// only, no artifact reads.
    static func all(repoID: UUID, fossilPath: String) -> [Loaded] {
        threads(repoID: repoID, fossilPath: fossilPath) + tickets(repoID: repoID, fossilPath: fossilPath)
    }

    static func threads(repoID: UUID, fossilPath: String) -> [Loaded] {
        let sql = """
        SELECT f.fpid, f.froot, COALESCE(f.fprev, 0), COALESCE(f.firt, 0), f.fmtime, b.uuid,
               COALESCE(e.user, ''), COALESCE(e.comment, '')
        FROM forumpost f JOIN blob b ON b.rid = f.fpid LEFT JOIN event e ON e.objid = f.fpid
        """
        let rows: [ForumPostRow] = FossilQuery.rows(fossilPath, sql).compactMap { r in
            guard r.count >= 8, let rid = Int(r[0]), let root = Int(r[1]), let mtime = Double(r[4]) else { return nil }
            return ForumPostRow(rid: rid, rootRid: root, previousRid: Int(r[2]) ?? 0,
                                inReplyToRid: Int(r[3]) ?? 0, mtime: mtime, hash: r[5],
                                user: r[6], comment: r[7...].joined(separator: "\u{1F}"))
        }
        return ForumThreads.assemble(rows).map {
            Loaded(id: ConversationID(repoID: repoID, kind: .thread, key: $0.rootHash),
                   title: $0.title, posts: $0.posts)
        }
    }

    /// Each ticket's comment-bearing changes, as posts. The author is the
    /// change's U card (`tkt_user`), falling back to the `login`/`username`
    /// fields older clones and web-form changes carry.
    static func tickets(repoID: UUID, fossilPath: String) -> [Loaded] {
        let changeColumns = FossilQuery.columns(fossilPath, table: "ticketchng")
        guard changeColumns.contains("icomment") else { return [] }
        let ticketColumns = FossilQuery.columns(fossilPath, table: "ticket")
        let authorParts = ["tkt_user", "login", "username"].filter(changeColumns.contains)
            .map { "NULLIF(c.\($0), '')" } + ["''"]
        let author = "COALESCE(\(authorParts.joined(separator: ", ")))"
        let mimetype = changeColumns.contains("mimetype") ? "COALESCE(c.mimetype, '')" : "''"
        let title = ticketColumns.contains("title") ? "COALESCE(t.title, '')" : "''"
        let sql = """
        SELECT t.tkt_uuid, \(title), c.tkt_mtime, b.uuid, \(author), c.icomment, \(mimetype)
        FROM ticketchng c JOIN ticket t ON t.tkt_id = c.tkt_id JOIN blob b ON b.rid = c.tkt_rid
        WHERE c.icomment IS NOT NULL AND c.icomment != ''
        ORDER BY c.tkt_mtime
        """
        var order: [String] = []
        var byTicket: [String: Loaded] = [:]
        for r in FossilQuery.rows(fossilPath, sql) {
            guard r.count >= 7, let mtime = Double(r[2]) else { continue }
            let uuid = r[0]
            let post = ConversationPost(hash: r[3], author: r[4], mtime: mtime, body: r[5],
                                        mimetype: r[6], inReplyTo: nil)
            if byTicket[uuid] == nil {
                order.append(uuid)
                byTicket[uuid] = Loaded(id: ConversationID(repoID: repoID, kind: .ticket, key: uuid),
                                        title: r[1].isEmpty ? "(untitled ticket)" : r[1], posts: [])
            }
            byTicket[uuid]?.posts.append(post)
        }
        return order.compactMap { byTicket[$0] }
    }

    /// Logins that made any change to a ticket (not only comments) --
    /// "started it or took part" for a ticket, keyed by ticket uuid.
    static func ticketParticipants(fossilPath: String, login: String) -> Set<String> {
        let changeColumns = FossilQuery.columns(fossilPath, table: "ticketchng")
        let checks = ["tkt_user", "login"].filter(changeColumns.contains)
            .map { "c.\($0) = \(FossilQuery.quote(login)) COLLATE NOCASE" }
        guard !checks.isEmpty else { return [] }
        let sql = """
        SELECT DISTINCT t.tkt_uuid FROM ticketchng c JOIN ticket t ON t.tkt_id = c.tkt_id
        WHERE \(checks.joined(separator: " OR "))
        """
        return Set(FossilQuery.rows(fossilPath, sql).compactMap(\.first))
    }

    /// The body of one forum post, from its artifact.
    static func body(hash: String, fossilPath: String) async -> (body: String, mimetype: String)? {
        if let cached = BodyCache.read(hash) {
            return cached
        }
        let result = await FossilEngine.shared.run(["artifact", hash, "-R", fossilPath])
        guard result.succeeded else { return nil }
        let artifact = FossilArtifact(text: result.output)
        guard let body = artifact.wiki else { return nil }
        let mimetype = artifact.first("N") ?? ""
        BodyCache.write(hash, body: body, mimetype: mimetype)
        return (body, mimetype)
    }

    /// Reads every missing body in `posts`.
    static func fillBodies(_ posts: [ConversationPost], fossilPath: String) async -> [ConversationPost] {
        var filled = posts
        for index in filled.indices where filled[index].body == nil {
            if let read = await body(hash: filled[index].hash, fossilPath: fossilPath) {
                filled[index].body = read.body
                filled[index].mimetype = read.mimetype
            }
        }
        return filled
    }
}

/// Artifacts never change once written, so a post's body is cached on disk by
/// hash: the list's previews and `For:` checks then cost one artifact read
/// per post, ever, rather than one per sync.
private enum BodyCache {
    private static var directory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("post-bodies", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct Entry: Codable {
        let body: String
        let mimetype: String
    }

    static func read(_ hash: String) -> (body: String, mimetype: String)? {
        guard let url = directory?.appendingPathComponent(hash),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return (entry.body, entry.mimetype)
    }

    static func write(_ hash: String, body: String, mimetype: String) {
        guard let url = directory?.appendingPathComponent(hash),
              let data = try? JSONEncoder().encode(Entry(body: body, mimetype: mimetype)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
