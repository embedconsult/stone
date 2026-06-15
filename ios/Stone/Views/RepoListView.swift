import SwiftUI

/// The home screen: lists repositories and offers add (clone / new) + delete.
struct RepoListView: View {
    @EnvironmentObject private var store: RepoStore
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var repoToRename: Repo?
    @State private var renameText = ""

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
                .swipeActions(edge: .leading) {
                    Button {
                        renameText = repo.name
                        repoToRename = repo
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
            .onDelete(perform: deleteRepos)
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
    }

    private func deleteRepos(_ offsets: IndexSet) {
        for index in offsets { store.delete(store.repos[index]) }
    }
}
