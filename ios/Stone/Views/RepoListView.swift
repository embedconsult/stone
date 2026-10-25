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
                        SyncStatusBadge(repo: repo)
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
        .task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await runAutoSyncLoop() }
                group.addTask { await runRemoteWakes() }
            }
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

    /// Foreground periodic "Sync All", per the maintainer's request for a
    /// programmable sync interval with a Low Power Mode opt-out
    /// (SettingsView's "Automatic Sync" section). Tied to this view's
    /// `.task` lifecycle, so it runs for as long as the home screen exists
    /// -- effectively the whole time the app is open, since this is the
    /// root screen -- and stops the moment the task is cancelled (app
    /// backgrounded/torn down). Background execution (ticket 1a55c5d8b8) is
    /// a separate path -- BackgroundSyncScheduler's BGTaskScheduler tasks --
    /// that takes over once the app leaves the foreground; `isSyncingAll`
    /// keeps the two from ever running at the same time. Reads UserDefaults
    /// directly rather than through `@AppStorage` so every iteration sees
    /// whatever SettingsView most recently saved, not a value snapshotted
    /// when this loop started.
    private func runAutoSyncLoop() async {
        let defaults = UserDefaults.standard
        while !Task.isCancelled {
            let minutes = defaults.object(forKey: SettingsView.autoSyncIntervalKey) as? Int
                ?? SettingsView.defaultAutoSyncIntervalMinutes
            try? await Task.sleep(for: .seconds(max(minutes, 1) * 60))
            guard !Task.isCancelled else { return }

            let enabled = defaults.object(forKey: SettingsView.autoSyncEnabledKey) as? Bool ?? false
            guard enabled else { continue }

            let skipsLowPower = defaults.object(forKey: SettingsView.autoSyncSkipsLowPowerKey) as? Bool ?? true
            if skipsLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled { continue }

            guard !store.isSyncingAll, store.repos.contains(where: { $0.remoteURL != nil }) else { continue }
            await store.syncAll()
            // Same post-sync scan/notify step a background task runs, so a
            // decision or try-this found while the app is open in the
            // foreground surfaces exactly the same way as one found while
            // backgrounded.
            await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: store.lastSyncReceivedCounts)
        }
    }

    /// While Automatic Sync is on, keeps one `/chat-poll` request waiting per
    /// repo with a remote and a saved password (RemoteWake), and syncs that
    /// repo as soon as its server records something new. The interval loop
    /// above keeps running as the fallback. The set of repos and the
    /// settings are read again every minute.
    private func runRemoteWakes() async {
        let defaults = UserDefaults.standard
        var following: [UUID: Task<Void, Never>] = [:]
        defer { following.values.forEach { $0.cancel() } }
        while !Task.isCancelled {
            let enabled = defaults.object(forKey: SettingsView.autoSyncEnabledKey) as? Bool ?? false
            let skipsLowPower = defaults.object(forKey: SettingsView.autoSyncSkipsLowPowerKey) as? Bool ?? true
            let allowed = enabled && !(skipsLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled)
            let wanted = allowed ? store.repos.filter { $0.remoteURL != nil } : []
            let wantedIDs = Set(wanted.map(\.id))
            for (id, task) in following where !wantedIDs.contains(id) {
                task.cancel()
                following[id] = nil
            }
            for repo in wanted where following[repo.id] == nil {
                following[repo.id] = Task { await RemoteWake.follow(repo) { await wakeSync(repo.id) } }
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// One repo's sync after its server woke us: skipped while a Sync All
    /// runs, which covers it.
    private func wakeSync(_ id: UUID) async {
        guard !store.isSyncingAll, let repo = store.repos.first(where: { $0.id == id }) else { return }
        guard let output = try? await store.sync(repo) else { return }
        let received = RepoStore.parseArtifactCounts(output)?.received ?? 0
        await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: [repo.id: received])
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

/// A repo's latest sync attempt, from any path, as one small icon: a
/// spinner while it runs, then green (synced), orange key (the server
/// refused the push), red bug (failed on this phone) or red mark (failed).
/// Blank when nothing was attempted in the last 15 minutes. Tapping it
/// shows that attempt's details and Fossil's full output.
struct SyncStatusBadge: View {
    let repo: Repo
    @EnvironmentObject private var store: RepoStore
    @State private var showingDetails = false

    var body: some View {
        // Re-checked every 30 seconds, so the icon goes blank on time.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let record = store.syncRecords[repo.id], record.isRecent(at: context.date) {
                Button { showingDetails = true } label: { icon(record.status) }
                    .buttonStyle(.borderless)
            }
        }
        .sheet(isPresented: $showingDetails) {
            if let record = store.syncRecords[repo.id] {
                SyncDetailsView(repoName: repo.name, record: record)
            }
        }
    }

    @ViewBuilder
    private func icon(_ status: RepoSyncStatus) -> some View {
        switch status {
        case .syncing:
            ProgressView()
        case .success(let sent, let received):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Synced — \(sent) sent, \(received) received")
        case .authFailed(let reason):
            // Deliberately distinct from both success and a bare command
            // failure (ticket 94ea2161f5): a rejected push looks exactly
            // like success at the exit-code level.
            Image(systemName: "key.slash.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Server refused the push: \(reason)")
        case .localFailure(let reason):
            // Ticket f0c612c027: a failure inside this phone's own clone,
            // never to be mistaken for the server refusing anything.
            Image(systemName: "ladybug.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Sync failed on this phone: \(reason)")
        case .failure(let message):
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Sync failed: \(message)")
        }
    }
}

/// One repo's latest sync attempt: what happened, when, and Fossil's full
/// output (the round-trips and counts the icon can't show).
private struct SyncDetailsView: View {
    let repoName: String
    let record: RepoSyncRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(summary)
                    LabeledContent("When", value: record.at.formatted(date: .omitted, time: .standard))
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var summary: String {
        switch record.status {
        case .syncing: return "Syncing…"
        case .success(let sent, let received): return "Synced: \(sent) sent, \(received) received."
        case .authFailed(let reason): return "The server refused the push: \(reason)."
        case .localFailure(let reason): return "Sync failed on this phone: \(reason)."
        case .failure(let message): return "Sync failed: \(message)"
        }
    }
}
