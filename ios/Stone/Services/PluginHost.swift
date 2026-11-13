import CryptoKit
import Foundation

/// Runs Stone's apps: WebAssembly modules bundled in Stone's own build
/// (Apps/NAME/app.wasm, with a release.txt naming the project and check-in
/// it was built from and its sha256, as an OCX release does), each off until
/// the person switches it on in the Apps list (plan on stone forum
/// df2aca7b58, step 1; contract agreed on d584e578b6). Stone never runs code
/// fetched from a repository. Each page request runs the module once,
/// CGI-style (StoneWasm), and the module's imports are answered here:
///
/// - `fossil` {"args", "input", "file"?, "repository"?}: a Fossil command on
///   the repository, signed with its own login (-U), "{file}" replaced by a
///   file holding "file"'s bytes. Reply {"status", "output", "error"}.
/// - `query` {"sql", "args", "repository"?}: a read; "?" takes each arg in
///   turn. Reply {"rows": [[TEXT]]}.
/// - `projects` {}: reply {"names"}, the repositories on this phone.
/// - `fetch` {"url"}: reply {"status", "type", "body"} (5 MB at most), or
///   {"error"}.
/// - `media` {"action": play|pause|status, "url", "title"}: Stone's player
///   (PodcastPlayer: background audio, lock screen). Reply {"state",
///   "title", "position", "duration"}.
///
/// "repository" names a repository on this phone; without it, calls go to
/// the app's own project's repository, when it's on the phone. Nothing else
/// on the phone is reachable.
enum PluginHost {
    /// One repository a plugin may reach.
    struct Place {
        let name: String
        let path: String
        let login: String
    }

    /// What a run's imports may reach: the app's project's repository, if
    /// it's on the phone, and the others. Never changed after it's made, so
    /// any thread may read it.
    final class Context: @unchecked Sendable {
        let home: Place?
        let others: [Place]

        init(home: Place?, others: [Place]) {
            self.home = home
            self.others = others
        }

        func place(_ name: String?) -> Place? {
            guard let name, !name.isEmpty else { return home }
            if let home, home.name == name { return home }
            return others.first { $0.name == name }
        }
    }

    /// One bundled app: Apps/NAME/ in Stone's bundle.
    struct App: Identifiable, Hashable {
        let name: String
        let project: String
        let checkin: String
        let sha256: String
        let module: URL
        var id: String { name }
        var title: String { name.capitalized }
    }

