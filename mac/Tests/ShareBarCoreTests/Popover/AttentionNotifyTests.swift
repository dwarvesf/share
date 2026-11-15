import XCTest
@testable import ShareBarCore

/// General's Notify me when toggles and the After sharing failure line.
final class AttentionNotifyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let all = NotifyPrefs(offline: true, expiry: true, member: true)

    private func profiles(state: String = "live", expires: Int = 4_102_444_800) -> ProfilesSnapshot {
        let share = makeShare(id: "x1", name: "deck.pdf", url: "u", expires: expires, storage: "machine", by: "Mac", linkState: state)
        return makeProfiles([("p", makeSnapshot(host: "s.t", shares: [share], role: "origin", tier: "t0"))])
    }

    func testTheFirstReadOnlyPrimes() {
        var notifier = AttentionNotifier()
        XCTAssertEqual(notifier.events(profiles: profiles(state: "offline"), members: [:], prefs: all, current: "p", now: now), [])
    }

    func testAnOwnLinkGoingOfflineNotifiesOnceAndRefiresAfterItClears() {
        var notifier = AttentionNotifier()
        _ = notifier.events(profiles: profiles(), members: [:], prefs: all, current: "p", now: now)
        let first = notifier.events(profiles: profiles(state: "offline"), members: [:], prefs: all, current: "p", now: now)
        XCTAssertEqual(first.map(\.title), ["Mac is offline"])
        XCTAssertEqual(notifier.events(profiles: profiles(state: "offline"), members: [:], prefs: all, current: "p", now: now), [])
        _ = notifier.events(profiles: profiles(), members: [:], prefs: all, current: "p", now: now)
        XCTAssertEqual(notifier.events(profiles: profiles(state: "offline"), members: [:], prefs: all, current: "p", now: now).count, 1)
    }

    func testAToggleThatIsOffSaysNothing() {
        var notifier = AttentionNotifier()
        let off = NotifyPrefs(offline: false, expiry: false, member: false)
        _ = notifier.events(profiles: profiles(), members: [:], prefs: off, current: "p", now: now)
        XCTAssertEqual(notifier.events(profiles: profiles(state: "offline"), members: [:], prefs: off, current: "p", now: now), [])
    }

    func testALinkAboutToExpireNotifies() {
        var notifier = AttentionNotifier()
        _ = notifier.events(profiles: profiles(), members: [:], prefs: all, current: "p", now: now)
        let soon = Int(now.timeIntervalSince1970) + 3 * 3_600
        let events = notifier.events(profiles: profiles(expires: soon), members: [:], prefs: all, current: "p", now: now)
        XCTAssertEqual(events.map(\.title), ["deck.pdf expires soon"])
        XCTAssertTrue(events[0].body.contains("3 hours"))
    }

    func testFailureLineSplitsTheNextStep() {
        XCTAssertEqual(FailureLine.split("Couldn't publish: no. Next: share status").next, "share status")
        XCTAssertEqual(FailureLine.split("Couldn't publish: no. Next: share status").sentence, "Couldn't publish: no.")
        XCTAssertNil(FailureLine.split("Couldn't publish: no.").next)
    }
}
