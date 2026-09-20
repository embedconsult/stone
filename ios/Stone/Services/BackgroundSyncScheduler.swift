import BackgroundTasks
import Foundation

/// Registers, schedules, and runs Stone's two BGTaskScheduler tasks (ticket
/// 1a55c5d8b8): a short `BGAppRefreshTask` for the ordinary "Sync All" case,
/// and a longer `BGProcessingTask` iOS may grant more generously (e.g.
/// overnight, or while charging) for a bigger backlog. Both funnel into the
/// same `runOnce`, so background and foreground share one code path and one
/// settings gate with `RepoListView.runAutoSyncLoop` (Automatic Sync toggle,
/// interval, Low Power opt-out) -- see that function's doc for why none of
/// this actually syncs unless Automatic Sync is on.
enum BackgroundSyncScheduler {
    static let refreshTaskIdentifier = "org.beagleboard.stone.sync-refresh"
    static let processingTaskIdentifier = "org.beagleboard.stone.sync-processing"

    /// Must run before the app finishes launching (a hard BGTaskScheduler
    /// requirement) -- called from `StoneApp.init()`, which SwiftUI runs
    /// before any scene is presented or `.task` fires.
    static func register() {
        _ = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskIdentifier, using: nil
        ) { task in
            handleAppRefresh(task as! BGAppRefreshTask)
        }
        _ = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingTaskIdentifier, using: nil
        ) { task in
            handleProcessing(task as! BGProcessingTask)
        }
    }

    /// Submits both requests. Called whenever the app leaves the foreground
    /// (StoneApp's `scenePhase` observer), so there is always a next
    /// background attempt pending rather than only one scheduled from
    /// inside a previous background run (which would never happen again if
    /// the user simply never backgrounds the app after that).
    static func scheduleAll() {
        scheduleAppRefresh()
        scheduleProcessing()
    }

    private static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: nextIntervalSeconds())
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: nextIntervalSeconds())
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The same interval the foreground loop reads
    /// (`SettingsView.autoSyncIntervalKey`). `earliestBeginDate` is a floor,
    /// not a promise -- iOS still decides the actual wake time based on
    /// usage patterns, battery, etc., so this is a hint, not a guarantee.
    private static func nextIntervalSeconds() -> TimeInterval {
        let minutes = UserDefaults.standard.object(forKey: SettingsView.autoSyncIntervalKey) as? Int
            ?? SettingsView.defaultAutoSyncIntervalMinutes
        return TimeInterval(max(minutes, 1) * 60)
    }

    private static func handleAppRefresh(_ task: BGAppRefreshTask) {
        scheduleAppRefresh() // always reschedule the next one up front
        let flag = ExpirationFlag()
        // Set before starting the work, not after: iOS can call this the
        // instant the task is handed to us if it's already out of budget,
        // and `flag` is the only thing standing between that and
        // `runOnce` starting an unwanted repo sync.
        task.expirationHandler = { flag.markExpired() }
        Task {
            await runOnce(shouldContinue: { !flag.isExpired() })
            task.setTaskCompleted(success: !flag.isExpired())
        }
    }

    private static func handleProcessing(_ task: BGProcessingTask) {
        scheduleProcessing()
        let flag = ExpirationFlag()
        task.expirationHandler = { flag.markExpired() }
        Task {
            await runOnce(shouldContinue: { !flag.isExpired() })
            task.setTaskCompleted(success: !flag.isExpired())
        }
    }

    /// Shared by both task kinds. `shouldContinue` is only ever polled
    /// between repos inside `RepoStore.syncAll` -- see that function's doc
    /// for why that is the one safe place to stop (never mid-command, so
    /// `FossilEngine`'s process-wide lock is never left held by an aborted
    /// call). `RepoStore.isSyncingAll` already guarantees foreground and
    /// background sync never run concurrently: both funnel through the same
    /// shared `RepoStore` instance, and `syncAll()` itself no-ops if a sync
    /// is already in flight.
    @MainActor
    private static func runOnce(shouldContinue: () -> Bool) async {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: SettingsView.autoSyncEnabledKey) as? Bool ?? false
        guard enabled else { return }
        let skipsLowPower = defaults.object(forKey: SettingsView.autoSyncSkipsLowPowerKey) as? Bool ?? true
        if skipsLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled { return }

        let store = RepoStore.shared
        guard !store.isSyncingAll, store.repos.contains(where: { $0.remoteURL != nil }) else { return }

        await store.syncAll(shouldContinue: shouldContinue)
        await scanAndNotify(store: store, receivedCounts: store.lastSyncReceivedCounts)
    }

    /// Also called by the foreground loop (RepoListView) after its own
    /// `syncAll()`, so a decision or try-this made while the app was open
    /// notifies exactly the same way as one found in the background.
    ///
    /// `receivedCounts` is `store.lastSyncReceivedCounts` after a "Sync
    /// All", or a single `[repo.id: received]` entry after a one-repo sync
    /// (`RepoWebView.runSync`) -- either way, it's this round's tally, not
    /// history. When every entry is zero (or the map is empty), nothing
    /// that just happened could have changed any repo's ticket table, so
    /// the whole scan is skipped (ticket d4d02c604f) rather than paying for
    /// a full sqlite pass over every repo just to reproduce the same
    /// `visibleRequests` that's already showing.
    @MainActor
    static func scanAndNotify(store: RepoStore, receivedCounts: [UUID: Int]) async {
        let requestStore = MaintainerRequestStore.shared
        guard receivedCounts.values.contains(where: { $0 > 0 }) else {
            store.appendRequestScanTiming(ran: false, seconds: 0)
            await NotificationManager.shared.updateBadge(requestStore.openRequestCount)
            return
        }

        let scanStartedAt = Date()
        let outcomes = await requestStore.scanAfterSync(
            repos: store.repos,
            receivedCounts: receivedCounts,
            fossilPath: { store.fileURL(for: $0).path }
        )
        store.appendRequestScanTiming(ran: true, seconds: Date().timeIntervalSince(scanStartedAt))
        for outcome in outcomes {
            await NotificationManager.shared.post(for: outcome.repo, newRequests: outcome.newRequests)
        }
        await NotificationManager.shared.updateBadge(requestStore.openRequestCount)
    }
}

/// Thread-safe one-shot flag: `BGTask.expirationHandler` fires on an
/// arbitrary queue, not necessarily the main actor, so this can't be a plain
/// `Bool` captured by the async work closure.
private final class ExpirationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false

    func markExpired() {
        lock.lock(); defer { lock.unlock() }
        expired = true
    }

    func isExpired() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return expired
    }
}
