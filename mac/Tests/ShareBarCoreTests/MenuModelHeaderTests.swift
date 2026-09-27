import XCTest
@testable import ShareBarCore

/// Every header rule, in the precedence order the spec lists: `share CLI not found`;
/// `Update share CLI`; `Update Share Bar`; the failure line; `Not set up`;
/// `Not serving on this Mac (hosts=<hosts>)`; `Stopped`; `Serving, tunnel not connected`;
/// `Serving at <host>`.
final class MenuModelHeaderTests: XCTestCase {
    func testLoadingBeforeFirstResultShowsLoadingNotNotSetUp() {
        // The cold-launch instant: no state call has returned yet, so there is neither a
        // snapshot nor a failure. Must read "Loading…", never "Not set up".
        let model = MenuModel(snapshot: nil, failure: nil, now: Date())
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.header, "Loading…")
    }

    func testCLINotFound() {
        let model = MenuModel(snapshot: nil, failure: .cliNotFound, now: Date())
        XCTAssertEqual(model.header, "share CLI not found")
    }

    func testOldCLI() {
        let model = MenuModel(snapshot: nil, failure: .oldCLI, now: Date())
        XCTAssertEqual(model.header, "Update share CLI")
    }

    func testSchemaAboveOneWinsOverEveryStateRuleAndStillRendersRows() {
        let share = makeShare()
        let snapshot = makeSnapshot(schema: 2, state: "serving", ready: true, shares: [share])

        let model = MenuModel(snapshot: snapshot, failure: nil, now: Date())

        XCTAssertEqual(model.header, "Update Share Bar")
        XCTAssertEqual(model.rows.count, 1, "decodable fields still render under the header override")
    }

    func testTheFailureLineWinsOverEveryStateRuleWhenThereIsNoSnapshot() {
        let model = MenuModel(snapshot: nil, failure: .other("share: jq: command not found"), now: Date())
        XCTAssertEqual(model.header, "share: jq: command not found")
    }

    func testNotSetUp() {
        let snapshot = makeSnapshot(state: "not_setup")
        let model = MenuModel(snapshot: snapshot, failure: nil, now: Date())
        XCTAssertEqual(model.header, "Not set up")
    }

    func testNotSetUpWinsOverNotServingHereWhenBothConditionsHold() {
        // Precedence check: not_setup with serves_here false must still say "Not set up",
        // not "Not serving on this Mac".
        let snapshot = makeSnapshot(state: "not_setup", hosts: "other-mac", servesHere: false)
        let model = MenuModel(snapshot: snapshot, failure: nil, now: Date())
        XCTAssertEqual(model.header, "Not set up")
    }

    func testNotServingOnThisMac() {
        let snapshot = makeSnapshot(state: "stopped", hosts: "other-mac", servesHere: false)
        let model = MenuModel(snapshot: snapshot, failure: nil, now: Date())
        XCTAssertEqual(model.header, "Not serving on this Mac (hosts=other-mac)")
    }

    func testStopped() {
        let snapshot = makeSnapshot(state: "stopped", servesHere: true)
        let model = MenuModel(snapshot: snapshot, failure: nil, now: Date())
        XCTAssertEqual(model.header, "Stopped")
    }

    func testServingTunnelNotConnected() {
        let snapshot = makeSnapshot(state: "serving", ready: false)
        let model = MenuModel(snapshot: snapshot, failure: nil, now: Date())
        XCTAssertEqual(model.header, "Serving, tunnel not connected")
    }

    func testServingAtHost() {
        let snapshot = makeSnapshot(state: "serving", ready: true, host: "s.han.ws")
        let model = MenuModel(snapshot: snapshot, failure: nil, now: Date())
        XCTAssertEqual(model.header, "Serving at s.han.ws")
    }
}
