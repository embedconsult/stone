import Foundation

/// Outcome of syncing a single repository as part of a "Sync All" run.
enum RepoSyncStatus: Equatable {
    case syncing
    case success
    case failure(String)
}

/// Owns the set of repositories: where their files live, their metadata, and
/// the high-level operations (create, clone, sync, delete).
///
/// It coordinates the other components but performs no Fossil work itself —
/// that is delegated to `FossilEngine`, with secrets via `CredentialStore`.
@MainActor
final class RepoStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []
    @Published var lastSyncLog: String = ""

    /// Per-repo outcome of the most recent "Sync All" run, keyed by repo id.
    @Published private(set) var syncStatuses: [UUID: RepoSyncStatus] = [:]
    @Published private(set) var isSyncingAll = false
    @Published private(set) var syncAllSummary: String?

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
        let authURL = try Self.urlWithPassword(remoteURL, password: password)
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
        let authURL = try Self.urlWithPassword(remote, password: password)
        let path = fileURL(for: repo).path
        let result = await engine.run(["sync", authURL, "-R", path])
        lastSyncLog = result.output
        guard result.succeeded else { throw StoreError.fossil(result.output) }
        return result.output
    }

    /// Parses Fossil's non-interactive sync summary line
    /// (`Round-trips: N   Artifacts sent: X  received: Y`, src/xfer.c
    /// `zBriefFormat`, printed exactly once when stdout isn't a tty) out of a
    /// `sync`/`clone` command's raw output. `nil` if the line isn't present
    /// (e.g. the command failed before any round-trip).
    ///
    /// This exists because a successful exit code alone does not mean
    /// anything was actually pushed: a remote identity lacking write
    /// capability makes Fossil silently decline to send content while still
    /// exiting 0. Surfacing the real sent/received counts, rather than a
    /// blanket "Sync complete," makes that silent no-op visible.
    static func parseArtifactCounts(_ output: String) -> (sent: Int, received: Int)? {
        guard let regex = try? NSRegularExpression(
            pattern: "Artifacts sent:\\s*(\\d+)\\s+received:\\s*(\\d+)"
        ) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let sentRange = Range(match.range(at: 1), in: output),
              let receivedRange = Range(match.range(at: 2), in: output),
              let sent = Int(output[sentRange]),
              let received = Int(output[receivedRange])
        else { return nil }
        return (sent, received)
    }

    /// Sync every repository that has a remote configured, one at a time (the
    /// same `sync(_:)` used by the per-repo screen). Repos without a remote
    /// are skipped. Runs sequentially so we never hammer a remote with
    /// concurrent requests.
    func syncAll() async {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        syncAllSummary = nil
        syncStatuses = [:]
        defer { isSyncingAll = false }

        var succeeded = 0
        var failed = 0
        var skipped = 0

        for repo in repos {
            guard repo.remoteURL != nil else {
                skipped += 1
                continue
            }
            syncStatuses[repo.id] = .syncing
            do {
                _ = try await sync(repo)
                syncStatuses[repo.id] = .success
                succeeded += 1
            } catch {
                syncStatuses[repo.id] = .failure(error.localizedDescription)
                failed += 1
            }
        }

        var parts = ["\(succeeded) synced"]
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped (no remote)") }
        syncAllSummary = parts.joined(separator: ", ")
    }

    func dismissSyncAllSummary() {
        syncAllSummary = nil
    }

    /// Rename a repository. Only the display label changes; the `.fossil` file
    /// keeps its (UUID-suffixed) name, so nothing on disk needs to move.
    func rename(_ repo: Repo, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        repos[idx].name = trimmed
        save()
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
        case passwordNeedsUsername

        var errorDescription: String? {
            switch self {
            case .fossil(let msg): return msg.isEmpty ? "Fossil command failed." : msg
            case .noRemote: return "This repository has no remote configured."
            case .passwordNeedsUsername:
                return "A password needs a username in the remote URL first — e.g. https://user@host/repo, not just https://host/repo."
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
    /// non-interactively. Username, if any, must already be part of `remote`
    /// (e.g. `https://user@host/repo`) -- a password with no username would
    /// silently become an empty-username credential, which Fossil rejects, so
    /// that combination is refused up front instead.
    private static func urlWithPassword(_ remote: String, password: String?) throws -> String {
        guard let password, !password.isEmpty else { return remote }
        guard var comps = URLComponents(string: remote) else { return remote }
        guard let user = comps.user, !user.isEmpty else {
            throw StoreError.passwordNeedsUsername
        }
        comps.password = password
        return comps.string ?? remote
    }
}
