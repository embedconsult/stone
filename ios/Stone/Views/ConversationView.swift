import SafariServices
import SwiftUI

/// One conversation as a chat: every post in order, oldest at the top, the
/// signed-in login's own posts on the right and everyone else's on the left.
/// The box at the bottom replies to the latest post; a long-press on a bubble
/// replies to that post instead. Replies are written to the local clone
/// (ConversationWriter) and pushed by the sync that follows, or by any later
/// one if the phone is offline.
struct ConversationView: View {
    let id: ConversationID

    @EnvironmentObject private var store: RepoStore
    @ObservedObject private var conversations = ConversationStore.shared
    @State private var title = ""
    @State private var posts: [ConversationPost] = []
    @State private var loaded = false
    /// Held by reference and observed only by the reply box, so each
    /// keystroke redraws the box alone -- not every bubble above it, whose
    /// re-measuring made the conversation jump while typing.
    @State private var draft = ComposerDraft()
    @State private var replyTarget: ConversationPost?
    @State private var sending = false
    /// One line under the reply box saying what happened to the last reply:
    /// sending, sent, or saved here to go out with a later sync (and why).
    @State private var sendStatus: String?
    @State private var errorText: String?
    @State private var openedLink: OpenedLink?
    /// What OCX says the agent on this thread is doing; nil when the server
    /// doesn't say (no endpoint, offline, a ticket rather than a thread).
    @State private var agentStatus: AgentStatus?
    @FocusState private var composerFocused: Bool

