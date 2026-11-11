import PhotosUI
import SafariServices
import SwiftUI
import UniformTypeIdentifiers

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
    @ObservedObject private var sessionSteps = SessionSteps.shared
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
    /// How many of the latest posts are on screen. A long thread renders
    /// in full only on request, a page at a time, so opening it costs the
    /// same as opening a short one.
    @State private var shownCount = Self.pageSize
    /// A post too long for a bubble, shown whole in a sheet.
    @State private var wholePost: ConversationPost?
    private static let pageSize = 100
    /// What the session answering this thread is doing, read from its
    /// posts on each reload; nil for a ticket, or a thread that isn't a
    /// session's.
    @State private var agentStatus: AgentStatus?
    /// Questions in this thread that have a decision, by hash: their
    /// choices are no longer offered.
    @State private var decided: Set<String> = []
    /// The session's steps after `post`, up to the next post: the turn that
    /// post started. Empty for a thread that isn't a session's.
    private func steps(after post: ConversationPost) -> [ChatLine] {
        guard let login = agentStatus?.login, let index = posts.firstIndex(of: post) else { return [] }
        let next = posts.index(after: index) < posts.endIndex ? posts[posts.index(after: index)].date : .distantFuture
        return sessionSteps.steps(repo: id.repoID, login: login, after: post.date, before: next)
    }
    /// Whether the newest post is on screen: the jump-to-bottom button
    /// shows when it isn't.
    @State private var bottomY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    private var scrolledUp: Bool { bottomY > viewportHeight + 80 }
    private static let bottomID = "bottom"
    /// Set for a moment by the jump button: turning
    /// scrolling off stops a list still coasting after a flick, which
    /// otherwise carries on past any jump (stone forum 915dbe3627).
    @State private var stopCoasting = false
    /// True while this screen's own sync (after Send, or the watch loop)
    /// runs, so the two never overlap.
    @State private var syncing = false
    @ObservedObject private var network = NetworkStatus.shared
    @FocusState private var composerFocused: Bool
    @StateObject private var keyboard = KeyboardInset()

    private var repo: Repo? { store.repos.first { $0.id == id.repoID } }
    private var login: String { repo.map(ConversationStore.login(for:)) ?? "" }
    private var fossilPath: String? { repo.map { store.fileURL(for: $0).path } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack, not a LazyVStack: lazy rows of very
                // different heights (a one-liner, a crash log) are
                // re-estimated on every redraw, which made the conversation
                // jump and left blank space where earlier posts had been.
                // Bubbles are Equatable, so a redraw of this screen (the
                // status poll, a sync) skips every bubble that didn't change.
                VStack(spacing: 12) {
                    if loaded && posts.isEmpty {
                        ContentUnavailableView("Nothing here yet", systemImage: "bubble.left",
                                               description: Text("This conversation isn't in this phone's clone. Try a sync."))
                    }
                    if posts.count > shownCount {
                        Button("Show earlier posts (\(posts.count - shownCount))") {
                            shownCount += Self.pageSize
                        }
                        .buttonStyle(.bordered)
                    }
                    ForEach(posts.suffix(shownCount)) { post in
                        BubbleView(post: post, own: ConversationBook.isOwn(post, login: login),
                                   reply: { replyTarget = post; composerFocused = true },
                                   choose: { option in
                                       replyTarget = post
                                       draft.text = option
                                       composerFocused = true
                                   },
                                   showWhole: { wholePost = post },
                                   decided: decided.contains(post.hash),
                                   fossilPath: fossilPath)
                            .equatable()
                            .id(post.hash)
                        let turn = steps(after: post)
                        if !turn.isEmpty {
                            StepsView(steps: turn, current: post == posts.last)
                        }
                    }
                    Color.clear.frame(height: 1)
                        .id(Self.bottomID)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.bottomID)).minY } action: { bottomY = $0 }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDisabled(stopCoasting)
            .coordinateSpace(.named(Self.bottomID))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onChange(of: posts.last?.hash) { _, _ in
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            // Like the console's: a round arrow while scrolled up, back to
            // the newest post (maintainer, ocx-console forum 57bc09a092).
            .overlay(alignment: .bottomTrailing) {
                if scrolledUp {
                    Button {
                        // A list still coasting after a flick carries on past
                        // a jump, animated or not (stone forum a3ddb2dd50,
                        // 915dbe3627). Stop it first by turning scrolling off,
                        // then jump and turn scrolling back on. The wait lets
                        // the screen draw once with scrolling off; on the very
                        // next turn of the main loop both changes could merge.
                        stopCoasting = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                            stopCoasting = false
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: Circle())
                            .shadow(radius: 2)
                    }
                    .padding(12)
                    .accessibilityLabel("Jump to bottom")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ReplyBox(draft: draft, replyTarget: $replyTarget, login: login, sending: sending,
                     status: sendStatus, waiting: waitingLine, canSend: !posts.isEmpty,
                     focused: $composerFocused, send: {
                Task { await send() }
            }, attach: { data, ext, mime in
                Task { await attachScreenshot(data, ext: ext, mime: mime) }
            })
            .padding(.bottom, keyboard.height)
        }
        // The reply box follows the keyboard by its frame (KeyboardInset),
        // not by SwiftUI's own keyboard avoidance, which now and then
        // missed a change and left the box under the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // The build-ID label would sit on the reply box whenever the
        // keyboard is up; it has no business on this screen.
        .onAppear { BuildIdentityVisibility.shared.hide() }
        .onDisappear { BuildIdentityVisibility.shared.unhide() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A session that hasn't ended can be asked for an update in one
            // press.
            if let agentStatus, !agentStatus.isEnded {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await send(Self.updateRequest) }
                    } label: {
                        Image(systemName: "questionmark.bubble")
                    }
                    .disabled(sending)
                    .accessibilityLabel("Ask for an update")
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    if !network.online {
                        OfflineLabel().font(.caption2).foregroundStyle(.secondary)
                    }
                    if let agentStatus {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(agentStatus.color)
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
        .task(id: id) { await watch() }
        .task(id: agentStatus == nil) {
            if agentStatus != nil, let repo { await sessionSteps.load(repo) }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "http" || url.scheme == "https" else { return .systemAction }
            openedLink = OpenedLink(url: url)
            return .handled
        })
        .sheet(item: $openedLink) { link in
            // A link to one of this phone's repositories' servers opens
            // signed in; any other in Safari's view.
            if let site = RemoteSiteView.repo(for: link.url, in: store.repos),
               CredentialStore.password(for: site.id) != nil {
                SignedInPage(repo: site, url: link.url)
            } else {
                SafariView(url: link.url).ignoresSafeArea()
            }
        }
        .sheet(item: $wholePost) { post in
            NavigationStack {
                LongTextView(text: post.body ?? "")
                    .navigationTitle(post.author)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { wholePost = nil }
                        }
                    }
            }
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

    /// When your post is the latest, who hasn't answered yet and since when
    /// -- the one activity signal the thread itself carries. Whether that
    /// agent is actually working, idle or stopped is only known to OCX on
    /// the server.
    private var waitingLine: String? {
        // A session's status line, and its steps, say whose turn it is.
        if agentStatus != nil { return nil }
        guard let last = posts.last, ConversationBook.isOwn(last, login: login) else { return nil }
        let other = posts.last { !ConversationBook.isOwn($0, login: login) }?.author ?? "a reply"
        let since = last.date.formatted(.dateTime.hour().minute())
        return "Waiting for \(other) since \(since)"
    }

    /// While this conversation is on screen (the task is cancelled when it
    /// leaves), sync this repo
    /// - every 30 seconds while a reply is due: your post is the latest, or
    ///   the session is working;
    /// - every 2 minutes otherwise.
    /// A session's thread also reads the repo's chat then, for its steps
    /// (and once when it is seen to be a session's: `.task` below).
    private func watch() async {
        guard let repo else { return }
        var lastSync = Date()
        while !Task.isCancelled {
            let due = waitingLine != nil || agentStatus?.state == .working
            let interval: TimeInterval = due ? 30 : 120
            var synced = false
            if Date().timeIntervalSince(lastSync) >= interval {
                await syncRepo(repo)
                lastSync = Date()
                synced = true
            }
            if synced, agentStatus != nil { await sessionSteps.load(repo) }
            try? await Task.sleep(for: .seconds(15))
        }
    }

    /// One quiet sync of this conversation's repo, then the same after-sync
    /// scan every other sync runs (notifications, unread counts), then
    /// reload. Failures are silent here: Send reports its own.
    private func syncRepo(_ repo: Repo) async {
        guard repo.remoteURL != nil, !syncing, !store.isSyncingAll else { return }
        syncing = true
        defer { syncing = false }
        guard let output = try? await store.sync(repo, trigger: .conversation) else { return }
        let received = RepoStore.parseArtifactCounts(output)?.received ?? 0
        if received > 0 {
            await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: [repo.id: received])
            await reload()
        }
    }

    // MARK: Loading and sending

    private func reload() async {
        guard let fossilPath else { return }
        if let result = await conversations.posts(for: id, fossilPath: fossilPath) {
            if title != result.title { title = result.title }
            if posts != result.posts { posts = result.posts }
            let status = id.kind == .thread ? AgentStatus.read(result.posts) : nil
            if agentStatus != status { agentStatus = status }
            let decisions = OCXMessage.decided(in: result.posts)
            if decided != decisions { decided = decisions }
            if let last = result.posts.last {
                conversations.markRead(id, upTo: last.mtime)
                await NotificationManager.shared.updateBadge(conversations.totalUnread)
            }
        }
        if !loaded { loaded = true }
    }

    /// Attaches a screenshot to the repo's Screenshots wiki page in this
    /// phone's clone and puts its link in the reply box; it goes out with
    /// the reply's sync.
    private func attachScreenshot(_ data: Data, ext: String, mime: String) async {
        guard let fossilPath else { return }
        sendStatus = "Attaching the screenshot…"
        do {
            let markdown = try await ConversationWriter.attachScreenshot(
                data, fileExtension: ext, mimeType: mime, login: login, fossilPath: fossilPath)
            draft.text = draft.text.isEmpty ? markdown : draft.text + "\n\n" + markdown
            sendStatus = "Screenshot attached. It goes out when you send."
        } catch {
            sendStatus = nil
            errorText = error.localizedDescription
        }
    }

    /// What the update button posts: a plain request the session answers
    /// in a few lines (maintainer, ocx-console forum 02c912ba6c: "asking
    /// for an update should be a single button").
    static let updateRequest = "Update, please: in a few lines, what you're doing now, what's done, and what's next."

    /// Sends the draft, or `fixed` text (the update button's) as a reply to
    /// the latest post, leaving the draft as it is.
    private func send(_ fixed: String? = nil) async {
        guard let repo, let fossilPath, let latest = posts.last else { return }
        sending = true
        defer { sending = false }
        var body = fixed ?? draft.text
        let replyTarget = fixed == nil ? self.replyTarget : nil
        // A reply to an OCX question is a decision on it: the option's
        // words, or your own, in the question's own message shape.
        if let target = replyTarget,
           let question = OCXMessage(target.body ?? ""), question.kind == "question" {
            let note = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { body = question.decision(on: target.hash, note: note) }
        }
        do {
            try await ConversationWriter.reply(in: id, to: replyTarget, latest: latest, login: login,
                                               body: body, fossilPath: fossilPath)
        } catch {
            errorText = error.localizedDescription
            return
        }
        if fixed == nil {
            draft.text = ""
            self.replyTarget = nil
        }
        await reload()
        // Push right away. When that can't happen (no network, a refused
        // login), the reply is already safe in the clone and any later sync
        // sends it -- say so rather than failing silently.
        guard repo.remoteURL != nil else {
            sendStatus = "Saved on this phone. This repo has no remote to send it to."
            return
        }
        sendStatus = "Sending…"
        // Wait out a sync the watch loop may be running, then take the turn.
        while syncing { try? await Task.sleep(for: .milliseconds(200)) }
        syncing = true
        defer { syncing = false }
        do {
            let output = try await store.sync(repo, trigger: .conversation)
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
            if case .offline? = error as? RepoStore.StoreError {
                sendStatus = "Offline. Saved on this phone; it goes out when the network returns."
            }
        }
    }
}

