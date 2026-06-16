import SwiftUI

/// The home screen: lists repositories and offers add (clone / new) + delete.
struct RepoListView: View {
    @EnvironmentObject private var store: RepoStore
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var repoToRename: Repo?
    @State private var renameText = ""
    @State private var repoToDelete: Repo?

    var body: some View {
        List {
            if store.repos.isEmpty {
                ContentUnavailableView("No Repositories",
                                       systemImage: "shippingbox",
                                       description: Text("Clone a remote Fossil repo or create a new one."))
            }
            ForEach(store.repos) { repo in
                NavigationLink(value: repo) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.name).font(.headline)
                        if let remote = repo.remoteURL {
                            Text(remote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
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
                }
            }
        }
        .navigationTitle("Stone")
        .navigationDestination(for: Repo.self) { repo in
            RepoDetailView(repo: repo)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
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
}
