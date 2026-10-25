import Foundation
import SwiftUI

/// The home screen: lists repositories and offers add (clone / new) + delete.
struct RepoListView: View {
    @EnvironmentObject private var store: RepoStore
    @ObservedObject private var conversationStore = ConversationStore.shared
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var repoToRename: Repo?
    @State private var renameText = ""
    @State private var repoToDelete: Repo?
    @State private var repoToEditRemote: Repo?
    @State private var syncResultRepo: Repo?

    var body: some View {
        List {
            if store.repos.isEmpty {
                ContentUnavailableView("No Repositories",
                                       systemImage: "shippingbox",
                                       description: Text("Clone a remote Fossil repo or create a new one."))
            }
            ForEach(store.repos) { repo in
                NavigationLink(value: repo) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.name).font(.headline)
                            if let remote = repo.remoteURL {
                                Text(remote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        syncStatusIcon(for: repo)
                    }
                    .accessibilityIdentifier("repoRow-\(repo.name)")
                }
                // allowsFullSwipe: false so a long swipe can't fire the
                // destructive action without a deliberate tap + confirmation.
                // Delete is deliberately alone here -- Rename/Edit Remote used
                // to share this row and read as "adjacent to destructive"
                // even though they aren't; they live in the context menu
                // instead now.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        repoToDelete = repo
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        renameText = repo.name
                        repoToRename = repo
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        repoToEditRemote = repo
                    } label: {
                        Label("Edit Remote", systemImage: "link")
                    }
                }
            }
        }
        .navigationTitle("Stone")
        .navigationDestination(for: Repo.self) { repo in
            RepoDetailView(repo: repo)
        }
        .navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .requests: RequestsView()
            case .conversations: ConversationListView()
            case .repoConversations(let repoID): ConversationListView(repoID: repoID)
            case .conversation(let id): ConversationView(id: id)
            }
        }
        .refreshable {
            await store.syncAll()
            await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: store.lastSyncReceivedCounts)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: AppRoute.conversations) {
                    conversationsIcon
                }
                .accessibilityIdentifier("conversationsButton")
                .accessibilityLabel("Conversations (\(conversationStore.totalUnread) unread)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await store.syncAll()
                        await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: store.lastSyncReceivedCounts)
                    }
                } label: {
                    if store.isSyncingAll { ProgressView() }
                    else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .disabled(store.isSyncingAll || !store.repos.contains { $0.remoteURL != nil })
                .accessibilityLabel("Sync All")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("addRepoButton")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddRepoView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(item: $repoToEditRemote) { repo in
            EditRemoteView(repo: repo)
        }
        .sheet(item: $syncResultRepo) { repo in
            if let record = store.syncRecords[repo.id] {
                SyncResultView(repoName: repo.name, record: record)
            }
        }
        .alert("Rename Repository",
               isPresented: Binding(get: { repoToRename != nil },
                                    set: { if !$0 { repoToRename = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { repoToRename = nil }
            Button("Save") {
                if let repo = repoToRename { store.rename(repo, to: renameText) }
                repoToRename = nil
            }
        }
        .confirmationDialog("Delete Repository",
                            isPresented: Binding(get: { repoToDelete != nil },
                                                 set: { if !$0 { repoToDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: repoToDelete) { repo in
            Button("Delete \(repo.name)", role: .destructive) {
                store.delete(repo)
                repoToDelete = nil
            }
            Button("Cancel", role: .cancel) { repoToDelete = nil }
        } message: { _ in
            Text("This permanently deletes the local repository file. This cannot be undone.")
        }
    }

    /// The repo's latest sync, whatever started it: a spinner while one
    /// runs, then its status icon for 15 minutes, blank after that or when
    /// none was tried. Tapping the icon shows that sync's results.
    @ViewBuilder
    private func syncStatusIcon(for repo: Repo) -> some View {
        if store.syncingRepos.contains(repo.id) {
            ProgressView()
        } else {
            RecentSyncButton(record: store.syncRecords[repo.id]) { syncResultRepo = repo }
        }
    }

    /// Speech bubbles plus the unread count across every conversation --
    /// the same number as the app icon badge.
    @ViewBuilder
    private var conversationsIcon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "bubble.left.and.bubble.right")
            if conversationStore.totalUnread > 0 {
                Text("\(conversationStore.totalUnread)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(Color.red))
                    .offset(x: 10, y: -10)
            }
        }
    }
}

/// A sync's status icon, as a button that opens its results, shown only
/// while the sync is recent (`shownFor`). Redraws every 30 seconds so it
/// goes blank on time without anything else changing.
struct RecentSyncButton: View {
    static let shownFor: TimeInterval = 15 * 60

    let record: RepoSyncRecord?
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let record, context.date.timeIntervalSince(record.finishedAt) < Self.shownFor {
                Button(action: action) {
                    SyncStatusIcon(status: record.status)
                }
                // Borderless, so a tap on the icon opens the results rather
                // than the row's navigation link.
                .buttonStyle(.borderless)
                .accessibilityHint("Shows this sync's results")
            }
        }
    }
}

/// The icon for one sync's outcome: green check, orange key for a push the
/// server refused, red ladybug for a failure on this phone, red mark for
/// any other failure.
struct SyncStatusIcon: View {
    let status: RepoSyncStatus

    var body: some View {
        switch status {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(status.summary)
        case .authFailed:
            // Deliberately distinct from both success and a bare command
            // failure (ticket 94ea2161f5): a rejected push looks exactly
            // like success at the exit-code level.
            Image(systemName: "key.slash.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel(status.summary)
        case .localFailure:
            // Ticket f0c612c027: a failure inside this phone's own clone,
            // never to be mistaken for the server refusing anything.
            Image(systemName: "ladybug.fill")
                .foregroundStyle(.red)
                .accessibilityLabel(status.summary)
        case .failure:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel(status.summary)
        }
    }
}

extension RepoSyncStatus {
    /// One line saying what the sync achieved.
    var summary: String {
        switch self {
        case .success(let sent, let received):
            // Real counts, not a blanket "Sync complete": a sync that sent
            // nothing must be visible as such.
            return "Synced — \(sent) sent, \(received) received"
        case .authFailed(let reason): return "Server refused the push: \(reason)"
        case .localFailure(let reason): return "Sync failed on this phone: \(reason)"
        case .failure(let message): return "Sync failed: \(message)"
        }
    }
}

/// One repo's latest sync in full: what it achieved, when, and Fossil's
/// own output with Stone's phase timings, which the summary can't show
/// (e.g. the round-trip count; ticket 94ea2161f5).
struct SyncResultView: View {
    let repoName: String
    let record: RepoSyncRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(record.status.summary)
                    } icon: {
                        SyncStatusIcon(status: record.status)
                    }
                    LabeledContent("Started by", value: record.trigger.rawValue)
                    LabeledContent("Finished") {
                        Text("\(record.finishedAt.formatted(date: .omitted, time: .standard)), \(record.finishedAt.formatted(.relative(presentation: .named)))")
                    }
                }
                Section("Fossil output") {
                    Text(record.log.isEmpty ? "(no output captured)" : record.log)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(repoName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
