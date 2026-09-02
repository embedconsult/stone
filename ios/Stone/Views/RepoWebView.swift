import SwiftUI
import WebKit

/// Bridges imperative `WKWebView` control (go back, know whether there's
/// anywhere to go back to) out to SwiftUI. `RepoWebView` is a
/// `UIViewRepresentable`, so its parent has no other way to reach the actual
/// `WKWebView` instance it creates -- this is that seam, held by
/// `RepoDetailView` so the toolbar's Back button can decide between "step
/// back a page" and "leave the repo."
///
/// Status: one candidate implementation for ticket 052e109e94 (Back-button
/// design, design_input=confirm) -- kept on the branch for the maintainer to
/// evaluate alongside the other options (swipe-gesture navigation, a
/// separate dedicated control, a skin-level nav affordance), not a decision
/// made unilaterally. Whether this merges is the maintainer's call.
@MainActor
final class WebViewController: ObservableObject {
    @Published fileprivate(set) var canGoBack = false
    fileprivate weak var webView: WKWebView?

    func goBack() {
        webView?.goBack()
    }
}

/// Hosts a `WKWebView` pointed at the in-process Fossil server, presenting
/// Fossil's own HTML UI. This is the whole point of the app's UI strategy:
/// render Fossil's real pages so there is zero drift from upstream.
struct RepoWebView: UIViewRepresentable {
    let baseURL: URL
    let controller: WebViewController
    var onURLChange: ((URL) -> Void)?
    var onLoadFailure: ((String) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // localhost session only
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: baseURL))
        controller.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // The server's port is stable for the app session; nothing to refresh.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: RepoWebView

        init(_ parent: RepoWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url {
                parent.onURLChange?(url)
            }
            parent.controller.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            parent.onLoadFailure?(nsError.localizedDescription)
        }
    }
}

/// Wrapper screen: starts the server for a repo, then shows its web UI.
struct RepoDetailView: View {
    let repo: Repo
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: URL?
    @State private var errorText: String?
    @State private var syncing = false
    @State private var syncMessage: String?
    @State private var showingGpcrEdit = false
    @State private var showingAgentConsole = false

    @State private var currentURL: URL?
    @State private var showingReplyComposer = false
    @State private var replyText = ""
    @State private var replyError: String?

    /// Owns the live WKWebView reference; see WebViewController's doc.
    @StateObject private var webController = WebViewController()

    var body: some View {
        Group {
            if let url = baseURL {
                RepoWebView(baseURL: url,
                            controller: webController,
                            onURLChange: { currentURL = $0 },
                            onLoadFailure: { message in
                                baseURL = nil
                                errorText = "Couldn't load the local Fossil page: \(message)"
                            })
                    .ignoresSafeArea(edges: .bottom)
            } else if let errorText {
                ContentUnavailableView("Couldn't start Fossil",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(errorText))
            } else {
                ProgressView("Starting Fossil…")
            }
        }
        .navigationTitle(repo.name)
        .navigationBarTitleDisplayMode(.inline)
        // The system Back button always pops this whole view -- there's no
        // way to intercept a tap on it to decide "step back a page" first.
        // Replace it with our own, which does what an ordinary browser's
        // back button does: step back through pages viewed within this
        // repo (WKWebView's own history) before finally leaving the repo.
        // See ticket 052e109e94 -- this is one candidate among several the
        // maintainer is choosing between, kept here for evaluation.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if webController.canGoBack {
                        webController.goBack()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAgentConsole = true
                } label: {
                    Image(systemName: "terminal")
                }
                .disabled(repo.remoteURL == nil)
                .accessibilityLabel("Agent Console")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingGpcrEdit = true
                } label: {
                    Image(systemName: "mic")
                }
                .disabled(repo.remoteURL == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    if forumPostID(from: currentURL) != nil {
                        Button {
                            showingReplyComposer = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                    Button {
                        Task { await runSync() }
                    } label: {
                        if syncing { ProgressView() }
                        else { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(syncing || repo.remoteURL == nil)
                }
            }
        }
        .task { await startServer() }
        .alert("Sync", isPresented: .constant(syncMessage != nil)) {
            Button("OK") { syncMessage = nil }
        } message: {
            Text(syncMessage ?? "")
        }
        .sheet(isPresented: $showingGpcrEdit) {
            NavigationStack {
                GpcrEditView(repo: repo)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingGpcrEdit = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingAgentConsole) {
            NavigationStack {
                AgentConsoleView(repo: repo)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingAgentConsole = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingReplyComposer) {
            VStack(spacing: 20) {
                Text("Reply to Thread").font(.headline)
                TextEditor(text: $replyText)
                    .frame(height: 200)
                    .border(Color.gray, width: 1)
                if let err = replyError {
                    Text(err).foregroundColor(.red).font(.caption)
                }
                HStack {
                    Button("Cancel") {
                        showingReplyComposer = false
                        replyText = ""
                        replyError = nil
                    }
                    Spacer()
                    Button("Send") {
                        Task { await sendReply() }
                    }
                    .disabled(replyText.isEmpty)
                }
            }
            .padding()
            .presentationDetents([.medium])
        }
    }

    /// Fossil emits both query-style links (`forum?fpid=...`) and the normal
    /// path-style links (`forum/<post-id>`). The embedded loopback server keeps
    /// the path shape, so support both rather than hiding the composer on the
    /// usual forum page.
    private func forumPostID(from url: URL?) -> String? {
        guard let url else { return nil }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: { $0.name == "fpid" || $0.name == "name" })?.value,
           !value.isEmpty {
            return value
        }

        let path = url.path.split(separator: "/").map(String.init)
        guard let route = path.lastIndex(where: { $0 == "forum" || $0 == "forumedit" }),
              path.indices.contains(route + 1) else { return nil }
        let value = path[route + 1]
        return value.isEmpty ? nil : value
    }

    private func sendReply() async {
        guard let fpid = forumPostID(from: currentURL),
              let remoteURL = repo.remoteURL else { return }

        let password = CredentialStore.password(for: repo.id)
        guard let session = RemoteSession(remoteURL: remoteURL, password: password) else {
            replyError = "Invalid remote session configuration."
            return
        }

        do {
            try await session.postReply(fpid: fpid, text: replyText)
            showingReplyComposer = false
            replyText = ""
            replyError = nil
        } catch {
            replyError = error.localizedDescription
        }
    }

    private func startServer() async {
        let path = store.fileURL(for: repo).path
        do {
            baseURL = try await FossilEngine.shared.startServer(repoPath: path)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func runSync() async {
        syncing = true
        defer { syncing = false }
        do {
            let output = try await store.sync(repo)
            // A zero exit code only means the round-trip completed -- it does
            // NOT mean anything was actually pushed. A remote identity
            // lacking write capability makes Fossil silently decline to send
            // content while still exiting 0. Show the real counts rather than
            // a blanket "Sync complete" so that no-op is visible instead of
            // reading as success.
            if let counts = RepoStore.parseArtifactCounts(output) {
                syncMessage = "Sync complete — \(counts.sent) sent, \(counts.received) received."
            } else {
                syncMessage = "Sync complete."
            }
        } catch {
            syncMessage = error.localizedDescription
        }
    }
}
