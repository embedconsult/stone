import SwiftUI

/// Minimal app settings: the commit author Fossil attributes clone/commit/
/// sync operations to (defaults to "stone"), and the automatic-sync
/// interval.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("commitAuthor") private var commitAuthor = "stone"

    /// Keys and default read by RepoListView's auto-sync loop too -- kept
    /// here as the one place both sides reference, so the loop can never
    /// drift from what this screen actually saved.
    static let autoSyncEnabledKey = "autoSyncEnabled"
    static let autoSyncIntervalKey = "autoSyncIntervalMinutes"
    static let autoSyncSkipsLowPowerKey = "autoSyncSkipsLowPowerMode"
    static let defaultAutoSyncIntervalMinutes = 15
    static let autoSyncIntervalChoices = [5, 15, 30, 60]

    @AppStorage(autoSyncEnabledKey) private var autoSyncEnabled = false
    @AppStorage(autoSyncIntervalKey) private var autoSyncIntervalMinutes = defaultAutoSyncIntervalMinutes
    @AppStorage(autoSyncSkipsLowPowerKey) private var autoSyncSkipsLowPowerMode = true

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
                    Toggle("Automatic Sync", isOn: $autoSyncEnabled)
                    if autoSyncEnabled {
                        Picker("Interval", selection: $autoSyncIntervalMinutes) {
                            ForEach(Self.autoSyncIntervalChoices, id: \.self) { minutes in
                                Text(Self.label(forMinutes: minutes)).tag(minutes)
                            }
                        }
                        Toggle("Skip in Low Power Mode", isOn: $autoSyncSkipsLowPowerMode)
                    }
                } header: {
                    Text("Automatic Sync")
                } footer: {
                    Text("Periodically runs Sync All while Stone is open on screen. Stone has no background-refresh capability yet, so nothing syncs while the app isn't in the foreground.")
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

    private static func label(forMinutes minutes: Int) -> String {
        guard minutes % 60 == 0 else { return "\(minutes) Minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 Hour" : "\(hours) Hours"
    }
}
