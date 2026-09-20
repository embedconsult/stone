import Foundation

/// A Fossil repository managed by the app.
///
/// `Repo` is pure data: identity plus where the `.fossil` file lives and the
/// optional remote it syncs with. It deliberately knows nothing about the
/// engine, the UI, or credentials — those live in their own components.
struct Repo: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String

    /// File name of the `.fossil` database within the app's repositories
    /// directory. Stored as a name (not an absolute URL) so the record stays
    /// valid across app container path changes between launches.
    var fileName: String

    /// Remote sync URL, if any (e.g. "https://example.com/myrepo").
    /// The password, when present, is stored separately in the Keychain.
    var remoteURL: String?

    /// When this clone last pulled `configuration ... ticket` from its
    /// remote (ticket d4d02c604f). `RepoStore.sync` uses this to cap the
    /// proactive refresh to at most once a day per repo, since every pull
    /// makes Fossil rebuild the entire local TICKET table
    /// (`configure_rebuild`/`ticket_rebuild`) -- expensive on a repo with
    /// thousands of tickets. `nil` (e.g. an index persisted before this
    /// field existed) is treated as "never pulled," so it's due immediately.
    var lastTicketConfigPullAt: Date?

    /// Same idea as `lastTicketConfigPullAt`, for `configuration ... skin`.
    /// Skin is purely cosmetic, so it only needs the once-a-day cap, never
    /// the schema-mismatch self-heal ticket config also does.
    var lastSkinPullAt: Date?

    init(id: UUID = UUID(), name: String, fileName: String, remoteURL: String? = nil,
         lastTicketConfigPullAt: Date? = nil, lastSkinPullAt: Date? = nil) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.remoteURL = remoteURL
        self.lastTicketConfigPullAt = lastTicketConfigPullAt
        self.lastSkinPullAt = lastSkinPullAt
    }
}