/// One post as a bubble: the login's own on the right, everyone else's on
/// the left. Equal when its post and side are, so SwiftUI redraws it (and
/// re-reads its markdown) only when the post itself changed.
private struct BubbleView: View, Equatable {
    let post: ConversationPost
    let own: Bool
    let reply: () -> Void
    let choose: (String) -> Void
    let showWhole: () -> Void
    /// For an OCX question: a decision on it is in the thread.
    let decided: Bool
    /// The clone the post's attached images are read from.
    let fossilPath: String?

    /// Longer posts (agents' logs, crash reports) are cut short in the
    /// bubble: SwiftUI lays out a Text all at once, and a thread of very
    /// long posts could use enough memory for iOS to close the app.
    static let bubbleLimit = 4_000

    static func == (a: BubbleView, b: BubbleView) -> Bool {
        a.post == b.post && a.own == b.own && a.decided == b.decided
    }

    private var isLong: Bool { (post.body?.utf8.count ?? 0) > Self.bubbleLimit }

    var body: some View {
        let message = OCXMessage(post.body ?? "")
        // An OCX question's options, the first its asker's recommendation,
        // until it is decided; else an older question's Options: list.
        let options = message.map { $0.kind == "question" && !own && !decided ? $0.options : [] }
            ?? (own || isLong ? [] : PostText.options(post.body ?? ""))
        let recommended = message?.kind == "question" ? options.first : nil
        return HStack {
            if own { Spacer(minLength: 48) }
            VStack(alignment: own ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(own ? "You" : post.author).fontWeight(.semibold)
                    Text(post.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(ConversationWriter.imageHashes(in: post.body ?? ""), id: \.self) { hash in
                    LocalArtifactImage(hash: hash, fossilPath: fossilPath)
                }

                // Not .textSelection(.enabled): on iOS a selectable Text likely
                // takes the tap, and its links didn't open (stone, forum 82fbe873c7,
                // Nov 4). Select Text in the context menu opens the post in a
                // selectable view instead.
                Text(Self.rendered(post, said: message?.said))
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
                            reply()
                        } label: {
                            Label("Reply to this post", systemImage: "arrowshape.turn.up.left")
                        }
                        Button {
                            UIPasteboard.general.string = post.body ?? ""
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button {
                            showWhole()
                        } label: {
                            Label("Select Text", systemImage: "selection.pin.in.out")
                        }
                    }

                if isLong {
                    Button("Show whole post (\((post.body ?? "").count) characters)", action: showWhole)
                        .font(.caption)
                }

                if !options.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(options, id: \.self) { option in
                            Button {
                                choose(option.replacingOccurrences(of: "**", with: ""))
                            } label: {
                                Text(Self.inline(option == recommended ? option + " *(recommended)*" : option))
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
    /// `said`: an OCX message's words in place of the post (OCXMessage.said).
    private static func rendered(_ post: ConversationPost, said: String? = nil) -> AttributedString {
        var body = ConversationWriter.removingImages(from: said ?? post.body ?? "(couldn't read this post)")
        if body.utf8.count > bubbleLimit {
            body = String(body.prefix(bubbleLimit)) + "\n…"
        }
        let isMarkdown = post.mimetype.isEmpty || post.mimetype.contains("markdown")
        guard isMarkdown else { return AttributedString(body) }
        return inline(body)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// How far the keyboard reaches above the bottom safe area (the
/// home-indicator strip), from UIKit's keyboard frame notifications. Every
/// show, hide, resize and undock posts one, so the reply box can sit
/// exactly on top of the keyboard.
@MainActor
final class KeyboardInset: ObservableObject {
    @Published private(set) var height: CGFloat = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                let hiding = note.name == UIResponder.keyboardWillHideNotification
                MainActor.assumeIsolated { self?.update(frame: hiding ? nil : frame, duration: duration) }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func update(frame: CGRect?, duration: Double) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        var overlap: CGFloat = 0
        if let frame, let window {
            // The frame is in screen coordinates; a floating or undocked
            // keyboard that doesn't reach the bottom edge covers nothing.
            let local = window.convert(frame, from: window.screen.coordinateSpace)
            if local.maxY >= window.bounds.maxY - 1 {
                overlap = max(0, window.bounds.maxY - local.minY - window.safeAreaInsets.bottom)
            }
        }
        guard overlap != height else { return }
        withAnimation(.easeOut(duration: duration)) { height = overlap }
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
    /// Attaches a picked image (its bytes, file extension and MIME type).
    let attach: (Data, String, String) -> Void
    @State private var pickedPhoto: PhotosPickerItem?

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
                    if let question = OCXMessage(target.body ?? ""), question.kind == "question" {
                        Text("Your decision: \(question.question ?? PostText.preview(target.body ?? ""))")
                            .lineLimit(1)
                    } else {
                        Text("\(ConversationBook.isOwn(target, login: login) ? "You" : target.author): \(PostText.preview(target.body ?? ""))")
                            .lineLimit(1)
                    }
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
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Image(systemName: "photo").font(.title2)
                }
                .disabled(sending)
                .accessibilityLabel("Attach a screenshot")
                .onChange(of: pickedPhoto) { _, item in
                    guard let item else { return }
                    pickedPhoto = nil
                    Task {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                        let type = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .png
                        attach(data, type.preferredFilenameExtension ?? "png", type.preferredMIMEType ?? "image/png")
                    }
                }
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
/// An image attached in a post, read from this phone's clone (`fossil
/// artifact HASH FILE`), so it shows offline and needs no login. Before the
/// sync that brings it, the clone doesn't have it yet, and says so.
private struct LocalArtifactImage: View {
    let hash: String
    let fossilPath: String?
    @State private var image: UIImage?
    @State private var missing = false

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if missing {
                Label("Image not on this phone yet", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().frame(width: 60, height: 60)
            }
        }
        .task(id: hash) { await load() }
    }

    private func load() async {
        if let cached = Self.cache.object(forKey: hash as NSString) {
            image = cached
            return
        }
        guard let fossilPath else { missing = true; return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(hash)")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await FossilEngine.shared.run(["artifact", hash, file.path, "-R", fossilPath])
        guard result.succeeded, let loaded = UIImage(contentsOfFile: file.path) else {
            missing = true
            return
        }
        Self.cache.setObject(loaded, forKey: hash as NSString)
        image = loaded
    }
}

/// A whole post as plain, selectable text. UITextView lays out only what is
/// on screen, so even a very long post opens quickly and cheaply.
private struct LongTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = .link
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension AgentStatus {
    var color: Color {
        switch state {
        case .waiting: return .orange
        case .working: return .green
        case .yourTurn: return .yellow
        case .ended: return .gray
        }
    }

    var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    /// The list's running or idle mark.
    var shortLabel: String {
        switch state {
        case .waiting: return "Not started"
        case .working: return "Running"
        case .yourTurn: return "Idle, your turn"
        case .ended: return "Ended"
        }
    }
}

/// One turn's steps, in line under the post that started it, from the
/// repository's chat (as ocx-console's page shows them). The current
/// turn's are open, its newest few with the rest counted; a past turn's
/// are folded to "N steps" until tapped.
private struct StepsView: View {
    let steps: [ChatLine]
    let current: Bool
    @State private var open: Bool?
    @State private var all = false
    private static let shown = 6

    var body: some View {
        let isOpen = open ?? current
        VStack(alignment: .leading, spacing: 3) {
            Button {
                open = !isOpen
            } label: {
                Label("\(steps.count) step\(steps.count == 1 ? "" : "s")",
                      systemImage: isOpen ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            if isOpen {
                if !all && steps.count > Self.shown {
                    Button("\(steps.count - Self.shown) earlier steps") { all = true }
                        .buttonStyle(.plain)
                        .underline()
                }
                ForEach(Array((all ? steps : Array(steps.suffix(Self.shown))).enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(step.date.formatted(.dateTime.hour().minute()))
                            .monospacedDigit()
                        Text(step.text).lineLimit(2)
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
