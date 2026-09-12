import SwiftUI

/// Native, mobile-first list of Ollama-Codex runner sessions bound to forum
/// threads on this repo's remote -- the sessions counterpart to
/// `RepoListView`'s repo list. Entry point into `AgentThreadView`.
///
/// This is cd9d4bfcb2's own scope (Gap 2 of agent-client-scoping.md):
/// `AgentConsoleView` stays the separate WebView entry point to the server's
/// own rendered console, unchanged by this native view.
struct AgentSessionListView: View {
    let repo: Repo

    @State private var sessions: [AgentSessionSummary] = []
    @State private var loadError: String?
    @State private var loading = false

    var body: some View {
        List {
            if let loadError {
                ContentUnavailableView("Couldn't load sessions",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if sessions.isEmpty && !loading {
                ContentUnavailableView("No Active Sessions",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("No runner sessions are bound to forum threads on this repo."))
            }
            ForEach(sessions) { session in
                NavigationLink(value: session) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).font(.headline)
                            if let lastActivity = session.lastActivity {
                                Text(lastActivity)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        statusIcon(for: session.status)
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .navigationDestination(for: AgentSessionSummary.self) { session in
            AgentThreadView(repo: repo, session: session)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func statusIcon(for status: String) -> some View {
        switch status.lowercased() {
        case "active", "running":
            Image(systemName: "circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Active")
        case "idle":
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Idle")
        default:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(status)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let remote = repo.remoteURL else {
            loadError = "This repository has no remote configured."
            return
        }
        guard let session = RemoteSession(remoteURL: remote, password: CredentialStore.password(for: repo.id)) else {
            loadError = "Invalid remote address."
            return
        }
        do {
            sessions = try await AgentSessionClient(session: session).fetchSessions()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
