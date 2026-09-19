import Foundation

/// Carries "open this repo, then navigate its WebView to this path" from a
/// tapped local notification (NotificationManager, delivered on whatever
/// thread UNUserNotificationCenter chooses) to the SwiftUI view layer
/// (RepoListView pushes the repo; RepoDetailView loads the path once its
/// server is up). A plain published pair rather than a full app-wide router:
/// this is the only deep link Stone has right now (ticket 1a55c5d8b8).
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    struct Destination: Equatable {
        let repoID: UUID
        /// Path on the repo's local Fossil server, e.g. "/tktview/<uuid>" for
        /// one ticket or "/ticket" for the general ticket page (coalesced
        /// notifications, which don't name a single ticket).
        let path: String
    }

    @Published var pending: Destination?

    func route(repoID: UUID, path: String) {
        pending = Destination(repoID: repoID, path: path)
    }

    /// Called once RepoListView has pushed the matching repo and
    /// RepoDetailView has consumed the path, so a later, unrelated
    /// navigation doesn't replay a stale deep link.
    func clear() {
        pending = nil
    }
}
