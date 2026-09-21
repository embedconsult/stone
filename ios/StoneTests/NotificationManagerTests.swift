import UserNotifications
import XCTest
@testable import Stone

/// Regression coverage for ticket 0878b97fc2: NotificationManager's delegate
/// methods were `async` without `@MainActor`, so the completion-handler
/// bridge the compiler synthesizes for the ObjC `UNUserNotificationCenterDelegate`
/// requirements fired on whatever executor the async body happened to finish
/// on. UIKit asserts (SIGABRT) if that completion handler isn't called on the
/// main thread -- exactly what happened when a maintainer tapped a
/// maintainer-request notification.
///
/// The synthesized bridge is only reachable through the ObjC-style
/// `withCompletionHandler:` entry point, not by calling the `async` method
/// directly, so the test goes through `UNUserNotificationCenterDelegate`'s
/// optional protocol methods (which Swift maps back onto that synthesized
/// bridge) rather than `NotificationManager`'s own async functions.
final class NotificationManagerTests: XCTestCase {
    func testDidReceiveCompletionHandlerFiresOnMainThread() {
        let delegate: UNUserNotificationCenterDelegate = NotificationManager.shared
        let response = Self.makeResponse(userInfo: ["repoID": UUID().uuidString, "ticketUUID": "abc123"])

        let expectation = expectation(description: "completion handler called")
        Task.detached {
            delegate.userNotificationCenter?(
                .current(),
                didReceive: response,
                withCompletionHandler: {
                    XCTAssertTrue(Thread.isMainThread)
                    expectation.fulfill()
                }
            )
        }
        wait(for: [expectation], timeout: 5)
    }

    func testWillPresentCompletionHandlerFiresOnMainThread() {
        let delegate: UNUserNotificationCenterDelegate = NotificationManager.shared
        let notification = Self.makeNotification(userInfo: [:])

        let expectation = expectation(description: "completion handler called")
        Task.detached {
            delegate.userNotificationCenter?(
                .current(),
                willPresent: notification,
                withCompletionHandler: { _ in
                    XCTAssertTrue(Thread.isMainThread)
                    expectation.fulfill()
                }
            )
        }
        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Notification body per kind (acceptance: 2026-09-21 00:0xZ)

    /// The maintainer's own complaint: a notification body used to be just
    /// the kind's display name ("Decision"), never the actual question.
    /// `NotificationManager.body(for:)` is the pure logic behind the fix --
    /// pinned once per kind so each shape can't silently regress into
    /// another.
    func testTryThisBodyIsTheHumanVerifyPrompt() {
        let request = MaintainerRequest(
            ticketUUID: "t1", title: "Try the new build", mtime: "1", kind: .tryThis,
            humanVerify: "Build 27, tap Sync twice and confirm no crash.", latestCommentSummary: nil)
        XCTAssertEqual(NotificationManager.body(for: request), "Build 27, tap Sync twice and confirm no crash.")
    }

    func testTryThisBodyFallsBackToTitleWhenHumanVerifyIsMissing() {
        let request = MaintainerRequest(
            ticketUUID: "t1", title: "Try the new build", mtime: "1", kind: .tryThis,
            humanVerify: nil, latestCommentSummary: nil)
        XCTAssertEqual(NotificationManager.body(for: request), "Try the new build")
    }

    func testDecisionBodyCombinesTitleAndLatestNonOCXComment() {
        let request = MaintainerRequest(
            ticketUUID: "t1", title: "Pick a rollout strategy", mtime: "1", kind: .decision,
            humanVerify: nil, latestCommentSummary: "Ship to 10% or 100%?")
        XCTAssertEqual(NotificationManager.body(for: request), "Pick a rollout strategy — Ship to 10% or 100%?")
    }

    func testDecisionBodyFallsBackToTitleWhenNoCommentSummary() {
        let request = MaintainerRequest(
            ticketUUID: "t1", title: "Pick a rollout strategy", mtime: "1", kind: .decision,
            humanVerify: nil, latestCommentSummary: nil)
        XCTAssertEqual(NotificationManager.body(for: request), "Pick a rollout strategy")
    }

    func testMergeCardBodyIsTheTicketTitle() {
        let request = MaintainerRequest(
            ticketUUID: "t1", title: "Merge candidate A", mtime: "1", kind: .mergeCard,
            humanVerify: nil, latestCommentSummary: nil)
        XCTAssertEqual(NotificationManager.body(for: request), "Merge candidate A")
    }

    // MARK: - Fixtures

    /// `UNNotification`/`UNNotificationResponse` have no public initializer,
    /// so tests build them the same way the wider Swift community does: both
    /// conform to `NSSecureCoding`, and their `init(coder:)` only ever asks
    /// for a fixed, long-stable set of keys, so a tiny stub `NSCoder` can
    /// stand in for a real archive.
    private static func makeNotification(userInfo: [AnyHashable: Any]) -> UNNotification {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        return UNNotification(coder: StubCoder(request: request, date: Date()))!
    }

    private static func makeResponse(userInfo: [AnyHashable: Any]) -> UNNotificationResponse {
        let notification = makeNotification(userInfo: userInfo)
        return UNNotificationResponse(
            coder: StubCoder(notification: notification, actionIdentifier: UNNotificationDefaultActionIdentifier)
        )!
    }

    private final class StubCoder: NSCoder {
        private let request: UNNotificationRequest?
        private let date: Date?
        private let notification: UNNotification?
        private let actionIdentifier: String?

        init(request: UNNotificationRequest, date: Date) {
            self.request = request
            self.date = date
            self.notification = nil
            self.actionIdentifier = nil
            super.init()
        }

        init(notification: UNNotification, actionIdentifier: String) {
            self.notification = notification
            self.actionIdentifier = actionIdentifier
            self.request = nil
            self.date = nil
            super.init()
        }

        override var allowsKeyedCoding: Bool { true }

        override func decodeObject(forKey key: String) -> Any? {
            switch key {
            case "request": return request
            case "date": return date
            case "notification": return notification
            case "actionIdentifier": return actionIdentifier
            default: return nil
            }
        }
    }
}
