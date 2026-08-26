import Foundation

/// Authenticated HTTPS client for a repository's *remote* Fossil server.
///
/// Single responsibility: obtain a Fossil login cookie for one remote and carry
/// it on subsequent requests. This is the shared auth foundation for both the
/// remote-cached read proxy and the agent-client layer (`/ext/...`, forum
/// posting, the SSE token mint) — see docs/design/agent-client-scoping.md.
///
/// It is deliberately separate from `FossilEngine`: this is ordinary client
/// traffic over `URLSession` (system trust store), not the embedded Fossil C
/// core, so it does not need the bundled `cacert.pem`.
///
/// Cookie policy: the `fossil-<projcode>` cookie lives in this session's own
/// in-memory (ephemeral) jar and is not persisted. Server-side login cookies are
/// short-lived, so we simply re-login on a 401 rather than widening the Keychain
/// surface with a stored cookie.
actor RemoteSession {
    /// Base URL of the remote repository, with any userinfo stripped
    /// (e.g. `https://fossil.example.com/myrepo`).
    private let baseURL: URL
    private let username: String?
    private let password: String?
    private let urlSession: URLSession

    private var loggedIn = false

    enum RemoteError: LocalizedError {
        case notAuthenticated          // 401 / no cookie after login
        case noCredentials             // nothing to log in with
        case http(Int)                 // other non-2xx
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not permitted — the login was rejected or lacks access on this repository."
            case .noCredentials:
                return "No remote login is configured. Settings > Commit Author is local-only; use a remote URL containing its login name and save that remote's password when cloning."
            case .http(let code):
                return "The remote returned HTTP \(code)."
            case .badResponse:
                return "The remote returned an unexpected response."
            }
        }
    }

    /// - Parameters:
    ///   - remoteURL: the repository's remote URL, which may include userinfo
    ///     (`https://user@host/repo`). Userinfo is split out for login.
    ///   - password: the secret from `CredentialStore` (not carried in the URL).
    init?(remoteURL: String, password: String?) {
        guard let comps = URLComponents(string: remoteURL),
              let scheme = comps.scheme, let host = comps.host else { return nil }

        var clean = URLComponents()
        clean.scheme = scheme
        clean.host = host
        clean.port = comps.port
        clean.path = comps.path
        guard let base = clean.url else { return nil }

        self.baseURL = base
        self.username = comps.user
        self.password = password

        let config = URLSessionConfiguration.ephemeral   // in-memory cookie jar
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// GET `path` (relative to the repo base, e.g. `"ext/agent"`) with optional
    /// query items, logging in first if needed and retrying once on a 401.
    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        if !loggedIn { try await login() }
        do {
            return try await rawGet(path, query: query)
        } catch RemoteError.notAuthenticated {
            // Cookie may have expired; re-login once and retry.
            loggedIn = false
            try await login()
            return try await rawGet(path, query: query)
        }
    }
    /// POST a form (relative to the repo base, e.g. `"edit"`) as the logged-in
    /// user, logging in first if needed and retrying once on a 401.
    func post(_ path: String, form: [String: String]) async throws -> Data {
        if !loggedIn { try await login() }
        do {
            return try await rawPost(path, form: form)
        } catch RemoteError.notAuthenticated {
            loggedIn = false
            try await login()
            return try await rawPost(path, form: form)
        }
    }

    /// Posts a reply to a forum thread. Follows Fossil's CSRF flow:
    /// GET /forumedit -> scrape csrf -> POST /forume2.
    func postReply(fpid: String, text: String) async throws {
        if !loggedIn { try await login() }

        // 1. Get the reply editor page to scrape the CSRF token
        let editorData = try await get("forumedit", query: [
            URLQueryItem(name: "fpid", value: fpid),
            URLQueryItem(name: "reply", value: "1")
        ])
        guard let html = String(data: editorData, encoding: .utf8) else { throw RemoteError.badResponse }

        // 2. Scrape the CSRF token
        guard let csrf = extractCSRF(from: html) else { throw RemoteError.notAuthenticated }

        // Fossil's forume2 endpoint requires all of these fields. In
        // particular, `reply` is a mode flag, not the reply body.
        _ = try await post("forume2", form: [
            "csrf": csrf,
            "fpid": fpid,
            "reply": "1",
            "content": text,
            "submit": "Submit"
        ])
    }

    private func extractCSRF(from html: String) -> String? {
        let pattern = "name=\"csrf\" value=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: nsRange),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    // MARK: - Login

    /// POST `u`/`p` to `<base>/login`. Named-user login needs no CSRF token and
    /// no captcha (that path is anonymous-only in Fossil's login.c). Success sets
    /// a `fossil-*` cookie and redirects; failure is HTTP 401.
    private func login() async throws {
        guard let username, !username.isEmpty,
              let password, !password.isEmpty else { throw RemoteError.noCredentials }

        var req = URLRequest(url: url(for: "login"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncoded(["u": username, "p": password])

        let (_, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.badResponse }
        if http.statusCode == 401 { throw RemoteError.notAuthenticated }

        let hasCookie = urlSession.configuration.httpCookieStorage?
            .cookies(for: baseURL)?
            .contains { $0.name.hasPrefix("fossil-") } ?? false
        guard hasCookie else { throw RemoteError.notAuthenticated }
        loggedIn = true
    }

    // MARK: - Helpers

    private func rawGet(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var comps = URLComponents(url: url(for: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        let (data, response) = try await urlSession.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.badResponse }
        switch http.statusCode {
        case 200...299: return data
        case 401:       throw RemoteError.notAuthenticated
        default:        throw RemoteError.http(http.statusCode)
        }
    }

    private func rawPost(_ path: String, form: [String: String]) async throws -> Data {
        var req = URLRequest(url: url(for: path))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncoded(form)
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.badResponse }
        switch http.statusCode {
        case 200...299: return data
        case 401:       throw RemoteError.notAuthenticated
        default:        throw RemoteError.http(http.statusCode)
        }
    }

    private func url(for path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func formEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
