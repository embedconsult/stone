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

    /// Reloads the page on screen, so a sync that brought new content shows
    /// it here, not only on the next page opened.
    func reload() {
        webView?.reload()
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

extension WKUserScript {
    /// Lets a long unbroken word in a timeline entry (a branch name, a path,
    /// a URL) break anywhere. Otherwise Fossil's timeline table widens to fit
    /// its longest word, every row's text runs off the right edge of the
    /// phone, and the page reads as cut off (forum e320232451, stone's
    /// 189da093f3: "i cannot read the timeline"). And keeps the time and
    /// graph columns as narrow as their content (width: 1%, the usual way
    /// to shrink a table column): once the comments could break anywhere,
    /// the phone gave the time column about half the screen (stone's
    /// screenshot of build 36f610778c79, in the dark skin). Added to every
    /// page, so it holds whatever skin the server or the clone uses.
    @MainActor static var stoneWrapLongWords: WKUserScript {
        WKUserScript(
        source: """
        (function() {
          var style = document.createElement('style');
          style.textContent = '.timelineModernComment, .timelineModernDetail, ' +
            '.timelineComment, .timelineDetailCell, .timelineCompactCell, ' +
            '.timelineVerboseCell, .timelineColumnarCell { overflow-wrap: anywhere; } ' +
            'table.timelineTable { width: 100%; } ' +
            'td.timelineTime, td.timelineGraph { width: 1%; }';
          (document.head || document.documentElement).appendChild(style);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true)
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
        config.userContentController.addUserScript(.stoneWrapLongWords)
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
    @State private var showingSyncResult = false
    @State private var showingRemoteSite = false

    /// Ticket 0bbfd908e6, Option A (the maintainer's pick): a permanent
    /// address bar "might get in the way, but could be useful for debug" --
    /// so this is reachable only via a long-press on the Back button (it was the nav title until the title went), not a
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
                // Ticket 0bbfd908e6's hidden debug entry, once a long-press
                // on the title. The title went: with three buttons on each
                // side it showed one letter of the repo name (stone, build
                // 36f610778c79: "title isn't helpful").
                .contextMenu {
                    Button {
                        debugPathInput = ""
                        showingPathPrompt = true
                    } label: {
                        Label("Go to Path", systemImage: "arrow.turn.down.right")
                    }
                }
            }
            // This repo's latest sync, as on the repo list: tap for its
            // results. Nothing pops up after a sync. On the leading side so
            // each side holds three buttons.
            ToolbarItem(placement: .topBarLeading) {
                if !syncing {
                    RecentSyncButton(record: store.syncRecords[repo.id]) { showingSyncResult = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingRemoteSite = true
                } label: {
                    Image(systemName: "globe")
                }
                .disabled(repo.remoteURL == nil)
                .accessibilityLabel("Remote Site")
            }
            // This repo's conversations, read from its local clone. (This
            // button used to open the agent-session list fed by trunk's
            // daemon endpoints, which no longer exist.)
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.repoConversations(repo.id)) {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .accessibilityLabel("Conversations")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await runSync() }
                } label: {
                    if syncing { ProgressView() }
                    else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .disabled(syncing || repo.remoteURL == nil)
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
        .sheet(isPresented: $showingSyncResult) {
            if let record = store.syncRecords[repo.id] {
                SyncResultView(repoName: repo.name, record: record)
            }
        }
        .sheet(isPresented: $showingRemoteSite) {
            NavigationStack {
                RemoteSiteView(repo: repo)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingRemoteSite = false }
                        }
                    }
            }
        }
    }

    /// Ticket 0bbfd908e6: navigate the local WebView to an arbitrary path
    /// on this repo's own server (e.g. "/modreq") -- reached only via the
    /// hidden long-press menu on the Back button, never a visible control.
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

    /// Any sync of this repo, from here or elsewhere, shows as the spinner.
    private var syncing: Bool { store.syncingRepos.contains(repo.id) }

    /// The result is recorded by RepoStore.sync and shown by the status
    /// icon beside the Sync button; nothing pops up.
    private func runSync() async {
        guard let output = try? await store.sync(repo, trigger: .syncButton) else { return }
        let received = RepoStore.parseArtifactCounts(output)?.received ?? 0
        await rescanAfterSync(receivedCounts: [repo.id: received])
        if received > 0 { webController.reload() }
    }
}

/// The console: Stone's own page, shipped in the app (Console/ in the
/// bundle; maintainer, 2026-10-31: "If it is Stone's console, it should be
/// part of Stone."), Stone's top-level greeting across every project. Its
/// tools are answered by ConsoleBridge from the clones on the phone, so it
/// needs no server and works offline; a record chosen on it pushes its own
/// clone's view (RepoDetailView), as a notification does.
struct ConsoleView: View {
    @EnvironmentObject private var store: RepoStore
    @StateObject private var console = ConsoleBridge()

    var body: some View {
        Group {
            if let page = ConsoleBridge.page {
                ConsolePage(page: page, console: console)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("No console in this build", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle("Console")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            console.store = store
            console.open = { target, path in DeepLinkRouter.shared.route(repoID: target.id, path: path) }
        }
    }
}

/// The web view the console page runs in, with ConsoleBridge as its "ocx"
/// message handler.
struct ConsolePage: UIViewRepresentable {
    let page: URL
    let console: ConsoleBridge

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(console, contentWorld: .page, name: "ocx")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.accessibilityIdentifier = "consoleWebView"
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// The console page's tools. The page calls `tool(name, input)`, which in
/// Stone is `webkit.messageHandlers.ocx.postMessage({tool, input})`; it
/// resolves to the tool's answer as a JSON string, or `{"stopped": WHY}`, and
/// never rejects. The tools and the card format are the contract shared with
/// OCX's console (ollama wiki "Console plan"); answers come from the C bridge
/// (`stone_fossil_card`), which Linux checks against OCX's shared examples,
/// so this only routes. Any clone's card/NAME pages count: a card is named by
/// its project and name, and is answered across every clone.
@MainActor
final class ConsoleBridge: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {
    weak var store: RepoStore?
    var open: ((Repo, String) -> Void)?

    /// The console page in the app bundle.
    nonisolated static let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Console")

    /// Only a page of the bundle's Console folder may call the tools.
    nonisolated static func isConsolePage(_ url: URL?) -> Bool {
        guard let url, url.isFileURL, let page else { return false }
        return url.standardizedFileURL.path.hasPrefix(page.deletingLastPathComponent().standardizedFileURL.path + "/")
    }

    /// Whether any clone has a card/ page, so the console has something to
    /// say (StoneApp opens it at launch only then).
    nonisolated static func anyCards(_ paths: [String]) -> Bool {
        paths.contains { !FossilQuery.rows($0, "SELECT 1 FROM tag WHERE tagname GLOB 'wiki-card/*' LIMIT 1").isEmpty }
    }

    nonisolated static func stopped(_ why: String) -> String {
        json(["stopped": why]) ?? "{\"stopped\": \"stopped\"}"
    }

    nonisolated static func json(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, Self.isConsolePage(message.frameInfo.request.url) else {
            replyHandler(Self.stopped("not the console page"), nil)
            return
        }
        guard let body = message.body as? [String: Any], let tool = body["tool"] as? String else {
            replyHandler(Self.stopped("no tool named"), nil)
            return
        }
        let input = body["input"] as? [String: Any] ?? [:]
        Task { replyHandler(await answer(tool, input), nil) }
    }

    /// A clone, with its file and its project-name.
    private struct Clone {
        let repo: Repo
        let path: String
        let project: String
    }

    private func answer(_ tool: String, _ input: [String: Any]) async -> String {
        guard let store else { return Self.stopped("Stone isn't ready") }
        let clones = store.repos.map { repo -> Clone in
            let path = store.fileURL(for: repo).path
            let project = FossilQuery.rows(path, "SELECT value FROM config WHERE name='project-name'").first?.first ?? ""
            return Clone(repo: repo, path: path, project: project)
        }
        let now = input["now"] as? String ?? ISO8601DateFormatter().string(from: Date())
        switch tool {
        case "card":
            guard let name = input["name"] as? String else { return Self.stopped("card needs a name") }
            let project = input["project"] as? String
            guard let home = clones.first(where: { (project == nil || $0.project == project)
                                                    && Self.cardNames($0.path).contains(name) }) else {
                return Self.stopped("no card/\(name) page\(project.map { " in \($0)" } ?? "")")
            }
            return await card(name, home, clones, input["for"] as? String, now)
        case "cards":
            var cards: [[String: Any]] = []
            var asOf: String?
            for home in clones {
                for name in Self.cardNames(home.path) {
                    let text = await card(name, home, clones, input["for"] as? String, now)
                    guard let data = text.data(using: .utf8),
                          let found = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          found["stopped"] == nil else { continue }
                    cards.append(["project": home.project, "name": name, "title": found["title"] ?? "",
                                  "count": found["count"] ?? 0, "say": found["say"] ?? ""])
                    if let at = found["as_of"] as? String, at > (asOf ?? "") { asOf = at }
                }
            }
            var answer: [String: Any] = ["cards": cards]
            if let asOf { answer["as_of"] = asOf }
            return Self.json(answer) ?? Self.stopped("couldn't write the cards")
        case "open":
            guard let project = input["project"] as? String,
                  let hash = input["hash"] as? String, !hash.isEmpty, hash.allSatisfy(\.isHexDigit) else {
                return Self.stopped("open needs a project and a hash")
            }
            guard let target = clones.first(where: { $0.project == project }) else {
                return Self.stopped("no clone of \(project) on this phone")
            }
            open?(target.repo, "/info/\(hash.lowercased())")
            return "{}"
        default:
            return Self.stopped("Stone has no tool \(tool) yet")
        }
    }

    nonisolated private static func cardNames(_ path: String) -> [String] {
        FossilQuery.rows(path, "SELECT substr(tagname, 11) FROM tag WHERE tagname GLOB 'wiki-card/*' ORDER BY tagname")
            .compactMap(\.first)
    }

    /// card/NAME read from its own clone, then answered across every clone.
    /// `$viewer` is `login`, else the login on that clone's remote.
    private func card(_ name: String, _ home: Clone, _ clones: [Clone], _ login: String?, _ now: String) async -> String {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return Self.stopped("no card named \(name)")
        }
        let page = await FossilEngine.shared.run(["wiki", "export", "card/\(name)", "-R", home.path])
        guard page.succeeded, !page.output.isEmpty else { return Self.stopped("no card/\(name) page") }
        let remoteLogin = RepoStore.splitRemoteURL(home.repo.remoteURL ?? "").username
        let viewer = login ?? (remoteLogin.isEmpty ? "nobody" : remoteLogin)
        let repos = clones.map(\.path)
        let answer = await Task.detached {
            FossilQuery.card(repos, name: name, definition: page.output, viewer: viewer, now: now)
        }.value
        return answer ?? Self.stopped("card/\(name) isn't a card this Stone can answer")
    }
}