    /// Stone's bundled apps, by name. release.txt holds "project NAME",
    /// "check-in HASH" and a sha256sum line for app.wasm.
    static let apps: [App] = {
        guard let root = Bundle.main.url(forResource: "Apps", withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            let folder = root.appendingPathComponent(name)
            guard let text = try? String(contentsOf: folder.appendingPathComponent("release.txt"), encoding: .utf8) else {
                return nil
            }
            var project = "", checkin = "", sha256 = ""
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "project": project = parts[1]
                case "check-in": checkin = parts[1]
                default: if parts[1] == "app.wasm" { sha256 = parts[0].lowercased() }
                }
            }
            guard !sha256.isEmpty else { return nil }
            return App(name: name, project: project, checkin: checkin, sha256: sha256,
                       module: folder.appendingPathComponent("app.wasm"))
        }
    }()

    /// The app's module, or nil when its bytes don't match release.txt.
    static func module(_ app: App) -> [UInt8]? {
        guard let data = try? Data(contentsOf: app.module) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == app.sha256 ? [UInt8](data) : nil
    }

    /// The UserDefaults key of the app's switch (off until switched on).
    static func switchKey(_ app: App) -> String { "app.on.\(app.name)" }

    /// Plugin runs happen here, one at a time, off the main thread.
    static let queue = DispatchQueue(label: "org.beagleboard.stone.plugins")

    @MainActor
    static func place(_ repo: Repo, _ store: RepoStore) -> Place {
        Place(name: (repo.fileName as NSString).deletingPathExtension,
              path: store.fileURL(for: repo).path,
              login: ConversationStore.login(for: repo))
    }

    @MainActor
    static func context(_ app: App, _ store: RepoStore) -> Context {
        let all = store.repos.map { place($0, store) }
        return Context(home: all.first { $0.name == app.project },
                       others: all.filter { $0.name != app.project })
    }

    /// Runs one request through the module, on `queue`.
    static func run(_ module: [UInt8], _ context: Context, method: String, query: String,
                    body: Data, contentType: String) async -> WasmRunner.Result {
        await withCheckedContinuation { continuation in
            queue.async {
                let env = ["REQUEST_METHOD=\(method)", "QUERY_STRING=\(query)", "PATH_INFO=/",
                           "CONTENT_LENGTH=\(body.count)", "CONTENT_TYPE=\(contentType)",
                           "GATEWAY_INTERFACE=CGI/1.1", "SERVER_SOFTWARE=Stone"]
                let unmanaged = Unmanaged.passRetained(context)
                defer { unmanaged.release() }
                let input = String(decoding: body, as: UTF8.self)
                continuation.resume(returning: WasmRunner.run(module, env: env, input: input,
                                                              host: answer, context: unmanaged.toOpaque()))
            }
        }
    }

    /// StoneWasm's host callback: answers one import, as malloc'd JSON.
    static let answer: stone_wasm_host_fn = { context, name, request in
        guard let context, let name, let request else { return nil }
        let host = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
        let call = String(cString: name)
        let fields = (try? JSONSerialization.jsonObject(with: Data(String(cString: request).utf8))) as? [String: Any] ?? [:]
        let reply: [String: Any]
        switch call {
        case "fossil": reply = fossil(fields, host)
        case "query": reply = query(fields, host)
        case "projects": reply = ["names": (host.home.map { [$0.name] } ?? []) + host.others.map(\.name)]
        case "fetch": reply = fetch(fields)
        case "media": reply = media(fields)
        default: return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return nil }
        return strdup(String(decoding: data, as: UTF8.self))
    }

    private static func fossil(_ fields: [String: Any], _ host: Context) -> [String: Any] {
        guard let place = host.place(fields["repository"] as? String) else {
            return ["status": 1, "output": "", "error": "This phone doesn't carry that repository."]
        }
        var args = (fields["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        var file: URL?
        if let encoded = fields["file"] as? String, let bytes = Data(base64Encoded: encoded) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-file-\(UUID().uuidString)")
            if (try? bytes.write(to: url)) != nil {
                file = url
                args = args.map { $0 == "{file}" ? url.path : $0 }
            }
        }
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        if let problem = ensureUser(place) {
            return ["status": 1, "output": "", "error": problem]
        }
        let result = FossilEngine.shared.runNow(args + ["-U", place.login, "-R", place.path])
        return ["status": Int(result.exitCode), "output": result.succeeded ? result.output : "",
                "error": result.succeeded ? "" : result.output]
    }

    /// -U needs the login in the clone's own user table; adding it there is
    /// local only (the user table doesn't sync).
    private static func ensureUser(_ place: Place) -> String? {
        guard FossilQuery.rows(place.path, "SELECT 1 FROM user WHERE login = \(FossilQuery.quote(place.login))").isEmpty else {
            return nil
        }
        let made = FossilEngine.shared.runNow(["user", "new", place.login, "", UUID().uuidString, "-R", place.path])
        return made.succeeded ? nil : made.output
    }

    private static func query(_ fields: [String: Any], _ host: Context) -> [String: Any] {
        guard let place = host.place(fields["repository"] as? String) else {
            return ["error": "This phone doesn't carry that repository."]
        }
        guard let sql = fields["sql"] as? String else { return ["error": "no sql"] }
        let args = (fields["args"] as? [Any])?.map { "\($0)" } ?? []
        return ["rows": FossilQuery.rows(place.path, bind(sql, args))]
    }

    /// The SQL with each "?" outside quotes replaced by the next argument:
    /// a whole number as it is, anything else as a quoted string.
    static func bind(_ sql: String, _ args: [String]) -> String {
        var out = ""
        var next = args.makeIterator()
        var quote: Character?
        for char in sql {
            if let open = quote {
                out.append(char)
                if char == open { quote = nil }
            } else if char == "'" || char == "\"" {
                quote = char
                out.append(char)
            } else if char == "?", let arg = next.next() {
                let whole = !arg.isEmpty && arg.allSatisfy(\.isASCII) && Int(arg) != nil
                out += whole ? arg : FossilQuery.quote(arg)
            } else {
                out.append(char)
            }
        }
        return out
    }

    static let fetchLimit = 5 * 1024 * 1024

    private static func fetch(_ fields: [String: Any]) -> [String: Any] {
        guard let text = fields["url"] as? String, let url = URL(string: text),
              url.scheme == "https" || url.scheme == "http" else {
            return ["error": "not a web address"]
        }
        var reply: [String: Any] = ["error": "no answer"]
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                reply = ["error": error.localizedDescription]
                return
            }
            let http = response as? HTTPURLResponse
            let body = data ?? Data()
            if body.count > fetchLimit {
                reply = ["error": "the answer is over 5 MB"]
                return
            }
            reply = ["status": http?.statusCode ?? 0,
                     "type": http?.value(forHTTPHeaderField: "Content-Type") ?? "",
                     "body": String(decoding: body, as: UTF8.self)]
        }.resume()
        done.wait()
        return reply
    }

    private static func media(_ fields: [String: Any]) -> [String: Any] {
        let action = fields["action"] as? String ?? "status"
        let url = (fields["url"] as? String).flatMap(URL.init(string:))
        let title = fields["title"] as? String ?? ""
        let now: (state: String, title: String, position: Double, duration: Double) = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let player = PodcastPlayer.shared
                switch action {
                case "play":
                    if let url, player.current?.audioURL != url {
                        player.play(PodcastEpisode(title: title.isEmpty ? url.lastPathComponent : title,
                                                   date: nil, audioURL: url), feedTitle: "")
                    } else {
                        player.resume()
                    }
                case "pause":
                    player.pause()
                default:
                    break
                }
                return (state: player.current == nil ? "stopped" : (player.playing ? "playing" : "paused"),
                        title: player.current?.title ?? "",
                        position: player.position,
                        duration: player.duration)
            }
        }
        return ["state": now.state, "title": now.title, "position": now.position, "duration": now.duration]
    }
}
