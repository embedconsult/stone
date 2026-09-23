import Foundation

/// A conversation is a Fossil forum thread or a ticket's comment history,
/// read straight from a repo's local clone and shown like a Messages chat.
/// Everything in this file is pure (Foundation only, no bridge, no UI) so the
/// parsing and composing rules can be unit-tested -- and compiled natively on
/// the Linux preflight host -- without a real repository.
///
/// The formats are Fossil's own, per
/// https://fossil-scm.org/home/doc/trunk/www/fileformat.wiki (forum posts and
/// ticket changes) and https://fossil-scm.org/home/doc/trunk/www/forum.wiki.
struct ConversationID: Hashable, Codable {
    enum Kind: String, Hashable, Codable {
        case thread
        case ticket
    }

    let repoID: UUID
    let kind: Kind
    /// Full hash of the thread's first post (a forum post's G card), or the
    /// ticket's uuid.
    let key: String

    /// Stable string form, used as a UserDefaults key and as a
    /// notification's thread identifier.
    var storageKey: String { "\(repoID.uuidString)/\(kind.rawValue)/\(key)" }
}

/// One post in a conversation: a forum post (its latest edit), or one ticket
/// change that added to the comment.
struct ConversationPost: Identifiable, Equatable {
    /// Artifact hash of the forum post, or of the ticket change.
    let hash: String
    let author: String
    /// Fossil's julian-day time of the post (the original post's, for an
    /// edited forum post, so edits don't reorder the conversation).
    let mtime: Double
    /// `nil` until read: a forum post's body lives in its artifact, not in
    /// any SQL column (ConversationReader fills it in).
    var body: String?
    var mimetype: String
    /// Hash of the post this one answers, when it says so (forum I card).
    /// Tickets have no such link.
    let inReplyTo: String?

    var id: String { hash }
    var date: Date { FossilTime.date(julian: mtime) }
}

/// One row in the conversations list.
struct ConversationSummary: Identifiable, Equatable {
    let id: ConversationID
    let title: String
    let latest: ConversationPost
    /// Posts by someone other than the signed-in login newer than the last
    /// time the conversation was read on this phone.
    var unread: Int
}

enum FossilTime {
    /// Fossil stores times as julian day numbers (SQLite's julianday()).
    static func date(julian: Double) -> Date {
        Date(timeIntervalSince1970: (julian - 2440587.5) * 86400)
    }

    /// A D card's value: UTC, `YYYY-MM-DDTHH:MM:SS.SSS`.
    static func dCard(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - Reading artifacts

/// The cards of one Fossil artifact as `fossil artifact HASH` prints it.
/// Tolerant: unknown cards are kept but ignored, and a malformed artifact
/// yields whatever cards parsed before the damage.
struct FossilArtifact: Equatable {
    /// Card letter -> the raw (still fossil-encoded) argument text, in order.
    private(set) var cards: [(letter: Character, value: String)] = []
    /// The W card's content, verbatim.
    private(set) var wiki: String?

    static func == (lhs: FossilArtifact, rhs: FossilArtifact) -> Bool {
        lhs.wiki == rhs.wiki && lhs.cards.map { "\($0.letter) \($0.value)" } == rhs.cards.map { "\($0.letter) \($0.value)" }
    }

    init(text: String) {
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            var end = i
            while end < bytes.count && bytes[end] != 0x0A { end += 1 }
            let line = String(decoding: bytes[i..<end], as: UTF8.self)
            i = end + 1
            guard let letter = line.first else { continue }
            let value = line.count > 2 ? String(line.dropFirst(2)) : ""
            if letter == "W", let size = Int(value.trimmingCharacters(in: .whitespaces)) {
                // The W card's size is in bytes; its content may itself
                // contain newlines, so take exactly that many bytes.
                let stop = min(i + max(size, 0), bytes.count)
                wiki = String(decoding: bytes[i..<stop], as: UTF8.self)
                i = stop + 1
                continue
            }
            cards.append((letter, value))
        }
    }

    func first(_ letter: Character) -> String? {
        cards.first { $0.letter == letter }.map { Fossilize.decode($0.value) }
    }
}

// MARK: - Writing artifacts

enum ConversationArtifact {
    /// A forum reply: D, G (thread), I (reply-to), N (mimetype), U (author),
    /// W (body), Z (checksum), in the card order Fossil requires.
    static func forumReply(thread: String, inReplyTo: String, user: String, body: String,
                           mimetype: String = "text/x-markdown", date: Date = Date()) -> String {
        var text = ""
        text += "D \(FossilTime.dCard(date))\n"
        text += "G \(thread)\n"
        text += "I \(inReplyTo)\n"
        text += "N \(Fossilize.encode(mimetype))\n"
        text += "U \(Fossilize.encode(user))\n"
        text += "W \(body.utf8.count)\n\(body)\n"
        return withChecksum(text)
    }

