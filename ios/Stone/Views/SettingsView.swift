import SwiftUI

/// Minimal app settings. Currently just the commit author Fossil attributes
/// clone/commit/sync operations to (defaults to "stone").
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("commitAuthor") private var commitAuthor = "stone"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("User name", text: $commitAuthor)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Commit Author")
                } footer: {
                    Text("Name Fossil records as the author of clones, commits, and syncs.")
                }

                Section {
                    NavigationLink("About", destination: AboutView())
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let name = commitAuthor.trimmingCharacters(in: .whitespaces)
                        if name.isEmpty { commitAuthor = "stone" }
                        Task { await FossilEngine.shared.setUser(commitAuthor) }
                        dismiss()
                    }
                }
            }
        }
    }
}
