import XCTest
@testable import ShareBarCore

/// `RefreshGate` decides whether a refresh trigger starts a `profiles` run now, and
/// whether a `fresh` request that arrived mid-run gets its own run when that one ends.
final class RefreshGateTests: XCTestCase {
    func testAnIdleGateStartsARun() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.request(fresh: false))
    }

    func testAPlainRequestDuringARunIsDropped() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.request(fresh: false))
        XCTAssertFalse(gate.request(fresh: false))
        XCTAssertFalse(gate.finish(), "nothing pending: the gate goes idle")
        XCTAssertTrue(gate.request(fresh: false), "idle again after finish")
    }

    func testAFreshRequestDuringARunRunsWhenThatRunEnds() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.request(fresh: false), "the 60s poll is in flight")
        XCTAssertFalse(gate.request(fresh: true), "setup completion arrives mid-poll")
        XCTAssertTrue(gate.finish(), "the poll ends: the pending fresh run starts")
        XCTAssertFalse(gate.request(fresh: false), "that fresh run holds the gate")
        XCTAssertFalse(gate.finish(), "the fresh run ends with nothing pending")
    }

    func testSeveralFreshRequestsDuringOneRunCollapseToOne() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.request(fresh: false))
        XCTAssertFalse(gate.request(fresh: true))
        XCTAssertFalse(gate.request(fresh: true))
        XCTAssertTrue(gate.finish())
        XCTAssertFalse(gate.finish())
    }
}
