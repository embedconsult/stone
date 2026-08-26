import SwiftUI

struct AboutView: View {
    @EnvironmentObject var store: RepoStore

    var body: some View {
        List {
            Section("Build Information") {
                InfoRow(label: "Version", value: bundleValue("CFBundleShortVersionString"))
                InfoRow(label: "Build", value: bundleValue("CFBundleVersion"))
                InfoRow(label: "Commit", value: bundleValue("BuildCommit"))
                InfoRow(label: "Date", value: bundleValue("BuildDate"))
                if bundleValue("BuildDirty") == "true" {
                    Text("Dirty build (uncommitted changes)").foregroundColor(.orange).font(.caption)
                }
            }

            Section("Configured Remotes") {
                if store.repos.isEmpty {
                    Text("No repositories configured").foregroundColor(.secondary)
                } else {
                    ForEach(store.repos) { repo in
                        VStack(alignment: .leading) {
                            Text(repo.name).font(.headline)
                            if let remote = repo.remoteURL {
                                Text(remote).font(.caption).foregroundColor(.secondary)
                            } else {
                                Text("Local only").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("About")
    }

    private func bundleValue(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "Unknown"
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}