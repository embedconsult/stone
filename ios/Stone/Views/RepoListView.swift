import SwiftUI

/// The home screen: lists repositories and offers add (clone / new) + delete.
struct RepoListView: View {
    @EnvironmentObject private var store: RepoStore
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
                }
                // allowsFullSwipe: false so a long swipe can't fire the
                // destructive action without a deliberate tap + confirmation.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        repoToDelete = repo
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        renameText = repo.name
                        repoToRename = repo
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                    Button {
                        repoToEditRemote = repo
                    } label: {
                        Label("Edit Remote", systemImage: "link")
                    }
                    .tint(.indigo)
                }
            }
        }
        .navigationTitle("Stone")
        .navigationDestination(for: Repo.self) { repo in
            RepoDetailView(repo: repo)
        }
        .refreshable {
            await store.syncAll()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.syncAll() }
                } label: {
                    if store.isSyncingAll { ProgressView() }
                    else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .disabled(store.isSyncingAll || !store.repos.contains { $0.remoteURL != nil })
                .accessibilityLabel("Sync All")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
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

    /// Compact per-row indicator for the most recent "Sync All" outcome.
    @ViewBuilder
    private func syncStatusIcon(for repo: Repo) -> some View {
        switch store.syncStatuses[repo.id] {
        case .syncing:
            ProgressView()
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Sync failed: \(message)")
        case .none:
            EmptyView()
        }
    }
}
