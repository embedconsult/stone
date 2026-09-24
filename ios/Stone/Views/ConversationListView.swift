import SwiftUI

/// Every forum thread and ticket the signed-in login takes part in, across
/// every repo (or just `repoID`'s), newest activity first -- like Messages'
/// conversation list.
struct ConversationListView: View {
    var repoID: UUID? = nil

    @EnvironmentObject private var store: RepoStore
    @ObservedObject private var conversations = ConversationStore.shared
    @State private var loading = false

    var body: some View {
        List {
            if shown.isEmpty && !loading {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Threads and tickets \(loginsText) posted in, or that name \(loginsText) on a For: line, show up here after a sync."))
            }
            ForEach(shown) { summary in
                NavigationLink(value: AppRoute.conversation(summary.id)) {
                    row(summary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(repoID.flatMap { id in store.repos.first { $0.id == id }?.name } ?? "Conversations")
        .overlay { if loading && shown.isEmpty { ProgressView() } }
        .task { await reload() }
        .refreshable {
            await store.syncAll(announce: false)
            await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: store.lastSyncReceivedCounts)
            await reload()
        }
    }

    /// The login(s) conversations are matched against, so an empty list
    /// says who it looked for.
    private var loginsText: String {
        let repos = store.repos.filter { repoID == nil || $0.id == repoID }
        let logins = Array(Set(repos.map(ConversationStore.login(for:)))).sorted()
        return logins.isEmpty ? "you" : logins.joined(separator: " or ")
    }

    private var shown: [ConversationSummary] {
        guard let repoID else { return conversations.summaries }
        return conversations.summaries.filter { $0.id.repoID == repoID }
    }

    private func row(_ summary: ConversationSummary) -> some View {
        let repo = store.repos.first { $0.id == summary.id.repoID }
        let own = repo.map { ConversationBook.isOwn(summary.latest, login: ConversationStore.login(for: $0)) } ?? false
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(summary.unread > 0 ? Color.accentColor : Color.clear)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(summary.latest.date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: summary.id.kind == .thread ? "text.bubble" : "ticket")
                    Text(repo?.name ?? "")
                    if summary.unread > 0 {
                        Text("· \(summary.unread) unread")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("\(own ? "You" : summary.latest.author): \(PostText.preview(summary.latest.body ?? ""))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        await conversations.refresh(repos: store.repos, fossilPath: { store.fileURL(for: $0).path })
        await NotificationManager.shared.updateBadge(conversations.totalUnread)
    }
}
