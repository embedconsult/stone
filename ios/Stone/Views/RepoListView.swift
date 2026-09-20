import Foundation
import SwiftUI

/// The home screen: lists repositories and offers add (clone / new) + delete.
struct RepoListView: View {
    @EnvironmentObject private var store: RepoStore
    @ObservedObject private var requestStore = MaintainerRequestStore.shared
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
            }
        }
        .refreshable {
            await store.syncAll()
            await BackgroundSyncScheduler.scanAndNotify(store: store, receivedCounts: store.lastSyncReceivedCounts)
        }
        .task {
            await runAutoSyncLoop()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: AppRoute.requests) {
                    bellIcon
                }
                .accessibilityIdentifier("requestsBellButton")
                .accessibilityLabel("Requests (\(requestStore.openRequestCount))")
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
        .alert("Sync All",
               isPresented: Binding(get: { store.syncAllSummary != nil },
                                    set: { if !$0 { store.dismissSyncAllSummary() } })) {
            Button("OK") { store.dismissSyncAllSummary() }
        } message: {
            Text(store.syncAllSummary ?? "")
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

    /// Compact per-row indicator for the most recent "Sync All" outcome.
    @ViewBuilder
    private func syncStatusIcon(for repo: Repo) -> some View {
        switch store.syncStatuses[repo.id] {
        case .syncing:
            ProgressView()
        case .success(let sent, let received):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Synced — \(sent) sent, \(received) received")
        case .authFailed(let reason):
            // Deliberately distinct from both success and a bare command
            // failure (ticket 94ea2161f5): a rejected push looks exactly
            // like success at the exit-code level, so it needs its own
            // unmistakable icon, not a shade of the checkmark or the
            // generic error mark.
            Image(systemName: "key.slash.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Server refused the push: \(reason)")
        case .localFailure(let reason):
            // Ticket f0c612c027: a LOCAL failure inside this phone's own
            // clone (e.g. a crossed-wires SQLite authorizer error) -- kept
            // visually distinct from .authFailed so it is never mistaken
            // for the server refusing anything.
            Image(systemName: "ladybug.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Sync failed on this phone: \(reason)")
        case .failure(let message):
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Sync failed: \(message)")
        case .none:
            EmptyView()
        }
    }

    /// A bell plus the current badge count (ticket 4c75227cc7) --
    /// `requestStore.openRequestCount` is always "rows currently shown",
    /// recomputed from the latest scan, never an accumulated total.
    @ViewBuilder
    private var bellIcon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "bell")
            if requestStore.openRequestCount > 0 {
                Text("\(requestStore.openRequestCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(Color.red))
                    .offset(x: 10, y: -10)
            }
        }
    }
}
