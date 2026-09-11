import XCTest
@testable import Stone

/// Regression coverage for the Xcode Cloud build stamp: ios/ci_scripts/
/// ci_post_clone.sh writes BuildCommit/BuildDate into Info.plist (CI_COMMIT,
/// falling back to `git rev-parse HEAD`), the same fields
/// scripts/run-on-device.sh stamps with a Fossil checkin hash for tethered
/// device builds. BuildIdentity.label is the single place that decides what
/// About/the build overlay render for either path, so it's tested directly
/// as a pure function rather than through a Bundle/Info.plist fixture.
final class BuildIdentityTests: XCTestCase {
    func testStampedCleanBuildRendersBareCommit() {
        XCTAssertEqual(BuildIdentity.label(commit: "e9583ff4d209", isDirty: false), "e9583ff4d209")
    }

    func testStampedDirtyBuildAppendsDirtySuffix() {
        XCTAssertEqual(BuildIdentity.label(commit: "e9583ff4d209", isDirty: true), "e9583ff4d209-dirty")
    }

    func testMissingCommitRendersUnstampedBuild() {
        XCTAssertEqual(BuildIdentity.label(commit: nil, isDirty: false), "Unstamped build")
    }

    func testEmptyCommitStringRendersUnstampedBuild() {
        XCTAssertEqual(BuildIdentity.label(commit: "", isDirty: false), "Unstamped build")
    }
}
