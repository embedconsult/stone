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
            List(posts) { post in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(post.user).font(.subheadline.bold())
                        Spacer()
                        Text(post.role).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Self.plainText(fromHTML: post.html))
                        .font(.body)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
    }

    /// Strips the server-rendered HTML down to plain text for the mobile
    /// list -- read-only-first per the design doc's Gap 2.2, and a scrolling
    /// list of embedded WebViews is neither good UX nor good performance.
    /// Reuses the same system HTML-to-text conversion GpcrEditClient uses
    /// for the same reason: don't hand-roll an HTML parser for arbitrary
    /// server markup.
    private static func plainText(fromHTML html: String) -> String {
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
            posts = try await AgentSessionClient(session: remote).fetchPosts(root: session.root)
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
