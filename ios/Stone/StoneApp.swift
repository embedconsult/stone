import BackgroundTasks
import SwiftUI

/// App entry point. Owns the single `RepoStore` and presents the repo list.
@main
struct StoneApp: App {
    // `.shared`, not a fresh instance: BackgroundSyncScheduler's BGTask
    // handlers (registered below, in init(), before this or any other
    // SwiftUI state exists) need to reach the exact same repo list this
    // view hierarchy shows -- see RepoStore.shared's doc.
    @StateObject private var store = RepoStore.shared
    @AppStorage("commitAuthor") private var commitAuthor = "stone"
    @Environment(\.scenePhase) private var scenePhase

    /// Owns the navigation path so a tapped notification (DeepLinkRouter)
    /// can push straight to a repo from outside the view that normally
    /// drives navigation (RepoListView's row taps) -- ticket 1a55c5d8b8.
    @State private var path = NavigationPath()
    @ObservedObject private var deepLinkRouter = DeepLinkRouter.shared
    @Environment(\.openURL) private var openURL

    init() {
        // Must happen before the app finishes launching -- BGTaskScheduler
        // throws at submit-time otherwise. `init()` runs before any scene
        // is presented, which is early enough.
        BackgroundSyncScheduler.register()
        // Forces NotificationManager's lazy singleton to exist now (not on
        // first use later), so its UNUserNotificationCenterDelegate is
        // already wired before the OS could ever deliver a
        // didReceiveResponse callback -- including a cold launch triggered
        // by tapping a notification.
        _ = NotificationManager.shared
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                RepoListView()
            }
            .environmentObject(store)
            // An overlay, not a ZStack sibling: it can never change the
            // layout underneath, so the keyboard still lifts the reply box.
            .overlay { BuildIdentityOverlay() }
            .task {
                await FossilEngine.shared.setUser(commitAuthor)
                if let ca = Bundle.main.path(forResource: "cacert", ofType: "pem") {
                    await FossilEngine.shared.setCACertificate(path: ca)
                }
                // iOS sets HOME to the read-only sandbox container root, so give
                // Fossil a writable home for its global config DB (~/.fossil).
                if let support = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask).first {
                    try? FileManager.default.createDirectory(
                        at: support, withIntermediateDirectories: true)
                    await FossilEngine.shared.setHome(path: support.path)
                }
            }
            .onChange(of: deepLinkRouter.pending) { _, destination in
                guard let destination,
                      let repo = store.repos.first(where: { $0.id == destination.repoID })
                else { return }
                path.append(repo)
            }
            .onChange(of: deepLinkRouter.pendingConversation) { _, id in
                guard let id else { return }
                path.append(AppRoute.conversation(id))
                deepLinkRouter.clearConversation()
            }
            .onChange(of: deepLinkRouter.requestsScreenRequested) { _, requested in
                guard requested else { return }
                path.append(AppRoute.requests)
                deepLinkRouter.clearRequestsScreenRequest()
            }
            // TicketOpener (ticket 98c06fb7a7): the ticket isn't in any
            // local clone even after a fresh sync -- open the server's own
            // page externally rather than ever landing on an empty local
            // ticket page.
            .onChange(of: deepLinkRouter.pendingRemoteURL) { _, url in
                guard let url else { return }
                openURL(url)
                deepLinkRouter.clearRemote()
            }
        }
        // Submitted here rather than only from inside a running background
        // task, so there is always a next attempt pending even the very
        // first time the app backgrounds -- a task that never once ran
        // can't reschedule itself.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                BackgroundSyncScheduler.scheduleAll()
            }
        }
    }
}
