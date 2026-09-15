import XCTest

/// End-to-end UI coverage for the highest-value flow named in ticket
/// cfcc7e04d5's "done when": part 2 of that ticket (a small XCUITest slice)
/// never actually landed -- only the unit-test target did (RepoStoreSync-
/// CredentialTests, FossilEngineServerTests, BuildIdentityTests,
/// AgentSessionTests). This is that missing slice: add a repository through
/// the real app UI, open it, and confirm the embedded Fossil server actually
/// renders a page in the WKWebView -- not just that RepoStore's methods
/// return successfully in isolation, which the unit tests already cover.
///
/// Uses "New Local" rather than "Clone Remote": cloning needs a reachable
/// remote Fossil server, which this environment has no way to provide as a
/// deterministic, offline test fixture, and CI/simulator runs can't depend
/// on real network access to a live ollama.openbeagle.org server. Creating a
/// local repo and browsing its own rendered home page still exercises the
/// actual point of Stone's UI architecture -- rendering Fossil's own real
/// HTML from the in-process server, with zero drift from upstream -- without
/// that network dependency. The session-thread "see a reply appear" flow
/// the ticket also names depends on a live remote too, so it's left for a
/// later pass once a test-remote fixture exists; adding it now, unverified
/// and unrunnable from this environment, would risk shipping a test that
/// looks like coverage but was never actually exercised.
final class StoneUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCreateLocalRepoAndBrowseItsHomePage() throws {
        let app = XCUIApplication()
        app.launch()

        // Unique per run so repeated test runs on the same simulator (which
        // persists app data across launches, unlike derivedDataPath) never
        // collide with a leftover repo from a prior run.
        let repoName = "UITest-\(Int(Date().timeIntervalSince1970))"

        let addButton = app.buttons["addRepoButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10),
                      "add-repo button never appeared -- repo list failed to load")
        addButton.tap()

        let modePicker = app.segmentedControls["addRepoModePicker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 5), "Add Repository sheet never appeared")
        modePicker.buttons["New Local"].tap()

        let nameField = app.textFields["repoNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(repoName)

        let submitButton = app.buttons["addRepoSubmitButton"]
        XCTAssertTrue(submitButton.isEnabled, "Create should be enabled once a name is entered")
        submitButton.tap()

        // AddRepoView.submit() only calls dismiss() after RepoStore.create-
        // Repo() succeeds -- so the sheet closing and the new row appearing
        // is itself proof creation succeeded, not just that the tap
        // registered.
        let newRepoText = app.staticTexts[repoName]
        XCTAssertTrue(newRepoText.waitForExistence(timeout: 15),
                      "new repo row never appeared -- repo creation likely failed")

        // Best-effort: delete the repo again once this test is done with it,
        // however it ends, so repeated local/CI runs don't pile up throwaway
        // repos in the simulator's persisted state. Deliberately not
        // XCTAssert-backed -- a selector mismatch here must never turn a
        // passing feature test red over cleanup housekeeping.
        addTeardownBlock {
            let row = app.staticTexts[repoName]
            guard row.waitForExistence(timeout: 5) else { return }
            row.swipeLeft()
            let deleteSwipeAction = app.buttons["Delete"]
            guard deleteSwipeAction.waitForExistence(timeout: 5) else { return }
            deleteSwipeAction.tap()
            let confirmButton = app.buttons["Delete \(repoName)"]
            if confirmButton.waitForExistence(timeout: 5) {
                confirmButton.tap()
            }
        }

        newRepoText.tap()

        // The embedded Fossil server has to actually start, and WKWebView
        // has to actually render its response -- this is the real
        // regression this test guards against. "A page browsed" means a
        // WKWebView with real content, not just a screen transition, since
        // Stone's whole UI strategy is rendering Fossil's own HTML rather
        // than reimplementing it natively.
        let webView = app.webViews["repoWebView"]
        XCTAssertTrue(webView.waitForExistence(timeout: 20),
                      "repo screen never showed its WKWebView -- local Fossil server likely failed to start (see ticket a7c72aba15)")
        XCTAssertTrue(webView.staticTexts.firstMatch.waitForExistence(timeout: 20),
                      "WKWebView appeared but never rendered any readable content")

        // Leave the repo via the Home button (ticket 052e109e94's shipped
        // design) to confirm that control actually returns to the list too,
        // not just that browsing worked.
        app.buttons["Repositories"].tap()
        XCTAssertTrue(app.staticTexts[repoName].waitForExistence(timeout: 10),
                      "repo list never reappeared after tapping Home")
    }
}
