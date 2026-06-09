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

    init(id: UUID = UUID(), name: String, fileName: String, remoteURL: String? = nil) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.remoteURL = remoteURL
    }
}
