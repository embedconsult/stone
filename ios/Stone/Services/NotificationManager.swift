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
    ///
    /// Ticket 4c75227cc7: the repo always goes in the subtitle and the
    /// kind(s) in the body, so a maintainer can tell what a notification is
    /// about without opening it. A single new request names its own ticket
    /// and deep-links straight to it; several at once have no single
    /// target, so they deep-link to the Requests screen instead
    /// (NotificationManager.userNotificationCenter(didReceive:)).
    func post(for repo: Repo, newRequests: [MaintainerRequest]) async {
        guard isEnabled, !newRequests.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.subtitle = repo.name
        content.sound = .default

        if newRequests.count == 1, let only = newRequests.first {
            content.title = only.title
            content.body = Self.body(for: only)
            // Carries the repo id plus the ticket uuid (not a path) --
            // ticket 98c06fb7a7: `TicketOpener` verifies the ticket is
            // actually in this repo's clone before routing to it, so the
            // handler needs the uuid on its own, not a pre-built local path.
            // `kind` rides along too (as the server's own `needs_you`
            // string) so the tap resolves to the same kind-specific target
            // TicketOpener would pick right now, not just wherever a plain
            // ticket-uuid lookup would land.
            content.userInfo = [
                "repoID": repo.id.uuidString,
                "ticketUUID": only.ticketUUID,
                "kind": only.kind.needsYouValue,
            ]
        } else {
            content.title = "\(newRequests.count) requests"
            let kinds = Set(newRequests.map(\.kind.displayName)).sorted()
            content.body = kinds.joined(separator: ", ")
            content.userInfo = ["screen": "requests"]
        }

        let request = UNNotificationRequest(
            identifier: "maintainer-request-\(repo.id.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil) // nil trigger = deliver as soon as possible
        _ = try? await center.add(request)
    }

    /// The maintainer's own follow-up complaint: a notification's body used
    /// to just be the kind's display name ("Merge card"/"Decision"/"Try
    /// this") -- never enough to act on without opening the app first. Each
    /// kind now carries the text that's actually informative for it:
    /// try-this's own instructions, a decision's question (its latest
    /// non-`OCX-` comment), or -- for a merge card, which has no question of
    /// its own to ask -- the ticket title, same as a bare "what is this"
    /// would show.
    ///
    /// Not `private`, so StoneTests can pin each kind's body shape via
    /// `@testable import` without needing a real `UNNotificationRequest`
    /// round trip.
    static func body(for request: MaintainerRequest) -> String {
        switch request.kind {
        case .mergeCard:
            return request.title
        case .tryThis:
            if let humanVerify = request.humanVerify, !humanVerify.isEmpty {
                return humanVerify
            }
            return request.title
        case .decision:
            if let comment = request.latestCommentSummary, !comment.isEmpty {
                return "\(request.title) — \(comment)"
            }
            return request.title
        }
    }

    /// "The badge count is the number of open requests" (ticket 1a55c5d8b8)
    /// -- the app icon badge, distinct from any in-app UI. Safe to call even
    /// when notifications are off/undetermined: an un-granted `.badge`
    /// permission just makes this a no-op rather than an error.
    func updateBadge(_ count: Int) async {
        _ = try? await center.setBadgeCount(count)
    }
}

/// @MainActor here isn't just style: these are `async` implementations of
/// ObjC-bridged `UNUserNotificationCenterDelegate` methods, so the compiler
/// synthesizes a completion-handler-based bridge for UIKit to call, and that
/// bridge invokes the completion handler on whatever executor the async body
/// finished on. Off the main actor, UIKit asserts (SIGABRT) because it
/// requires that completion handler on the main thread -- ticket 0878b97fc2.
extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Without this, a notification that arrives while Stone is already in
    /// the foreground is suppressed entirely by default.
    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .badge, .sound, .list]
    }

    /// Tapping the notification: resolve to the repo's ticket page via
    /// `TicketOpener` (ticket 98c06fb7a7) -- verifies the ticket is actually
    /// in that repo's local clone (syncing once if not) before routing
    /// there, and falls back to the server's own ticket page over https
    /// rather than ever opening an empty local one. A coalesced notification
    /// (several requests, no single ticket to name) carries
    /// `"screen": "requests"` instead of a repo/ticket pair, and opens the
    /// Requests screen (ticket 4c75227cc7) rather than any one repo.
    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if info["screen"] as? String == "requests" {
            DeepLinkRouter.shared.routeToRequestsScreen()
            return
        }
        guard let repoIDString = info["repoID"] as? String,
              let repoID = UUID(uuidString: repoIDString),
              let ticketUUID = info["ticketUUID"] as? String,
              let kindString = info["kind"] as? String,
              let kind = MaintainerRequest.Kind(needsYouValue: kindString),
              let repo = RepoStore.shared.repos.first(where: { $0.id == repoID }) else { return }
        await TicketOpener.open(repo: repo, ticketUUID: ticketUUID, kind: kind)
    }
}
