import XCTest
@testable import ShareBarCore

/// Cases the review of the foundations round added: an out-of-range `expires` never traps,
/// and an unknown member status never reads as a running verb.
final class ReviewHardeningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func share(expires: Int) -> Share {
        Share(id: "a1", name: "n.txt", url: "https://s.example.test/a1/n.txt", kind: "snapshot", ownHost: nil, expires: expires)
    }

    func testAnExtremeExpiresReadsExpiredAndNeverTraps() {
        for expires in [Int.min, Int.min + 1, -9_223_372_036_000_000_000, -1] {
            XCTAssertEqual(secondsLeft(expires, now: now), expires == -1 ? -1 - 1_800_000_000 : 0, "\(expires)")
            XCTAssertEqual(Row.trailingText(share: share(expires: expires), now: now), "expired")
            XCTAssertEqual(LinkView.timeLeft(of: share(expires: expires), now: now), "expired")
        }
    }

    func testAFarFutureExpiresStillReadsDaysLeft() {
        XCTAssertEqual(Row.trailingText(share: share(expires: Int.max), now: now).hasSuffix("d left"), true)
    }

    func testOnlyTheCLIsRunningStatusesReadAsRunning() throws {
        func status(_ value: String) throws -> MemberRecord {
            let json = #"{"member_id":"m-ann-0a1b2c3d","name":"ann","status":"\#(value)"}"#
            return try JSONDecoder().decode(MemberRecord.self, from: Data(json.utf8))
        }
        for running in ["adding", "joining", "pausing", "resuming", "inviting", "rotating", "renewing", "removing"] {
            XCTAssertTrue(try status(running).isRunning, running)
        }
        for settled in ["active", "paused", "invited", "removed", "left", "defrosting", "nothing-ing"] {
            XCTAssertFalse(try status(settled).isRunning, settled)
        }
    }
}
