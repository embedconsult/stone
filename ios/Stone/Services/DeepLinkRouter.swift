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
        /// Path on the repo's local Fossil server, e.g. "/tktview/<uuid>" --
        /// always names a single ticket. A notification with no single
        /// target to name (several requests at once) uses
        /// `requestsScreenRequested` below instead of this.
        let path: String
    }

    @Published var pending: Destination?

    /// Set true when a notification carries no single ticket to deep-link
    /// to (several requests arrived at once) -- ticket 4c75227cc7. StoneApp
    /// pushes the Requests screen in response, then clears this the same
    /// way `pending` is cleared, so a later unrelated notification tap
    /// doesn't replay it.
    @Published var requestsScreenRequested = false

    /// Set when `TicketOpener` determines the ticket isn't (yet) in this
    /// clone even after a fresh sync -- ticket 98c06fb7a7. StoneApp opens
    /// this externally (Safari) rather than ever routing to a local ticket
    /// page Fossil would render empty.
    @Published var pendingRemoteURL: URL?

    func route(repoID: UUID, path: String) {
        pending = Destination(repoID: repoID, path: path)
    }

    func routeToRequestsScreen() {
        requestsScreenRequested = true
    }

    func routeToRemote(url: URL) {
        pendingRemoteURL = url
    }

    /// Called once RepoListView has pushed the matching repo and
    /// RepoDetailView has consumed the path, so a later, unrelated
    /// navigation doesn't replay a stale deep link.
    func clear() {
        pending = nil
    }

    func clearRequestsScreenRequest() {
        requestsScreenRequested = false
    }

    func clearRemote() {
        pendingRemoteURL = nil
    }
}
