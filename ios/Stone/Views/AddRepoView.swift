import SwiftUI

/// Sheet for adding a repository, either by cloning a remote or creating a new
/// empty one. Keeps form state local; delegates the work to `RepoStore`.
struct AddRepoView: View {
    @EnvironmentObject private var store: RepoStore
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case clone = "Clone Remote"
        case new = "New Local"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .clone
    @State private var name = ""
    @State private var remoteURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Section("Repository") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                }

                if mode == .clone {
                    Section("Remote") {
                        TextField("https://example.com/repo", text: $remoteURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        TextField("Username (optional)", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password (optional)", text: $password)
                    }
                    if !password.isEmpty && username.trimmingCharacters(in: .whitespaces).isEmpty {
                        Section {
                            Text("A password needs a username to authenticate as.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .clone ? "Clone" : "Create") {
                        Task { await submit() }
                    }
                    .disabled(working || !isValid)
                }
            }
            .overlay {
                if working { ProgressView().controlSize(.large) }
            }
        }
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if mode == .clone {
            guard !remoteURL.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            // A password with no username can't authenticate -- block it here
            // rather than letting the clone fail with a confusing error.
            if !password.isEmpty && username.trimmingCharacters(in: .whitespaces).isEmpty {
                return false
            }
        }
        return true
    }

    private func submit() async {
        working = true
        errorText = nil
        defer { working = false }
        do {
            switch mode {
            case .clone:
                let authURL = RepoStore.combinedRemoteURL(host: remoteURL, username: username)
                try await store.cloneRepo(named: name,
                                          remoteURL: authURL,
                                          password: password.isEmpty ? nil : password)
            case .new:
                try await store.createRepo(named: name)
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
