import Foundation

/// The conversations the signed-in login takes part in, across every repo,
/// with this phone's read markers and the "already notified" set.
///
/// A conversation counts when the login wrote any post in it (starting it
/// included), or when the latest post names it on a `For:` line. The login is
/// the username in the repo's remote URL -- the identity Fossil syncs as --
/// falling back to the commit-author setting for a repo without one.
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    /// Newest activity first.
    @Published private(set) var summaries: [ConversationSummary] = []

    var totalUnread: Int { summaries.reduce(0) { $0 + $1.unread } }

    /// New posts by someone else in one conversation, found by the last scan.
    struct NewPosts {
        let repo: Repo
        let summary: ConversationSummary
        let posts: [ConversationPost]
    }

    private let defaults: UserDefaults
    private static let lastReadKey = "conversationLastReadV1"
    private static let notifiedKey = "conversationNotifiedV1"

    /// Conversation storage key -> julian day of the newest post read here.
    private var lastRead: [String: Double]
    /// Repo id -> hashes of posts already notified (or already present when
    /// the repo was first scanned). Absent for a repo never scanned.
    private var notified: [String: [String]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastRead = (defaults.dictionary(forKey: Self.lastReadKey) as? [String: Double]) ?? [:]
        notified = (defaults.dictionary(forKey: Self.notifiedKey) as? [String: [String]]) ?? [:]
    }

    nonisolated static func login(for repo: Repo) -> String {
        if let remote = repo.remoteURL {
            let user = RepoStore.splitRemoteURL(remote).username
            if !user.isEmpty { return user }
        }
        return UserDefaults.standard.string(forKey: "commitAuthor") ?? "stone"
    }

    /// Rebuilds `summaries` from every repo's clone, and returns what is new
    /// since the last scan for notifying. The first scan of a repo takes
    /// everything already there as read and notified, so history never
    /// floods the phone.
    @discardableResult
    func refresh(repos: [Repo], fossilPath: (Repo) -> String) async -> [NewPosts] {
        var all: [ConversationSummary] = []
        var outcomes: [NewPosts] = []
        for repo in repos {
            let path = fossilPath(repo)
            let login = Self.login(for: repo)
            let conversations = await Self.participating(repoID: repo.id, fossilPath: path, login: login)
            let repoKey = repo.id.uuidString
            let firstScan = notified[repoKey] == nil
            let previouslyNotified = notified[repoKey].map(Set.init)
            var nowNotified: Set<String> = []

            for conversation in conversations {
                guard let latest = conversation.posts.last else { continue }
                let key = conversation.id.storageKey
                if firstScan && lastRead[key] == nil {
                    lastRead[key] = latest.mtime
                }
                let summary = ConversationSummary(
                    id: conversation.id, title: conversation.title, latest: latest,
                    unread: ConversationBook.unread(conversation.posts, login: login, lastRead: lastRead[key] ?? 0))
                all.append(summary)

                let fresh = ConversationBook.newForNotification(conversation.posts, login: login,
                                                                notified: previouslyNotified)
                if !fresh.isEmpty {
                    var withBodies = fresh
                    if conversation.id.kind == .thread {
                        withBodies = await ConversationReader.fillBodies(fresh, fossilPath: path)
                    }
                    outcomes.append(NewPosts(repo: repo, summary: summary, posts: withBodies))
                }
                for post in conversation.posts where !ConversationBook.isOwn(post, login: login) {
                    nowNotified.insert(post.hash)
                }
            }
            notified[repoKey] = Array(nowNotified)
        }
        summaries = all.sorted { $0.latest.mtime > $1.latest.mtime }
        persist()
        return outcomes
    }

    /// Posts of one conversation, bodies read, oldest first.
    func posts(for id: ConversationID, fossilPath: String) async -> (title: String, posts: [ConversationPost])? {
        let loaded: ConversationReader.Loaded? = await Task.detached(priority: .userInitiated) {
            switch id.kind {
            case .thread:
                return ConversationReader.threads(repoID: id.repoID, fossilPath: fossilPath).first { $0.id == id }
            case .ticket:
                return ConversationReader.tickets(repoID: id.repoID, fossilPath: fossilPath).first { $0.id == id }
            }
        }.value
        guard let loaded else { return nil }
        let posts = await ConversationReader.fillBodies(loaded.posts, fossilPath: fossilPath)
        return (loaded.title, posts)
    }

    /// Marks everything up to `mtime` read in `id`.
    func markRead(_ id: ConversationID, upTo mtime: Double) {
        let key = id.storageKey
        guard (lastRead[key] ?? 0) < mtime else { return }
        lastRead[key] = mtime
        if let index = summaries.firstIndex(where: { $0.id == id }) {
            summaries[index].unread = 0
        }
        persist()
    }

    /// The conversations `login` takes part in, latest post body read (the
    /// list shows it, and a `For:` line in it is one way to take part).
    private static func participating(repoID: UUID, fossilPath: String, login: String) async -> [ConversationReader.Loaded] {
        let (loaded, ticketsTouched) = await Task.detached(priority: .utility) {
            (ConversationReader.all(repoID: repoID, fossilPath: fossilPath),
             ConversationReader.ticketParticipants(fossilPath: fossilPath, login: login))
        }.value
        var result: [ConversationReader.Loaded] = []
        for var conversation in loaded {
            guard !conversation.posts.isEmpty else { continue }
            let last = conversation.posts.count - 1
            if conversation.posts[last].body == nil,
               let read = await ConversationReader.body(hash: conversation.posts[last].hash, fossilPath: fossilPath) {
                conversation.posts[last].body = read.body
                conversation.posts[last].mimetype = read.mimetype
            }
            let touched = conversation.id.kind == .ticket && ticketsTouched.contains(conversation.id.key)
            if touched || ConversationBook.participates(posts: conversation.posts, login: login,
                                                        latestBody: conversation.posts[last].body) {
                result.append(conversation)
            }
        }
        return result
    }

    private func persist() {
        defaults.set(lastRead, forKey: Self.lastReadKey)
        defaults.set(notified, forKey: Self.notifiedKey)
    }
}
