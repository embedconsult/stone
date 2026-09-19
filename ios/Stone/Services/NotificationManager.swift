import Foundation
import UserNotifications

/// Local-only notifications for maintainer requests (ticket 1a55c5d8b8).
/// Deliberately local (`UNNotificationRequest` with a `nil` trigger, fired
/// right after a scan finds something new) -- no APNs, no push entitlement,
/// no server-side fan-out. Everything here already ran on-device (the
/// MaintainerRequestScanner pass that just finished), so there is nothing an
/// external push service would add except risk.
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    /// Read by SettingsView's toggle too -- default true (matches the
    /// ticket's framing: the feature works once permission is granted,
    /// unless the maintainer explicitly turns it off here).
    static let notificationsEnabledKey = "notificationsEnabled"
    private static let permissionRequestedKey = "notificationPermissionRequestedV1"

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.notificationsEnabledKey) as? Bool ?? true
    }

    /// Fires the system permission prompt at most once ever -- iOS itself
    /// only shows it once regardless, but guarding here also means calling
    /// this from both SettingsView (toggle turned on) and app launch (toggle
    /// already on from a previous run) never risks a second, silently-a-
    /// no-op call masking a real problem.
    func requestAuthorizationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.permissionRequestedKey) else { return }
        defaults.set(true, forKey: Self.permissionRequestedKey)
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    /// One notification per repo, even when several requests came in on that
    /// repo in the same scan ("3 requests on ollama") -- never one per
    /// ticket, which would flood the notification center for a repo with a
    /// backlog. Silently does nothing if the toggle is off or the system
    /// permission was never granted (denied, or not yet asked).
    func post(for repo: Repo, newRequests: [MaintainerRequest]) async {
        guard isEnabled, !newRequests.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        if newRequests.count == 1, let only = newRequests.first {
            content.title = "Ollama-Codex needs you: \(only.title)"
            content.subtitle = repo.name
            content.userInfo = ["repoID": repo.id.uuidString, "path": "/tktview/\(only.ticketUUID)"]
        } else {
            content.title = "\(newRequests.count) requests on \(repo.name)"
            content.userInfo = ["repoID": repo.id.uuidString, "path": "/ticket"]
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "maintainer-request-\(repo.id.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil) // nil trigger = deliver as soon as possible
        _ = try? await center.add(request)
    }

    /// "The badge count is the number of open requests" (ticket 1a55c5d8b8)
    /// -- the app icon badge, distinct from any in-app UI. Safe to call even
    /// when notifications are off/undetermined: an un-granted `.badge`
    /// permission just makes this a no-op rather than an error.
    func updateBadge(_ count: Int) async {
        _ = try? await center.setBadgeCount(count)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Without this, a notification that arrives while Stone is already in
    /// the foreground is suppressed entirely by default.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .badge, .sound, .list]
    }

    /// Tapping the notification: route to the repo's ticket page
    /// (RepoWebView), via DeepLinkRouter -- RepoListView pushes the repo,
    /// RepoDetailView loads the path once its local server is up.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let repoIDString = info["repoID"] as? String,
              let repoID = UUID(uuidString: repoIDString),
              let path = info["path"] as? String else { return }
        await DeepLinkRouter.shared.route(repoID: repoID, path: path)
    }
}
