import Foundation
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
        webView?.load(RepoWebView.freshRequest(for: url))
    }

    /// Ticket 98c06fb7a7's per-kind routing: a decision/try-this deep link
    /// asks for the reply composer to be focused once its ticket page
    /// finishes loading, so the maintainer can start typing an answer
    /// immediately instead of hunting for Fossil's own "Append Change"
    /// field. Best-effort, not a confirmed DOM contract: Fossil's stock
    /// ticket-view theme names that field's textarea `comment`, so this
    /// tries the common id/name shapes and does nothing if neither matches
    /// (an unusual skin, say) -- there is no local page left un-openable
    /// either way, just a composer that isn't pre-focused.
    func focusTicketComposer() {
        let js = """
        (function() {
            var el = document.getElementById('comment') || document.querySelector('textarea[name="comment"]');
            if (!el) { return false; }
            el.scrollIntoView({block: 'center'});
            el.focus();
            return true;
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
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
        // Lets StoneUITests wait for this specific WKWebView (not just any
        // web view that happens to be on screen, e.g. from a sheet) via
        // app.webViews["repoWebView"] as the "a page actually rendered"
        // signal for the browse flow (ticket cfcc7e04d5).
        webView.accessibilityIdentifier = "repoWebView"
        webView.load(Self.freshRequest(for: baseURL))
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
        webView.load(Self.freshRequest(for: baseURL))
    }

    private func origin(of url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port ?? -1)"
    }

    /// Every load this Swift code drives (first open, a server-restart
    /// reload, self-heal recovery) bypasses the cache, not just
    /// `.useProtocolCachePolicy` -- ticket 5d90457d88: a published skin
    /// change not showing up is at least partly explained by a stale
    /// `/style.css` served from this WKWebView's own in-memory HTTP cache.
    /// The `.nonPersistent()` data store in `makeUIView` already means
    /// nothing survives a fresh visit to this screen, but within one
    /// session a cached response can still be reused across these
    /// Swift-driven reloads without this.
    static func freshRequest(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
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

    /// Ticket 1a55c5d8b8: a tapped maintainer-request notification pushes
    /// this repo (StoneApp) and, once the local server is up, this consumes
    /// the request's path (e.g. "/tktview/<uuid>") and clears it so a later
    /// unrelated visit to this repo doesn't replay a stale deep link.
    @ObservedObject private var deepLinkRouter = DeepLinkRouter.shared

    @State private var currentURL: URL?
    @State private var showingReplyComposer = false
    @State private var replyText = ""
    @State private var replyError: String?

    /// Guards the one-shot automatic self-heal in handleLoadFailure() below
    /// so a genuinely broken remote/repo doesn't retry forever -- reset to
    /// false on the next successful navigation, so a LATER, separate outage
    /// still gets its own automatic attempt.
    @State private var recoveryAttempted = false

    /// Guards `consumePendingDeepLink()` so it fires at most once per
    /// `startServer()` run -- `onURLChange` fires again for the very
    /// redirect that consuming the deep link itself causes, and again for
    /// any further in-page browsing after that.
    @State private var deepLinkConsumed = false

    /// Set by `consumePendingDeepLink()` when the just-triggered navigation
    /// is a decision/try-this deep link -- consumed on the NEXT
    /// `onURLChange` (the one firing once that navigation actually
    /// finishes), which is the earliest point the composer field could
    /// exist in the DOM to focus.
    @State private var pendingComposerFocus = false

    /// Set by `consumePendingDeepLink()` for a merge card opened locally
    /// only because there was no remote to build a console link from --
    /// shown once as a banner, then cleared.
    @State private var pendingApprovalNote: String?

    /// Owns the live WKWebView reference; see WebViewController's doc.
    @StateObject private var webController = WebViewController()

    var body: some View {
        Group {
            if let url = baseURL {
                RepoWebView(baseURL: url,
                            controller: webController,
                            onURLChange: { url in
                                currentURL = url
                                recoveryAttempted = false
                                // Checked BEFORE consumePendingDeepLink() so
                                // a focus request set by a navigation this
                                // same closure invocation just triggered
                                // isn't acted on until the NEXT invocation,
                                // once that navigation has actually finished.
                                if pendingComposerFocus {
                                    webController.focusTicketComposer()
                                    pendingComposerFocus = false
                                }
                                consumePendingDeepLink()
                            },
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
        // Ticket 98c06fb7a7: shown once when a merge-card deep link had to
        // fall back to this local ticket page (no remote configured to
        // build the console's merge-review link from) -- the Approve
        // control isn't on this page, so say so rather than leaving the
        // maintainer to discover that themselves.
        .alert("Approval Needs the Console", isPresented: .constant(pendingApprovalNote != nil)) {
            Button("OK") { pendingApprovalNote = nil }
        } message: {
            Text(pendingApprovalNote ?? "")
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
        deepLinkConsumed = false
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

    /// If a notification deep-linked into this exact repo, navigate to its
    /// ticket page once the WKWebView has actually finished its first load
    /// (called from `onURLChange`) -- calling this any earlier would race
    /// `RepoWebView.makeUIView`, which creates the WKWebView (and hands it to
    /// `webController`) asynchronously relative to `startServer()` setting
    /// `baseURL`.
    private func consumePendingDeepLink() {
        guard !deepLinkConsumed else { return }
        deepLinkConsumed = true
        guard let base = baseURL,
              let destination = deepLinkRouter.pending,
              destination.repoID == repo.id else { return }
        let relative = destination.path.hasPrefix("/") ? String(destination.path.dropFirst()) : destination.path
        if let url = URL(string: relative, relativeTo: base)?.absoluteURL {
            webController.load(url)
            pendingComposerFocus = destination.focusComposer
        }
        if let note = destination.note {
            pendingApprovalNote = note
        }
        deepLinkRouter.clear()
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

    /// Recomputes the badge/Requests screen after a single-repo sync, same
    /// as "Sync All" -- ticket 4c75227cc7: they must be recomputed from the
    /// current scan after every sync. `MaintainerRequestStore.scanAfterSync`
    /// is still handed every repo in the store (never a subset -- it
    /// replaces its whole result set wholesale, so dropping a repo would
    /// make its requests vanish), but `receivedCounts` limits the actual
    /// per-repo rescan work to just this one repo (ticket d4d02c604f): every
    /// other repo's tally is implicitly zero this round, so its existing
    /// rows are carried over instead of re-scanned.
    private func rescanAfterSync(receivedCounts: [UUID: Int]) async {
        await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: receivedCounts)
    }

    private func runSync() async {
        syncing = true
        defer { syncing = false }
        do {
            let output = try await store.sync(repo)
            let received = RepoStore.parseArtifactCounts(output)?.received ?? 0
            await rescanAfterSync(receivedCounts: [repo.id: received])
            // Ground truth (ticket f0c612c027): a LOCAL SQLite failure
            // (e.g. this phone's own clone rejecting a post-sync write with
            // SQLITE_AUTH) must be checked BEFORE detectAuthFailure -- its
            // "not authorized" text would otherwise be misread as the
            // server refusing the push. Ground truth (ticket 94ea2161f5): a
            // stale/rotated remote password let a sync report a plausible
            // "sent" count while the server actually refused the content --
            // Fossil's own client can silently disable pushing mid-session
            // without printing anything. Check for that BEFORE trusting
            // parseArtifactCounts' numbers, so a rejected push reads as a
            // loud warning, not as "Sync complete."
            if let reason = RepoStore.detectLocalSQLiteFailure(output) {
                syncMessage = "⚠️ Sync failed on this phone: \(reason)."
            } else if let reason = RepoStore.detectAuthFailure(output) {
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
            if case .fossil(let msg)? = error as? RepoStore.StoreError, let reason = RepoStore.detectLocalSQLiteFailure(msg) {
                syncMessage = "⚠️ Sync failed on this phone: \(reason)."
            } else if case .fossil(let msg)? = error as? RepoStore.StoreError, let reason = RepoStore.detectAuthFailure(msg) {
                syncMessage = "⚠️ Server refused the push: \(reason)."
            } else {
                syncMessage = error.localizedDescription
            }
        }
    }
}
