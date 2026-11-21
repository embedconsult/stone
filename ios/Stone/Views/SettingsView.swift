import SwiftUI
import UIKit

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

    /// How many days a post counts as new in Conversations (0: always,
    /// until read). Maintainer, Nov 17: "yes, but 14 and settable".
    static let newForDaysKey = "conversationNewForDays"
    static let defaultNewForDays = 14
    static let newForDaysChoices = [1, 3, 7, 14, 30, 0]
    nonisolated static var newForDaysSetting: Int {
        UserDefaults.standard.object(forKey: newForDaysKey) as? Int ?? defaultNewForDays
    }
    @AppStorage(autoSyncEnabledKey) private var autoSyncEnabled = false
    @AppStorage(autoSyncIntervalKey) private var autoSyncIntervalMinutes = defaultAutoSyncIntervalMinutes
    @AppStorage(autoSyncSkipsLowPowerKey) private var autoSyncSkipsLowPowerMode = true
    @AppStorage(newForDaysKey) private var newForDays = defaultNewForDays

    /// Ticket 1a55c5d8b8: notify when a repo has a decision or try-this
    /// waiting for the maintainer. Default true (matches
    /// NotificationManager.isEnabled's fallback) -- the toggle is how the
    /// maintainer turns it *off*; permission is asked for separately, once,
    /// the first time this is (or becomes) true.
    @AppStorage(NotificationManager.notificationsEnabledKey) private var notificationsEnabled = true

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
                    Text("Periodically runs Sync All while Stone is open on screen, and in the background when Automatic Sync is on and Stone leaves the foreground -- iOS decides exactly when a background sync runs, not this interval.")
                }

                Section {
                    Picker("New For", selection: $newForDays) {
                        ForEach(Self.newForDaysChoices, id: \.self) { days in
                            Text(days == 0 ? "Until Read" : days == 1 ? "1 day" : "\(days) days").tag(days)
                        }
                    }
                } header: {
                    Text("Conversations")
                } footer: {
                    Text("A post older than this stops counting as new, read or not. Takes effect at the next sync.")
                }
                Section {
                    Toggle("Maintainer Request Alerts", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { _, enabled in
                            guard enabled else { return }
                            Task { await NotificationManager.shared.requestAuthorizationIfNeeded() }
                        }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("After a sync, Stone looks for tickets waiting on you -- a decision to confirm, or something to try. When this is on, it asks iOS once for permission to notify you, then sends one notification per repo when it finds something new. Turn it off to stop asking.")
                }

                Section {
                    NavigationLink("Verify This Build", destination: VerifyView())
                    NavigationLink("Hang Log", destination: HangLogView())
                    NavigationLink("WebAssembly Test", destination: WasmTestView())
                    NavigationLink("About", destination: AboutView())
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if notificationsEnabled {
                    await NotificationManager.shared.requestAuthorizationIfNeeded()
                }
            }
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

/// Each time Stone stopped answering for a second or more, with what it
/// had been doing just before (HangLog). Copy pastes it whole.
private struct HangLogView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No hangs noted yet." : text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Hang Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy") { UIPasteboard.general.string = text }
                    .disabled(text.isEmpty)
            }
        }
        .task { text = HangLog.shared.text() }
    }
}