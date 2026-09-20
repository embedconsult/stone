import Foundation
import SwiftUI

/// Navigation destinations reachable from outside their owning view's own
/// row taps -- currently just the Requests screen, pushed either from
/// RepoListView's bell button or from a coalesced notification tap
/// (StoneApp, DeepLinkRouter.routeToRequestsScreen).
enum AppRoute: Hashable {
    case requests
}

/// The screen behind the notifications (ticket 4c75227cc7): one row per
/// outstanding maintainer request (MaintainerRequestStore.visibleRequests),
/// grouped by repo, so a maintainer can see what a badge/notification was
/// actually about and clear it without waiting for the next sync.
///
/// Reachable from the home list's bell (RepoListView) and from any
/// notification tap that names no single ticket (several requests arrived
/// at once).
struct RequestsView: View {
    @ObservedObject private var requestStore = MaintainerRequestStore.shared
    @EnvironmentObject private var repoStore: RepoStore

    /// Sectioned by repo, in the same order as the home list, so a
    /// maintainer with a mental map of their repo list can find a section
    /// without re-scanning alphabetically.
    private var sections: [(repo: Repo, rows: [MaintainerRequestStore.Row])] {
        let grouped = Dictionary(grouping: requestStore.visibleRequests) { $0.repo.id }
        return repoStore.repos.compactMap { repo in
            guard let rows = grouped[repo.id], !rows.isEmpty else { return nil }
            return (repo: repo, rows: rows)
        }
    }

    var body: some View {
        List {
            if requestStore.visibleRequests.isEmpty {
                ContentUnavailableView(
                    "No Outstanding Requests",
                    systemImage: "bell.slash",
                    description: Text("Every maintainer request has been handled or dismissed."))
            }
            ForEach(sections, id: \.repo.id) { section in
                Section(section.repo.name) {
                    ForEach(section.rows) { row in
                        Button {
                            open(row)
                        } label: {
                            rowLabel(row)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                requestStore.dismiss(row)
                            } label: {
                                Label("Dismiss", systemImage: "xmark.circle")
                            }
                        }
                        .accessibilityIdentifier("requestRow-\(row.request.ticketUUID)")
                    }
                }
            }
        }
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear All") { requestStore.clearAll() }
                    .disabled(requestStore.visibleRequests.isEmpty)
                    .accessibilityIdentifier("clearAllRequestsButton")
            }
        }
    }

    @ViewBuilder
    private func rowLabel(_ row: MaintainerRequestStore.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.request.title)
                .font(.headline)
                .foregroundStyle(.primary)
            HStack {
                Label(row.request.kind.displayName, systemImage: row.request.kind.systemImage)
                    .font(.caption)
                    .foregroundStyle(tint(for: row.request.kind))
                Spacer()
                Text("First seen \(row.firstSeenAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tint(for kind: MaintainerRequest.Kind) -> Color {
        switch kind {
        case .mergeCard: return .purple
        case .decision: return .blue
        case .tryThis: return .orange
        }
    }

    /// Same routing a tapped single-ticket notification uses
    /// (NotificationManager.userNotificationCenter(didReceive:)) --
    /// StoneApp's `deepLinkRouter.pending` observer pushes the repo, and
    /// RepoDetailView.consumePendingDeepLink() navigates its WebView to this
    /// exact ticket once the local server is up.
    private func open(_ row: MaintainerRequestStore.Row) {
        DeepLinkRouter.shared.route(repoID: row.repo.id, path: "/tktview/\(row.request.ticketUUID)")
    }
}
