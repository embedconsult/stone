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

    /// Forces a reload to `url` directly, bypassing SwiftUI's state-diffing.
    /// Used for the self-heal recovery in RepoDetailView.handleLoadFailure():
    /// if the restarted server happens to land on the SAME port as before
    /// (rc==0 retarget, not a fresh bind -- meaning the failure was
    /// transient rather than a dead listener), `baseURL`'s value doesn't
    /// change, so nothing would otherwise trigger RepoWebView.updateUIView's
    /// origin check and no retry would actually happen.
    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
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
        // A self-healed server restart (FossilEngine.startServer(), see
        // ticket a7c72aba15) gets a fresh OS-assigned port -- the comment
        // this replaced ("the port is stable, nothing to refresh") was true
        // before self-heal existed but stopped being true once a restart
        // could produce a different port than the one this WKWebView is
        // still pointed at. Compare origins, not full URLs: ordinary in-page
        // navigation (the user browsing to a file, a forum post, etc.)
        // changes the path constantly and must NOT be clobbered by a reload
        // back to baseURL's root -- only a genuine port change (the signal
        // that a restart happened) should force a reload.
        guard let current = webView.url, origin(of: current) != origin(of: baseURL) else { return }
        webView.load(URLRequest(url: baseURL))
    }

    private func origin(of url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port ?? -1)"
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
    @State private var showingSyncLog = false
    @State private var showingGpcrEdit = false
    @State private var showingAgentConsole = false
    @State private var showingAgentSessions = false

    /// Ticket 0bbfd908e6, Option A (the maintainer's pick): a permanent
    /// address bar "might get in the way, but could be useful for debug" --
    /// so this is reachable only via a long-press on the nav title, not a
    /// visible control. Lets a repo path like /modreq be reached directly
    /// when Fossil's own rendered pages don't happen to link to it.
    @State private var showingPathPrompt = false
    @State private var debugPathInput = ""

    @State private var currentURL: URL?
    @State private var showingReplyComposer = false
    @State private var replyText = ""
    @State private var replyError: String?

    /// Guards the one-shot automatic self-heal in handleLoadFailure() below
    /// so a genuinely broken remote/repo doesn't retry forever -- reset to
    /// false on the next successful navigation, so a LATER, separate outage
    /// still gets its own automatic attempt.
    @State private var recoveryAttempted = false

    /// Owns the live WKWebView reference; see WebViewController's doc.
    @StateObject private var webController = WebViewController()

    var body: some View {
        Group {
            if let url = baseURL {
                RepoWebView(baseURL: url,
                            controller: webController,
                            onURLChange: { currentURL = $0; recoveryAttempted = false },
                            onLoadFailure: { message in
                                Task { await handleLoadFailure(message) }
                            })
                    .ignoresSafeArea(edges: .bottom)
            } else if let errorText {
                ContentUnavailableView {
                    Label("Couldn't start Fossil", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorText)
                } actions: {
                    Button("Retry") {
                        Task { await startServer() }
                    }
                }
            } else {
                ProgressView("Starting Fossil…")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // The system Back button always pops this whole view -- there's no
        // way to intercept a tap on it to decide "step back a page" first.
        // Ticket 052e109e94: the maintainer picked Option A (history-back on
        // "<") plus a separate Home button carrying the old "always exit"
        // behavior, rather than overloading one control with both meanings.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // Replaces the plain .navigationTitle(repo.name) so a long-press
            // can be attached to it (ticket 0bbfd908e6, Option A) -- SwiftUI
            // gives no way to intercept a gesture on the system-rendered
            // title itself, so this IS the title, styled to match.
            ToolbarItem(placement: .principal) {
                Text(repo.name)
                    .font(.headline)
                    .onLongPressGesture {
                        debugPathInput = ""
                        showingPathPrompt = true
                    }
            }
            // Left of Back, per the maintainer's decision: always leave the
            // repo and return to the list, regardless of in-page history --
            // the behavior "<" used to have before Option A changed its
            // meaning to history-back.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "house")
                }
                .accessibilityLabel("Repositories")
            }
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
                .accessibilityLabel("Back")
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
            // Native counterpart to the "Agent Console" WebView entry point
            // above: browses sessions/threads and composes instructions
            // in-app rather than in the server's rendered HTML (cd9d4bfcb2).
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAgentSessions = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .disabled(repo.remoteURL == nil)
                .accessibilityLabel("Agent Sessions")
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
        .alert("Go to Path", isPresented: $showingPathPrompt) {
            TextField("/modreq", text: $debugPathInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Go") { goToDebugPath() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a path on this repo's local server.")
        }
        .alert("Sync", isPresented: .constant(syncMessage != nil)) {
            // The parsed "N sent, M received" summary (parseArtifactCounts)
            // is a lossy read of Fossil's real sync output -- it can't show
            // e.g. the Round-trips count, which is exactly the kind of
            // detail needed to tell "nothing new to send" apart from "sync
            // gave up partway through negotiating a large push." Until now
            // that full output (RepoStore.lastSyncLog) was captured but
            // never shown anywhere -- see ticket 94ea2161f5.
            Button("View Log") { showingSyncLog = true }
            Button("OK") { syncMessage = nil }
        } message: {
            Text(syncMessage ?? "")
        }
        .sheet(isPresented: $showingSyncLog) {
            NavigationStack {
                ScrollView {
                    Text(store.lastSyncLog.isEmpty ? "(no sync output captured)" : store.lastSyncLog)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Sync Log")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showingSyncLog = false
                            syncMessage = nil
                        }
                    }
                }
            }
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
        .sheet(isPresented: $showingAgentSessions) {
            NavigationStack {
                AgentSessionListView(repo: repo)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingAgentSessions = false }
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

    /// Ticket 0bbfd908e6: navigate the local WebView to an arbitrary path
    /// on this repo's own server (e.g. "/modreq") -- reached only via the
    /// hidden long-press on the nav title, never a visible control.
    private func goToDebugPath() {
        guard let base = baseURL else { return }
        let trimmed = debugPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let relative = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        guard let url = URL(string: relative, relativeTo: base)?.absoluteURL else { return }
        webController.load(url)
    }

    private func startServer() async {
        errorText = nil
        recoveryAttempted = false
        let path = store.fileURL(for: repo).path
        // Defensive, not just clone-time (RepoStore.cloneRepo already does
        // this for new clones): repos cloned before this fix existed --
        // like the one behind ticket 94ea2161f5 -- need it applied here too,
        // on every open, so they self-heal without a fresh re-clone. See
        // RepoStore.disableLocalauthSetting's doc for why this matters.
        await store.disableLocalauthSetting(at: path)
        do {
            baseURL = try await FossilEngine.shared.startServer(repoPath: path)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// A page load failing with "Could not connect to the server" (see
    /// ticket a7c72aba15) means the local accept loop died -- possible at
    /// ANY point in a session, not just on first opening the repo, and
    /// FossilEngine's self-heal only runs inside startServer(), which
    /// nothing else re-invokes once the WKWebView is up (ordinary in-page
    /// navigation happens entirely inside the WebView, never through Swift
    /// again). Without this, a mid-session death -- e.g. the accept loop
    /// dying just before a forum-edit POST -- left the repo stuck showing
    /// the error until the user backed all the way out and back in, which
    /// is the only thing that re-triggers a fresh .task -> startServer().
    /// Try that recovery transparently once here instead of waiting for the
    /// user to discover the workaround; a manual Retry button in the error
    /// view (see body) covers the case where self-heal itself can't recover
    /// (e.g. genuine resource exhaustion outlasting a fresh listen()).
    private func handleLoadFailure(_ message: String) async {
        guard !recoveryAttempted else {
            baseURL = nil
            errorText = "Couldn't load the local Fossil page: \(message)"
            return
        }
        recoveryAttempted = true
        let path = store.fileURL(for: repo).path
        do {
            let url = try await FossilEngine.shared.startServer(repoPath: path)
            baseURL = url
            errorText = nil
            // Force the reload directly: if startServer() retargeted onto
            // the SAME port (a transient failure, not a dead listener), the
            // baseURL value above didn't change, so SwiftUI wouldn't call
            // updateUIView and the WebView would be left showing nothing.
            webController.load(url)
        } catch {
            baseURL = nil
            errorText = "Couldn't load the local Fossil page: \(message)"
        }
    }

    private func runSync() async {
        syncing = true
        defer { syncing = false }
        do {
            let output = try await store.sync(repo)
            // Ground truth (ticket 94ea2161f5): a stale/rotated remote
            // password let a sync report a plausible "sent" count while the
            // server actually refused the content -- Fossil's own client
            // can silently disable pushing mid-session without printing
            // anything. Check for that BEFORE trusting parseArtifactCounts'
            // numbers, so a rejected push reads as a loud warning, not as
            // "Sync complete."
            if let reason = RepoStore.detectAuthFailure(output) {
                syncMessage = "⚠️ Server refused the push: \(reason)."
            } else if let counts = RepoStore.parseArtifactCounts(output) {
                // A zero exit code only means the round-trip completed --
                // it does NOT mean anything was actually pushed. Show the
                // real counts rather than a blanket "Sync complete" so a
                // genuine no-op (e.g. nothing new to send) is still visible
                // as such.
                syncMessage = "Sync complete — \(counts.sent) sent, \(counts.received) received."
            } else {
                syncMessage = "Sync complete."
            }
        } catch {
            if case .fossil(let msg)? = error as? RepoStore.StoreError,
               let reason = RepoStore.detectAuthFailure(msg) {
                syncMessage = "⚠️ Server refused the push: \(reason)."
            } else {
                syncMessage = error.localizedDescription
            }
        }
    }
}
