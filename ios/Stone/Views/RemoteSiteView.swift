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
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            remoteBanner
            Divider()
            content
        }
        .navigationTitle("Remote Site")
        .navigationBarTitleDisplayMode(.inline)
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
            RemoteSiteWebView(url: pageURL)
        } else if let errorText {
            ContentUnavailableView("Couldn't reach the remote site",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else {
            ProgressView("Connecting…")
        }
    }

    private func prepare() async {
        guard let remote = repo.remoteURL,
              var comps = URLComponents(string: remote) else {
            errorText = "This repository has no remote configured."
            return
        }
        comps.user = nil
        comps.password = nil
        guard let home = comps.url else {
            errorText = "Invalid remote address."
            return
        }
        // Log in first when there's a password, so pages that need it open
        // without a second login; without one, browse anonymously.
        if CredentialStore.password(for: repo.id) != nil,
           let session = RemoteSession(remoteURL: remote, password: CredentialStore.password(for: repo.id)) {
            do {
                let cookie = try await session.sessionCookie()
                await RemoteSiteWebView.shareCookie(cookie)
            } catch {
                errorText = error.localizedDescription
                return
            }
        }
        pageURL = home
    }
}

/// Thin WKWebView wrapper for the remote site. Deliberately separate from
/// `RepoWebView` (the LOCAL embedded server) so local, on-device content and
/// the remote server are never rendered by the same code path.
private struct RemoteSiteWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
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