    private var repo: Repo? { store.repos.first { $0.id == id.repoID } }
    private var login: String { repo.map(ConversationStore.login(for:)) ?? "" }
    private var fossilPath: String? { repo.map { store.fileURL(for: $0).path } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if loaded && posts.isEmpty {
                        ContentUnavailableView("Nothing here yet", systemImage: "bubble.left",
                                               description: Text("This conversation isn't in this phone's clone. Try a sync."))
                    }
                    ForEach(posts) { post in
                        bubble(post)
                            .id(post.hash)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: posts.last?.hash) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ReplyBox(draft: draft, replyTarget: $replyTarget, login: login, sending: sending,
                     status: sendStatus, waiting: waitingLine, canSend: !posts.isEmpty,
                     focused: $composerFocused) {
                Task { await send() }
            }
        }
        // The build-ID label would sit on the reply box whenever the
        // keyboard is up; it has no business on this screen.
        .onAppear { BuildIdentityVisibility.shared.hide() }
        .onDisappear { BuildIdentityVisibility.shared.unhide() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    if let agentStatus {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Self.color(for: agentStatus.state))
                                .frame(width: 7, height: 7)
                            Text(agentStatus.label())
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .task(id: id) { await pollAgentStatus() }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "http" || url.scheme == "https" else { return .systemAction }
            openedLink = OpenedLink(url: url)
            return .handled
        })
        .sheet(item: $openedLink) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
        .alert("Couldn't send", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .task { await reload() }
        .onChange(of: conversations.summaries.first { $0.id == id }?.latest.hash) { _, _ in
            Task { await reload() }
        }
    }

    // MARK: Bubbles

    private func bubble(_ post: ConversationPost) -> some View {
        let own = ConversationBook.isOwn(post, login: login)
        let options = own ? [] : PostText.options(post.body ?? "")
        return HStack {
            if own { Spacer(minLength: 48) }
            VStack(alignment: own ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(own ? "You" : post.author).fontWeight(.semibold)
                    Text(post.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(Self.rendered(post))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(own ? Color.white : Color.primary)
                    .tint(own ? Color.white : Color.accentColor)
                    // systemGray5 is Messages' incoming-bubble grey: visible on
                    // white and black alike (secondarySystemBackground was too
                    // pale to read as a bubble on a white screen).
                    .background(own ? Color.accentColor : Color(.systemGray5),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contextMenu {
                        Button {
                            replyTarget = post
                            composerFocused = true
                        } label: {
                            Label("Reply to this post", systemImage: "arrowshape.turn.up.left")
                        }
                        Button {
                            UIPasteboard.general.string = post.body ?? ""
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }

                if !options.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(options, id: \.self) { option in
                            Button {
                                replyTarget = post
                                draft.text = option.replacingOccurrences(of: "**", with: "")
                                composerFocused = true
                            } label: {
                                Text(Self.inline(option))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if !own { Spacer(minLength: 48) }
        }
    }

    /// Markdown for markdown posts (links, emphasis, code; line breaks kept
    /// as written), plain text for anything else.
    private static func rendered(_ post: ConversationPost) -> AttributedString {
        let body = post.body ?? "(couldn't read this post)"
        let isMarkdown = post.mimetype.isEmpty || post.mimetype.contains("markdown")
        guard isMarkdown else { return AttributedString(body) }
        return inline(body)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// When your post is the latest, who hasn't answered yet and since when
    /// -- the one activity signal the thread itself carries. Whether that
    /// agent is actually working, idle or stopped is only known to OCX on
    /// the server.
    private var waitingLine: String? {
        guard let last = posts.last, ConversationBook.isOwn(last, login: login) else { return nil }
        let other = posts.last { !ConversationBook.isOwn($0, login: login) }?.author ?? "a reply"
        let since = last.date.formatted(.dateTime.hour().minute())
        return "Waiting for \(other) since \(since)"
    }

    private static func color(for state: AgentStatus.State) -> Color {
        switch state {
        case .working: return .green
        case .idle: return .yellow
        case .stopped: return .gray
        }
    }

    /// Every 15 seconds while this conversation is on screen (the task is
    /// cancelled when it leaves). Threads only: OCX runs agents on forum
    /// threads, keyed by the thread's first post.
    private func pollAgentStatus() async {
        guard id.kind == .thread, let repo else { return }
        while !Task.isCancelled {
            agentStatus = await AgentStatusClient.fetch(repo: repo, thread: id.key)
            try? await Task.sleep(for: .seconds(15))
        }
    }

    // MARK: Loading and sending

    private func reload() async {
        guard let fossilPath else { return }
        if let result = await conversations.posts(for: id, fossilPath: fossilPath) {
            title = result.title
            posts = result.posts
            if let last = result.posts.last {
                conversations.markRead(id, upTo: last.mtime)
                await NotificationManager.shared.updateBadge(conversations.totalUnread)
            }
        }
        loaded = true
    }

    private func send() async {
        guard let repo, let fossilPath, let latest = posts.last else { return }
        sending = true
        defer { sending = false }
        do {
            try await ConversationWriter.reply(in: id, to: replyTarget, latest: latest, login: login,
                                               body: draft.text, fossilPath: fossilPath)
        } catch {
            errorText = error.localizedDescription
            return
        }
        draft.text = ""
        replyTarget = nil
        await reload()
        // Push right away. When that can't happen (no network, a refused
        // login), the reply is already safe in the clone and any later sync
        // sends it -- say so rather than failing silently.
        guard repo.remoteURL != nil else {
            sendStatus = "Saved on this phone. This repo has no remote to send it to."
            return
        }
        sendStatus = "Sending…"
        do {
            let output = try await store.sync(repo)
            if let reason = RepoStore.detectLocalSQLiteFailure(output) ?? RepoStore.detectAuthFailure(output) {
                sendStatus = "Saved on this phone; it will go out with the next sync. (\(reason))"
            } else {
                sendStatus = "Sent"
                let received = RepoStore.parseArtifactCounts(output)?.received ?? 0
                await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: [repo.id: received])
                await reload()
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if sendStatus == "Sent" { sendStatus = nil }
                }
            }
        } catch {
            // A failed sync's error is its whole log; say the one thing
            // that matters.
            var reason = "couldn't reach the server"
            if case .fossil(let log)? = error as? RepoStore.StoreError {
                reason = RepoStore.detectLocalSQLiteFailure(log) ?? RepoStore.detectAuthFailure(log) ?? reason
            } else {
                reason = error.localizedDescription
            }
            sendStatus = "Saved on this phone; it will go out with the next sync. (\(reason))"
        }
    }
}

final class ComposerDraft: ObservableObject {
    @Published var text = ""
}

/// The reply box: what is being answered, the text, and Send.
private struct ReplyBox: View {
    @ObservedObject var draft: ComposerDraft
    @Binding var replyTarget: ConversationPost?
    let login: String
    let sending: Bool
    let status: String?
    let waiting: String?
    let canSend: Bool
    var focused: FocusState<Bool>.Binding
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let waiting, status == nil {
                Label(waiting, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let target = replyTarget {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left")
                    Text("\(ConversationBook.isOwn(target, login: login) ? "You" : target.author): \(PostText.preview(target.body ?? ""))")
                        .lineLimit(1)
                    Spacer()
                    Button {
                        replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Reply to the latest post instead")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply", text: $draft.text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .focused(focused)
                Button(action: send) {
                    if sending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
                .disabled(sending || !canSend || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct OpenedLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Links open inside the app, over the conversation, rather than switching
/// to Safari.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
