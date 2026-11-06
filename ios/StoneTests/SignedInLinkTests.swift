import XCTest
@testable import Stone

/// Which repository a conversation's link belongs to, so it opens signed in.
final class SignedInLinkTests: XCTestCase {
    private let stone = Repo(name: "Stone", fileName: "stone.fossil",
                             remoteURL: "https://x86-1-stone@ollama.openbeagle.org/stone")
    private let console = Repo(name: "Console", fileName: "console.fossil",
                               remoteURL: "https://ec2-user@ollama.openbeagle.org/ocx-console")

    func testLinkGoesToItsOwnRepository() throws {
        let url = try XCTUnwrap(URL(string: "https://ollama.openbeagle.org/ocx-console/ext/ocx2-cgi/app/console"))
        XCTAssertEqual(RemoteSiteView.repo(for: url, in: [stone, console])?.name, "Console")
    }

    func testPrefixOfAnotherNameDoesNotMatch() throws {
        let url = try XCTUnwrap(URL(string: "https://ollama.openbeagle.org/stonework/timeline"))
        XCTAssertNil(RemoteSiteView.repo(for: url, in: [stone, console]))
    }

    func testOtherHostsOpenAsBefore() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/embedconsult/stone"))
        XCTAssertNil(RemoteSiteView.repo(for: url, in: [stone, console]))
    }
}
