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
            ZStack {
                NavigationStack(path: $path) {
                    RepoListView()
                }
                .environmentObject(store)

                BuildIdentityOverlay()
            }
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
            .onChange(of: deepLinkRouter.requestsScreenRequested) { _, requested in
                guard requested else { return }
                path.append(AppRoute.requests)
                deepLinkRouter.clearRequestsScreenRequest()
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
