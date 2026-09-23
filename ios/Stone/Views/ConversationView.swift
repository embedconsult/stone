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
    @State private var draft = ""
    @State private var replyTarget: ConversationPost?
    @State private var sending = false
    @State private var errorText: String?
    @State private var openedLink: OpenedLink?
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
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
            if own { Spacer(minLength: 40) }
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
                    .background(own ? Color.accentColor : Color(.secondarySystemBackground),
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
                                draft = option.replacingOccurrences(of: "**", with: "")
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
            if !own { Spacer(minLength: 40) }
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

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                TextField("Reply", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($composerFocused)
                Button {
                    Task { await send() }
                } label: {
                    if sending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
                .disabled(sending || posts.isEmpty || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
                                               body: draft, fossilPath: fossilPath)
        } catch {
            errorText = error.localizedDescription
            return
        }
        draft = ""
        replyTarget = nil
        await reload()
        // Push now when there's a network; when there isn't, the reply is
        // already safe in the clone and the next sync sends it.
        guard repo.remoteURL != nil else { return }
        if let output = try? await store.sync(repo) {
            let received = RepoStore.parseArtifactCounts(output)?.received ?? 0
            await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: [repo.id: received])
            await reload()
        }
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
