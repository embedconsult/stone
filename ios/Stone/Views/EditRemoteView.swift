import SwiftUI

/// Sheet for editing a repository's remote URL, username, and password after
/// it already exists — the counterpart to `AddRepoView`'s clone-time fields,
/// since `RepoStore.updateRemote` previously had no UI calling it at all.
struct EditRemoteView: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss

    let repo: Repo

    @State private var remoteURL: String
    @State private var username: String
    @State private var password = ""

    init(repo: Repo) {
        self.repo = repo
        let split = RepoStore.splitRemoteURL(repo.remoteURL ?? "")
        _remoteURL = State(initialValue: split.host)
        _username = State(initialValue: split.username)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote") {
                    TextField("https://example.com/repo", text: $remoteURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("Username (optional)", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password (leave blank to keep current)", text: $password)
                }
                if !password.isEmpty && username.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Text("A password needs a username to authenticate as.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.updateRemote(repo, remoteURL: combinedURL, password: password.isEmpty ? nil : password)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        if !password.isEmpty && username.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    private var combinedURL: String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return RepoStore.combinedRemoteURL(host: trimmed, username: username)
    }
}
