import SwiftUI
import WebKit

/// The repo's remote Fossil site, live: opens the server's home page for this
/// repo, from which its own links reach every other page (timeline, forum,
/// tickets, the OCX console, any CGI extension). Unlike RepoDetailView, which
/// browses the local clone on the phone, this is the server itself.
///
/// Bridges RemoteSession's login cookie into WKWebView's own, separate
/// cookie store before loading, so the site opens already logged in as the
/// repo's remote user instead of showing a second login page.
struct RemoteSiteView: View {
    let repo: Repo

    @State private var pageURL: URL?
    @State private var shown: URL?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            remoteBanner
            Divider()
            content
        }
        .navigationTitle("Remote Site")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { OpenInSafariButton(url: shown ?? pageURL) }
        }
        .task { await prepare() }
    }

    /// Always visible while this screen is open: which host this is talking
    /// to, and that it is REMOTE -- distinct from RepoDetailView's local,
    /// on-device browsing, which never leaves the phone.
    private var remoteBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
            Text("Remote — \(hostLabel) — \(repo.name)")
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange)
    }

    private var hostLabel: String {
        guard let remote = repo.remoteURL,
              let url = URL(string: remote),
              let host = url.host else { return "unknown host" }
        return host
    }

    @ViewBuilder
    private var content: some View {
        if let pageURL {
            RemoteSiteWebView(url: pageURL, shown: $shown)
        } else if let errorText {
            ContentUnavailableView("Couldn't reach the remote site",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else {
            ProgressView("Connecting…")
        }
    }

    private func prepare() async {
        guard repo.remoteURL != nil else {
            errorText = "This repository has no remote configured."
            return
        }
        guard let home = Self.siteURL(repo) else {
            errorText = "Invalid remote address."
            return
        }
        do {
            try await Self.signIn(repo)
        } catch {
            errorText = error.localizedDescription
            return
        }
        pageURL = home
    }

    /// The repo's server address, without the login in it.
    static func siteURL(_ repo: Repo) -> URL? {
        guard let remote = repo.remoteURL, var comps = URLComponents(string: remote) else { return nil }
        comps.user = nil
        comps.password = nil
        return comps.url
    }

    /// Logs in first when there's a password, so pages that need it open
    /// without a second login; without one, browse anonymously.
    static func signIn(_ repo: Repo) async throws {
        guard let remote = repo.remoteURL, let password = CredentialStore.password(for: repo.id),
              let session = RemoteSession(remoteURL: remote, password: password) else { return }
        let cookie = try await session.sessionCookie()
        await RemoteSiteWebView.shareCookie(cookie)
    }

    /// The repository on this phone whose server `url` is on: its address,
    /// without the login, starts the link's. The longest match wins, so
    /// two repositories on one host each get their own links.
    static func repo(for url: URL, in repos: [Repo]) -> Repo? {
        let link = url.absoluteString
        let matches = repos.compactMap { repo -> (repo: Repo, base: String)? in
            guard var base = siteURL(repo)?.absoluteString else { return nil }
            while base.hasSuffix("/") { base.removeLast() }
            guard link == base || link.hasPrefix(base + "/") || link.hasPrefix(base + "?") else { return nil }
            return (repo, base)
        }
        return matches.max { $0.base.count < $1.base.count }?.repo
    }
}

/// A page of one of the phone's repositories' servers, opened from a
/// conversation's link: signed in as the repo's remote user, as Remote Site
/// is, so a page that needs a login doesn't send you to /login
/// (maintainer, ocx-console forum 649a29854b).
struct SignedInPage: View {
    let repo: Repo
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false
    @State private var shown: URL?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if ready {
                    RemoteSiteWebView(url: url, shown: $shown)
                } else if let errorText {
                    ContentUnavailableView("Couldn't sign in", systemImage: "exclamationmark.triangle",
                                           description: Text(errorText))
                } else {
                    ProgressView("Signing in…")
                }
            }
            .navigationTitle(repo.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) { OpenInSafariButton(url: shown ?? url) }
            }
        }
        .task {
            do {
                try await RemoteSiteView.signIn(repo)
                ready = true
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// Thin WKWebView wrapper for the remote site. Deliberately separate from
/// `RepoWebView` (the LOCAL embedded server) so local, on-device content and
/// the remote server are never rendered by the same code path.
struct RemoteSiteWebView: UIViewRepresentable {
    let url: URL
    /// The page showing now, for Open in Safari.
    @Binding var shown: URL?

    final class Coordinator {
        var watch: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(.stoneWrapLongWords)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.uiDelegate = NewTabsInPlace.shared
        webView.load(URLRequest(url: url))
        let shown = $shown
        context.coordinator.watch = webView.observe(\.url, options: [.initial, .new]) { view, _ in
            let now = view.url
            Task { @MainActor in shown.wrappedValue = now }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Injects the Fossil login cookie into the shared, persistent
    /// `WKWebsiteDataStore` cookie store, so this WebView -- which has its
    /// own cookie jar, separate from the `URLSession` RemoteSession logged in
    /// with -- loads already authenticated as the same user.
    static func shareCookie(_ cookie: HTTPCookie) async {
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
    }
}

/// Opens the page showing now in Safari (maintainer, ocx-console forum
/// 58613c1556: "stone doesn't give me a way to select opening in a
/// browser"). Safari signs in on its own; Stone's login stays in Stone.
struct OpenInSafariButton: View {
    let url: URL?

    var body: some View {
        Button {
            if let url { UIApplication.shared.open(url) }
        } label: {
            Image(systemName: "safari")
        }
        .disabled(url == nil)
        .accessibilityLabel("Open in Safari")
    }
}
