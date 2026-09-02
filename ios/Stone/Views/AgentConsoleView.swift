import SwiftUI
import WebKit

/// Entry point to the remote's own agent console (`/ext/agent` -- the
/// forum-driven sessions/thread UI Ollama-Codex serves) from a repo that has
/// one. Renders the server's real HTML in a WKWebView (anti-drift, the same
/// approach Stone already uses for its own local pages) rather than a
/// native re-implementation -- this is the console *entry point*, not the
/// full native Sessions/Thread UI (that stays cd9d4bfcb2's larger scope).
///
/// Bridges RemoteSession's login cookie into WKWebView's own, separate
/// cookie store before loading, so this opens already authenticated as the
/// same user instead of showing a second, redundant login page -- resolving
/// contract C-A in docs/design/ollama-codex-client.md ("exact mechanism for
/// a headless remote login cookie feeding ... a visible WebView").
struct AgentConsoleView: View {
    let repo: Repo

    @State private var pageURL: URL?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            remoteBanner
            Divider()
            content
        }
        .navigationTitle("Agent Console")
        .navigationBarTitleDisplayMode(.inline)
        .task { await prepare() }
    }

    /// Always-visible while this screen is open: which host this is actually
    /// talking to, and that it's REMOTE -- distinct from RepoDetailView's
    /// local, on-device browsing, which never leaves the phone. This is the
    /// "always be able to tell when you're on a remote surface" requirement.
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
            AgentConsoleWebView(url: pageURL)
        } else if let errorText {
            ContentUnavailableView("Couldn't reach the agent console",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else {
            ProgressView("Connecting…")
        }
    }

    private func prepare() async {
        guard let remote = repo.remoteURL else {
            errorText = "This repository has no remote configured."
            return
        }
        guard let session = RemoteSession(remoteURL: remote, password: CredentialStore.password(for: repo.id)) else {
            errorText = "Invalid remote address."
            return
        }
        do {
            let cookie = try await session.sessionCookie()
            await AgentConsoleWebView.shareCookie(cookie)
            guard var comps = URLComponents(string: remote) else {
                errorText = "Invalid remote address."
                return
            }
            comps.user = nil
            comps.password = nil
            comps.path = (comps.path as NSString).appendingPathComponent("ext/agent")
            guard let url = comps.url else {
                errorText = "Invalid remote address."
                return
            }
            pageURL = url
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Thin WKWebView wrapper for the console page. Deliberately separate from
/// `RepoWebView` (which is specifically the LOCAL embedded server) so the
/// two surfaces -- local, on-device content vs. this remote page -- are
/// never rendered by the same code path and can't be confused for one
/// another.
private struct AgentConsoleWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Injects the Fossil login cookie into the shared, persistent
    /// `WKWebsiteDataStore` cookie store so this WebView -- which has its own
    /// cookie jar, separate from the `URLSession` RemoteSession logged in
    /// with -- loads the console already authenticated as the same user.
    static func shareCookie(_ cookie: HTTPCookie) async {
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
    }
}
