import Foundation

/// Owns the set of repositories: where their files live, their metadata, and
/// the high-level operations (create, clone, sync, delete).
///
/// It coordinates the other components but performs no Fossil work itself —
/// that is delegated to `FossilEngine`, with secrets via `CredentialStore`.
@MainActor
final class RepoStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []
    @Published var lastSyncLog: String = ""

    private let engine = FossilEngine.shared
    private let fileManager = FileManager.default

    init() {
        load()
    }

    // MARK: - Locations

    /// Directory holding every `.fossil` file plus the metadata index.
    private var repositoriesDir: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Repositories", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL {
        repositoriesDir.appendingPathComponent("index.json")
    }

    /// Absolute location of a repository's `.fossil` database file.
    func fileURL(for repo: Repo) -> URL {
        repositoriesDir.appendingPathComponent(repo.fileName)
    }

    // MARK: - Persistence of the metadata index

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Repo].self, from: data)
        else { return }
        repos = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(repos) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Operations

    /// Create a brand-new empty repository.
    func createRepo(named name: String) async throws {
        let fileName = Self.fileName(for: name)
        let path = repositoriesDir.appendingPathComponent(fileName).path
        let result = await engine.run(["init", path])
        guard result.succeeded else { throw StoreError.fossil(result.output) }
        var repo = Repo(name: name, fileName: fileName)
        repo.remoteURL = nil
        repos.append(repo)
        save()
    }

    /// Clone a remote repository into a new local `.fossil` file.
    func cloneRepo(named name: String, remoteURL: String, password: String?) async throws {
        let fileName = Self.fileName(for: name)
        let path = repositoriesDir.appendingPathComponent(fileName).path
        let id = UUID()
        let authURL = Self.urlWithPassword(remoteURL, password: password)
        let result = await engine.run(["clone", authURL, path])
        guard result.succeeded else { throw StoreError.fossil(result.output) }
        if let password, !password.isEmpty {
            CredentialStore.setPassword(password, for: id)
        }
        repos.append(Repo(id: id, name: name, fileName: fileName, remoteURL: remoteURL))
        save()
    }

    /// Pull + push against the repository's configured remote.
    @discardableResult
    func sync(_ repo: Repo) async throws -> String {
        guard let remote = repo.remoteURL, !remote.isEmpty else {
            throw StoreError.noRemote
        }
        let password = CredentialStore.password(for: repo.id)
        let authURL = Self.urlWithPassword(remote, password: password)
        let path = fileURL(for: repo).path
        let result = await engine.run(["sync", authURL, "-R", path])
        lastSyncLog = result.output
        guard result.succeeded else { throw StoreError.fossil(result.output) }
        return result.output
    }

    func updateRemote(_ repo: Repo, remoteURL: String?, password: String?) {
        guard let idx = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        repos[idx].remoteURL = (remoteURL?.isEmpty == true) ? nil : remoteURL
        if let password, !password.isEmpty {
            CredentialStore.setPassword(password, for: repo.id)
        }
        save()
    }

    func delete(_ repo: Repo) {
        try? fileManager.removeItem(at: fileURL(for: repo))
        CredentialStore.delete(for: repo.id)
        repos.removeAll { $0.id == repo.id }
        save()
    }

    // MARK: - Helpers

    enum StoreError: LocalizedError {
        case fossil(String)
        case noRemote

        var errorDescription: String? {
            switch self {
            case .fossil(let msg): return msg.isEmpty ? "Fossil command failed." : msg
            case .noRemote: return "This repository has no remote configured."
            }
        }
    }

    private static func fileName(for name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? "repo" : safe
        return "\(base)-\(UUID().uuidString.prefix(8)).fossil"
    }

    /// Inject a password into a remote URL's userinfo so Fossil can authenticate
    /// non-interactively. Username, if any, must already be part of `remote`.
    private static func urlWithPassword(_ remote: String, password: String?) -> String {
        guard let password, !password.isEmpty,
              var comps = URLComponents(string: remote) else { return remote }
        comps.password = password
        if comps.user == nil { comps.user = "" }
        return comps.string ?? remote
    }
}