    /// A ticket change that appends `comment` to the ticket's comment
    /// (Fossil's `+icomment` J card), with the author as both the U card and
    /// the ticket's own `login` field, as Fossil's web form does.
    static func ticketComment(ticket: String, user: String, comment: String,
                              mimetype: String = "text/x-markdown", date: Date = Date()) -> String {
        // J cards sorted by field name, as Fossil writes them.
        let fields: [(String, String)] = [
            ("+icomment", comment),
            ("login", user),
            ("mimetype", mimetype),
        ]
        var text = "D \(FossilTime.dCard(date))\n"
        for (name, value) in fields {
            text += "J \(name) \(Fossilize.encode(value))\n"
        }
        text += "K \(ticket)\n"
        text += "U \(Fossilize.encode(user))\n"
        return withChecksum(text)
    }

    private static func withChecksum(_ text: String) -> String {
        text + "Z \(MD5.hex(Array(text.utf8)))\n"
    }
}

/// Fossil's card-argument escaping (encode.c fossilize/defossilize).
enum Fossilize {
    static func encode(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case " ": out += "\\s"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{0B}": out += "\\v"
            case "\u{0C}": out += "\\f"
            case "\\": out += "\\\\"
            case "\0": out += "\\0"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func decode(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                switch ch {
                case "s": out += " "
                case "n": out += "\n"
                case "t": out += "\t"
                case "r": out += "\r"
                case "v": out += "\u{0B}"
                case "f": out += "\u{0C}"
                case "0": out += "\0"
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

// MARK: - Reading posts

enum PostText {
    /// The first line worth showing as a preview: the first non-blank line,
    /// with leading markdown emphasis and list markers stripped.
    static func preview(_ body: String) -> String {
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            return line.replacingOccurrences(of: "**", with: "")
        }
        return ""
    }

    /// Logins named on a `For:` line (`For: opus`, `**For:** a, @b`, or a
    /// `For:` heading followed by the names on the next lines).
    static func forLogins(_ body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            guard let rest = afterHeading("For", in: raw) else { continue }
            var names = rest
            if names.isEmpty {
                // Heading on its own line: names follow until a blank line
                // after them, or the next heading.
                var collected: [String] = []
                for next in lines[(index + 1)...] {
                    let trimmed = next.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { if collected.isEmpty { continue } else { break } }
                    if isHeading(trimmed) { break }
                    collected.append(trimmed)
                }
                names = collected.joined(separator: ",")
            }
            return names
                .components(separatedBy: CharacterSet(charactersIn: ", ;"))
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*@` ")) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    /// The choices of a question-shaped post: one with a `Question:` heading
    /// and an `Options:` heading, whose options are the list items (or plain
    /// lines) after `Options:` up to the next heading. Empty for any other
    /// post -- a courtesy only; every post can be answered in free text.
    static func options(_ body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        guard lines.contains(where: { afterHeading("Question", in: $0) != nil }),
              let start = lines.firstIndex(where: { afterHeading("Options", in: $0) != nil })
        else { return [] }
        var options: [String] = []
        if let inline = afterHeading("Options", in: lines[start]), !inline.isEmpty {
            options.append(inline)
        }
        for raw in lines[(start + 1)...] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if isHeading(line) { break }
            let item = stripListMarker(line)
            if !item.isEmpty { options.append(item) }
        }
        return options
    }

    private static let headings = ["Question", "References", "Options", "Stakes", "For"]

    private static func isHeading(_ line: String) -> Bool {
        headings.contains { afterHeading($0, in: line) != nil }
    }

    /// The text after `Name:` when `line` starts with that heading, allowing
    /// markdown emphasis or a `#` heading around the name.
    private static func afterHeading(_ name: String, in line: String) -> String? {
        var s = line.trimmingCharacters(in: .whitespaces)
        while let first = s.first, first == "#" || first == "*" || first == "_" {
            s.removeFirst()
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard s.lowercased().hasPrefix(name.lowercased() + ":") else { return nil }
        var rest = String(s.dropFirst(name.count + 1))
        while let first = rest.first, first == "*" || first == "_" {
            rest.removeFirst()
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func stripListMarker(_ line: String) -> String {
        var s = Substring(line)
        if let first = s.first, "-*+•".contains(first) {
            s = s.dropFirst()
        } else {
            let digits = s.prefix { $0.isNumber }
            if !digits.isEmpty, let after = s.dropFirst(digits.count).first, after == "." || after == ")" {
                s = s.dropFirst(digits.count + 1)
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Assembling threads

/// One row of the clone's `forumpost` table joined with its `event` row and
/// hash -- the facts SQL can give without reading any artifact.
struct ForumPostRow: Equatable {
    let rid: Int
    let rootRid: Int
    /// The post this one edits, or 0.
    let previousRid: Int
    /// The post this one replies to, or 0.
    let inReplyToRid: Int
    let mtime: Double
    let hash: String
    let user: String
    /// The timeline comment: "Post: Title", "Reply: Title", "Edit reply:
    /// Title", "Delete reply: Title" and so on.
    let comment: String
}

enum ForumThreads {
    struct Thread: Equatable {
        let rootHash: String
        let title: String
        /// Latest versions of each post, oldest original first, deleted
        /// posts left out.
        let posts: [ConversationPost]
    }

    /// Groups `rows` by thread. An edit replaces the post it edits, keeping
    /// the original's place in the order; a deletion (an edit with an empty
    /// body, which Fossil labels "Delete ...") drops it.
    static func assemble(_ rows: [ForumPostRow]) -> [Thread] {
        let byRid = Dictionary(rows.map { ($0.rid, $0) }, uniquingKeysWith: { a, _ in a })
        let superseded = Set(rows.compactMap { $0.previousRid == 0 ? nil : $0.previousRid })

        func origin(of row: ForumPostRow) -> ForumPostRow {
            var current = row
            var guardCount = 0
            while current.previousRid != 0, let previous = byRid[current.previousRid], guardCount < 1000 {
                current = previous
                guardCount += 1
            }
            return current
        }

        var threads: [Int: [(order: Double, post: ConversationPost)]] = [:]
        var titles: [Int: String] = [:]
        for row in rows where !superseded.contains(row.rid) {
            let first = origin(of: row)
            if first.rid == row.rootRid || row.rid == row.rootRid {
                titles[row.rootRid] = title(fromComment: row.comment)
            }
            if isDeletion(row.comment) { continue }
            let replyTo = row.inReplyToRid == 0 ? nil : byRid[row.inReplyToRid]?.hash
            let post = ConversationPost(hash: row.hash, author: row.user, mtime: first.mtime,
                                        body: nil, mimetype: "", inReplyTo: replyTo)
            threads[row.rootRid, default: []].append((first.mtime, post))
        }

        return threads.compactMap { rootRid, entries in
            guard let root = byRid[rootRid] else { return nil }
            let posts = entries.sorted { $0.order < $1.order }.map(\.post)
            guard !posts.isEmpty else { return nil }
            let title = titles[rootRid] ?? title(fromComment: root.comment)
            return Thread(rootHash: root.hash, title: title.isEmpty ? "(untitled thread)" : title, posts: posts)
        }
    }

    static func isDeletion(_ comment: String) -> Bool {
        comment.hasPrefix("Delete ")
    }

    /// "Post: Title" -> "Title"; "Edit reply: Title" -> "Title". A comment
    /// with no recognised prefix is shown whole.
    static func title(fromComment comment: String) -> String {
        guard let colon = comment.range(of: ": ") else { return comment }
        let prefix = comment[..<colon.lowerBound]
        let words = prefix.split(separator: " ")
        let known: Set<Substring> = ["Post", "Reply", "Edit", "Delete", "reply", "post"]
        guard !words.isEmpty, words.allSatisfy({ known.contains($0) }) else { return comment }
        return String(comment[colon.upperBound...])
    }
}

// MARK: - Unread and notification bookkeeping

enum ConversationBook {
    /// Posts by anyone other than `login` newer than `lastRead` (a julian
    /// day; 0 for a conversation never opened on this phone).
    static func unread(_ posts: [ConversationPost], login: String, lastRead: Double) -> Int {
        return posts.filter { !isOwn($0, login: login) && $0.mtime > lastRead }.count
    }

    static func isOwn(_ post: ConversationPost, login: String) -> Bool {
        !login.isEmpty && post.author.caseInsensitiveCompare(login) == .orderedSame
    }

    /// Posts by someone else whose hash was never notified. `notified` is
    /// `nil` the first time a repo is scanned: everything already there is
    /// taken as seen, so installing or updating the app never floods the
    /// notification center with history.
    static func newForNotification(_ posts: [ConversationPost], login: String,
                                   notified: Set<String>?) -> [ConversationPost] {
        guard let notified else { return [] }
        return posts.filter { !isOwn($0, login: login) && !notified.contains($0.hash) }
    }

    /// Whether `login` takes part: it wrote a post (including the first), or
    /// the latest post names it on a `For:` line.
    static func participates(posts: [ConversationPost], login: String, latestBody: String?) -> Bool {
        guard !login.isEmpty else { return false }
        if posts.contains(where: { isOwn($0, login: login) }) { return true }
        guard let latestBody else { return false }
        return PostText.forLogins(latestBody).contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }
}

// MARK: - MD5 (for the Z card)

/// Minimal MD5 (RFC 1321). Fossil's Z card is the MD5 of everything before
/// it; CryptoKit's `Insecure.MD5` would do on iOS, but this keeps the file
/// Foundation-only so the Linux preflight can compile and check it too.
enum MD5 {
    static func hex(_ message: [UInt8]) -> String {
        digest(message).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        let k: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        var bytes = message
        let bitLength = UInt64(message.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }

        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = chunk + i * 4
                m[i] = UInt32(bytes[j]) | UInt32(bytes[j + 1]) << 8 | UInt32(bytes[j + 2]) << 16 | UInt32(bytes[j + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ (f << s[i] | f >> (32 - s[i]))
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * UInt32($0))) } }
    }
}
