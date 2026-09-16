import SwiftUI
import UIKit

/// Native thread view for one Ollama-Codex session: posts, a live-status
/// banner fed by the `:8443` SSE stream (falling back to poll-on-sync when
/// offline or unavailable), and a composer that posts a new instruction as a
/// forum reply -- which is how the design doc's forum-as-work-queue contract
/// (C-B) queues a turn: the reply becomes forum activity the server daemon
/// polls and drives.
///
/// This is the native counterpart to `AgentConsoleView`'s WebView entry
/// point into the server's own console -- cd9d4bfcb2's own scope (Gap 2 of
/// agent-client-scoping.md).
struct AgentThreadView: View {
    let repo: Repo
    let session: AgentSessionSummary

    @State private var posts: [AgentThreadPost] = []
    /// Plain-text render of each post's HTML, precomputed in loadPosts() --
    /// see that function's doc for why this must never happen inside `body`.
    @State private var plainTextByHash: [String: String] = [:]
    @State private var loadError: String?

    @State private var liveStatus: LiveStatus = .connecting
    @State private var eventTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?

    @State private var showingComposer = false
    @State private var composerText = ""
    @State private var sending = false
    @State private var sendError: String?

    enum LiveStatus: Equatable {
        case connecting
        case live(String)  // last event's human-readable summary
        case polling       // SSE unavailable -- falling back to sync-on-interval
        case offline(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            Divider()
            content
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingComposer = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New Instruction")
            }
        }
        .task { await loadPosts() }
        .task { await connectLive() }
        .onDisappear {
            eventTask?.cancel()
            pollTask?.cancel()
        }
        .sheet(isPresented: $showingComposer) {
            composerSheet
                .presentationDetents([.medium])
        }
    }

    // MARK: - Status banner

    private var statusBanner: some View {
        HStack(spacing: 6) {
            switch liveStatus {
            case .connecting:
                ProgressView().controlSize(.small).tint(.white)
                Text("Connecting…")
            case .live(let summary):
                Image(systemName: "dot.radiowaves.left.and.right")
                Text(summary).lineLimit(1)
            case .polling:
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Live updates unavailable — checking for replies periodically")
                    .lineLimit(1)
            case .offline(let reason):
                Image(systemName: "wifi.slash")
                Text(reason).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bannerColor)
    }

    private var bannerColor: Color {
        switch liveStatus {
        case .live: return .green
        case .connecting, .polling: return .orange
        case .offline: return .red
        }
    }

    // MARK: - Posts

    @ViewBuilder
    private var content: some View {
        if let loadError, posts.isEmpty {
            ContentUnavailableView("Couldn't load this thread",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(loadError))
        } else {
            // A thread reads chronologically oldest-first (matches the
            // server's session_posts order), but a List otherwise opens
            // scrolled to the top -- the maintainer's own live-testing
            // feedback on this exact screen: "the default is to show the
            // top of the thread, so scrolling to the bottom is a real pain."
            // Chat-style UIs open on the newest message; jump there on
            // every load/refresh (initial .task, the reply-composer's
            // reload, and each poll-fallback tick all funnel through
            // loadPosts(), so `posts` changing is the one signal that
            // covers all of them) rather than leaving the reader to find it
            // themselves each time.
            //
            // ScrollView + LazyVStack, not List: the maintainer's follow-up
            // live-test report on the first .textSelection(.enabled) commit
            // ("Copy is available, but i cannot seem to select text") showed
            // the long-press menu working but the drag-to-extend selection
            // handles not responding. List is backed by a UITableView, whose
            // own pan gesture recognizer competes with the pan-based
            // recognizer UITextInteraction installs to drive those handles.
            // A plain ScrollView has no such competing recognizer.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(posts) { post in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(post.user).font(.subheadline.bold())
                                    Spacer()
                                    Text(post.role).font(.caption2).foregroundStyle(.secondary)
                                }
                                // Reads the precomputed conversion (see loadPosts())
                                // -- deliberately never calls plainText(fromHTML:)
                                // here. Falling back to the raw HTML string if a
                                // post somehow has no precomputed entry is ugly but
                                // harmless; calling the converter from inside this
                                // row closure is not (see plainText(fromHTML:)'s
                                // doc).
                                // SelectableText, not Text + .textSelection(.enabled):
                                // two prior on-device reports on this exact ticket
                                // (builds 67a080d665c0 and 2e2022d7b568) both showed
                                // the long-press Copy/Share menu working but no
                                // actual selection UI (word highlight, drag handles)
                                // -- first inside a List, then inside a ScrollView +
                                // LazyVStack after the List was swapped out to chase
                                // this exact bug. Swapping the container twice
                                // didn't fix it, which points at SwiftUI's
                                // .textSelection(.enabled) modifier itself, not its
                                // container, so this drops down to a plain
                                // UITextView (see SelectableText below), which gets
                                // real native selection for free -- the same
                                // mechanism the SwiftUI modifier is a thin wrapper
                                // over.
                                SelectableText(text: plainTextByHash[post.hash] ?? post.html)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 16)
                            .id(post.id)
                            Divider()
                        }
                    }
                }
                .onChange(of: posts) { _, newPosts in
                    guard let lastID = newPosts.last?.id else { return }
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    /// Strips the server-rendered HTML down to plain text for the mobile
    /// list -- read-only-first per the design doc's Gap 2.2, and a scrolling
    /// list of embedded WebViews is neither good UX nor good performance.
    /// Reuses the same system HTML-to-text conversion GpcrEditClient uses
    /// for the same reason: don't hand-roll an HTML parser for arbitrary
    /// server markup.
    ///
    /// MUST be called from loadPosts() (or similar ordinary async work),
    /// never from inside `body`/a List row closure. Confirmed by a real
    /// TestFlight crash (ticket 9626caf291, build 1.0(15)): `NSAttributed-
    /// String`'s HTML importer runs through `-[NSHTMLReader
    /// _loadUsingWebKit]`, which pumps its own nested CFRunLoop on the main
    /// thread. Calling that synchronously from inside this view's `content`
    /// List row closure meant it ran WHILE SwiftUI's AttributeGraph was
    /// mid-update for that same node; the nested run loop let something else
    /// re-enter and mutate the graph, which AttributeGraph detects as a
    /// hard invariant violation and aborts on (AG::invalidation_precondition
    /// -> AG::precondition_failure -> abort()) -- SIGABRT, not a Swift trap,
    /// so no amount of `guard`/`try?` in this function itself could have
    /// caught it. Moving the call to loadPosts() keeps the same main-thread
    /// requirement (this API isn't safe to call off-main either) but runs it
    /// as ordinary top-level async work, not reentrantly nested inside a
    /// graph transaction -- the result lands in `plainTextByHash` state
    /// *before* the List/ForEach that reads it ever evaluates.
    ///
    /// Not `private`, so StoneTests can reach it via `@testable import` for
    /// the parts that ARE safely unit-testable (the string conversion
    /// itself); the crash this function's doc describes is a SwiftUI/
    /// AttributeGraph re-entrancy issue that only reproduces with a real
    /// view hierarchy, not something a unit test can exercise.
    static func plainText(fromHTML html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return html
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Composer

    /// Native, reliably selectable post-body rendering. See the call site's
    /// doc for why this replaced Text + .textSelection(.enabled) -- that
    /// SwiftUI modifier left the long-press Copy/Share menu working but the
    /// actual selection UI (highlight + drag handles) unresponsive on-device
    /// in two different container types. A plain UITextView, non-editable
    /// and non-scrolling (the ScrollView it lives in already scrolls),
    /// supplies genuine UIKit text selection instead of leaning on SwiftUI's
    /// wrapper around it.
    private struct SelectableText: UIViewRepresentable {
        let text: String

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.isEditable = false
            view.isSelectable = true
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.font = .preferredFont(forTextStyle: .body)
            view.adjustsFontForContentSizeCategory = true
            view.setContentCompressionResistancePriority(.required, for: .vertical)
            return view
        }

        func updateUIView(_ uiView: UITextView, context: Context) {
            if uiView.text != text {
                uiView.text = text
            }
        }

        /// Lets SwiftUI size this like any other text view instead of a
        /// fixed-frame UIKit view -- without this, a UIViewRepresentable
        /// defaults to a size that ignores the text content entirely.
        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
            let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
            return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        }
    }

    private var composerSheet: some View {
        VStack(spacing: 20) {
            Text("New Instruction").font(.headline)
            TextEditor(text: $composerText)
                .frame(height: 200)
                .border(Color.gray, width: 1)
            if let sendError {
                Text(sendError).foregroundColor(.red).font(.caption)
            }
            HStack {
                Button("Cancel") {
                    showingComposer = false
                    composerText = ""
                    sendError = nil
                }
                Spacer()
                Button("Send") {
                    Task { await sendInstruction() }
                }
                .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
        }
        .padding()
    }

    /// Posts the composed text as a reply to the thread's root post -- the
    /// forum-as-work-queue contract (design doc C-B): the reply is forum
    /// activity the server daemon polls and drives as a Provider/Runner turn.
    private func sendInstruction() async {
        guard let remote = makeSession() else {
            sendError = "This repository has no remote configured."
            return
        }
        sending = true
        defer { sending = false }
        do {
            try await remote.postReply(fpid: session.root, text: composerText)
            showingComposer = false
            composerText = ""
            sendError = nil
            await loadPosts()
        } catch {
            sendError = error.localizedDescription
        }
    }

    // MARK: - Networking

    private func makeSession() -> RemoteSession? {
        guard let remote = repo.remoteURL else { return nil }
        return RemoteSession(remoteURL: remote, password: CredentialStore.password(for: repo.id))
    }

    private func loadPosts() async {
        guard let remote = makeSession() else {
            loadError = "This repository has no remote configured."
            return
        }
        do {
            let fetched = try await AgentSessionClient(session: remote).fetchPosts(root: session.root)
            posts = fetched
            // Precompute plain-text renders here, not in the List row
            // closure -- see plainText(fromHTML:)'s doc for why that
            // distinction is load-bearing, not just tidiness.
            var texts: [String: String] = [:]
            for post in fetched { texts[post.hash] = Self.plainText(fromHTML: post.html) }
            plainTextByHash = texts
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Live status

    private func connectLive() async {
        guard let remote = makeSession() else {
            liveStatus = .offline("This repository has no remote configured.")
            startPolling()
            return
        }
        do {
            let url = try await AgentSessionClient(session: remote).liveEventsURL(root: session.root)
            eventTask = Task { await streamEvents(from: url) }
        } catch {
            // No SSE URL available (offline, or the server doesn't expose
            // live status yet) -- fall back to poll-on-sync per the design
            // doc's "poll when offline-capable, SSE when connected" rule.
            startPolling()
        }
    }

    /// Runs entirely inside this call's own `Task` (held in `eventTask`) so
    /// that cancelling it on disappear reliably tears down the underlying
    /// connection -- see `AgentEventStream.run`'s doc.
    private func streamEvents(from url: URL) async {
        do {
            try await AgentEventStream.run(url: url) { event in
                liveStatus = .live(Self.summarize(event))
            }
        } catch {
            // Connection dropped or never established -- fall through to
            // polling below rather than leaving the banner stuck.
        }
        if !Task.isCancelled {
            startPolling()
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        liveStatus = .polling
        pollTask = Task {
            while !Task.isCancelled {
                await loadPosts()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private static func summarize(_ event: AgentTurnEvent) -> String {
        switch event {
        case .turnStarted: return "Turn started…"
        case .turnHeartbeat: return "Working…"
        case .turnFinished: return "Turn finished"
        case .other(let name, _): return name
        }
    }
}
