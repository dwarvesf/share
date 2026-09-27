import XCTest
@testable import ShareBarCore

final class LocateTests: XCTestCase {
    func testSHARE_BINWinsOutrightNoExistenceCheck() {
        // SHARE_BIN is a trusted override, same convention as SHARE_ROOT in bin/share:
        // it wins even when the injected fileExists check says nothing exists.
        let url = CLI.locate(env: ["SHARE_BIN": "/tmp/custom/share"], fileExists: { _ in false })
        XCTAssertEqual(url?.path, "/tmp/custom/share")
    }

    func testOrderPrefersHomebrewOverUsrLocal() {
        let url = CLI.locate(env: [:], fileExists: { _ in true })
        XCTAssertEqual(url?.path, "/opt/homebrew/bin/share")
    }

    func testFallsThroughToNextCandidateWhenEarlierOnesAreMissing() {
        let checked: (String) -> Bool = { path in
            path != "/opt/homebrew/bin/share" && path != "/usr/local/bin/share"
        }
        let url = CLI.locate(env: ["HOME": "/Users/tester"], fileExists: checked)
        XCTAssertEqual(url?.path, "/Users/tester/.local/bin/share")
    }

    func testHomeIsExpandedInSwiftNotLeftAsATilde() {
        let url = CLI.locate(
            env: ["HOME": "/Users/tester"],
            fileExists: { $0 == "/Users/tester/.local/bin/share" }
        )
        XCTAssertEqual(url?.path, "/Users/tester/.local/bin/share")
    }

    func testLastCandidateIsOptLocal() {
        let checked: (String) -> Bool = { $0 == "/opt/local/bin/share" }
        let url = CLI.locate(env: ["HOME": "/Users/tester"], fileExists: checked)
        XCTAssertEqual(url?.path, "/opt/local/bin/share")
    }

    func testNilWhenNothingIsFoundAndSHARE_BINIsUnset() {
        let url = CLI.locate(env: [:], fileExists: { _ in false })
        XCTAssertNil(url)
    }

    func testEmptySHARE_BINIsTreatedAsUnset() {
        let url = CLI.locate(env: ["SHARE_BIN": ""], fileExists: { _ in false })
        XCTAssertNil(url)
    }
}
