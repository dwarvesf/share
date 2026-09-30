import XCTest
@testable import ShareBarCore

/// The health table, the worst-health icon rule, and every header rule in the precedence
/// order the spec lists: the Working line; `Loading…`; `share CLI not found`;
/// `Update share CLI`; `Update Share Bar`; the `profiles --json` failure line;
/// `Needs attention: <names>`; `Serving at <hosts>`; `Not serving on this Mac`;
/// `Not set up`.
final class MenuModelHeaderTests: XCTestCase {
    // MARK: - health table (first match wins)

    func testHealthTableMatchesTheSpecRows() {
        XCTAssertEqual(Health.of(makeEntry(name: "e", error: "share: bad profile name 'Bad'")), .error)
        XCTAssertEqual(Health.statusText(of: makeEntry(name: "e", error: "share: bad profile name 'Bad'")), "Error: share: bad profile name 'Bad'")
        XCTAssertEqual(Health.of(makeEntry(name: "u", error: "Update Share Bar")), .error)
        XCTAssertEqual(Health.statusText(of: makeEntry(name: "u", error: "Update Share Bar")), "Update Share Bar")
        XCTAssertEqual(Health.of(makeEntry(name: "n", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false))), .notSetUp)
        XCTAssertEqual(Health.of(makeEntry(name: "x", state: makeSnapshot(state: "stopped", servesHere: false))), .elsewhere)
        XCTAssertEqual(Health.of(makeEntry(name: "s", state: makeSnapshot(state: "stopped", servesHere: true))), .stopped)
        XCTAssertEqual(Health.of(makeEntry(name: "t", state: makeSnapshot(state: "serving", ready: false))), .tunnelDown)
        XCTAssertEqual(Health.of(makeEntry(name: "o", state: makeSnapshot(state: "serving", ready: true))), .ok)
    }

    func testNotSetUpWinsOverElsewhereWhenServesHereIsFalse() {
        // The Mini's unset default reports serves_here false; it must classify notSetUp
        // (neutral), never elsewhere, and never error.
        let entry = makeEntry(name: "default", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false))
        XCTAssertEqual(Health.of(entry), .notSetUp)
        XCTAssertTrue(Health.of(entry).isNeutral)
        XCTAssertFalse(Health.of(entry).isAttention)
        XCTAssertEqual(Health.statusText(of: entry), "Not set up")
    }

    func testElsewhereStatusNamesTheHostsList() {
        let entry = makeEntry(name: "a", state: makeSnapshot(state: "stopped", hosts: "other-mac", servesHere: false))
        XCTAssertEqual(Health.of(entry), .elsewhere)
        XCTAssertEqual(Health.statusText(of: entry), "Not serving on this Mac (hosts=other-mac)")
    }

    // MARK: - header precedence before any profile rule

    func testLoadingBeforeFirstResultShowsLoadingNotNotSetUp() {
        let model = MenuModel(profiles: nil, failure: nil, now: Date())
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.header, "Loading…")
        XCTAssertEqual(model.icon, .disconnected)
    }

    func testCLINotFound() {
        let model = MenuModel(profiles: nil, failure: .cliNotFound, now: Date())
        XCTAssertEqual(model.header, "share CLI not found")
        XCTAssertTrue(model.showCopyInstallCommand)
        XCTAssertFalse(model.showCopyUpgradeCommand)
    }

    func testOldCLI() {
        let model = MenuModel(profiles: nil, failure: .oldCLI, now: Date())
        XCTAssertEqual(model.header, "Update share CLI")
        XCTAssertTrue(model.showCopyUpgradeCommand)
        XCTAssertFalse(model.showCopyInstallCommand)
    }

    func testTopLevelSchemaAboveOneIsTheGlobalUpdateShareBarHeader() {
        let profiles = makeProfiles([
            makeEntry(name: "a", state: makeSnapshot(state: "serving", ready: true)),
        ], schema: 2)
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())

        XCTAssertEqual(model.header, "Update Share Bar")
        XCTAssertTrue(model.sections.isEmpty, "a listing this app cannot read renders like .oldCLI: no sections")
        XCTAssertEqual(model.icon, .disconnected)
        XCTAssertFalse(model.canPublish)
        XCTAssertTrue(PublishChoice.eligible(profiles).isEmpty, "the publish dialog offers no profile")
    }

    func testTheFailureLineWinsOverEveryProfileRuleWhenThereIsNoSnapshot() {
        let model = MenuModel(profiles: nil, failure: .other("share: jq: command not found"), now: Date())
        XCTAssertEqual(model.header, "share: jq: command not found")
    }

    // MARK: - the Mini shape: a neutral default never slashes a healthy profile

    func testMiniFixtureIsConnectedAndServingHeader() throws {
        // default not_setup (serves_here false), dfoundation serving and ready.
        let model = MenuModel(profiles: try loadFixtureProfiles(), failure: nil, now: Date())

        XCTAssertEqual(model.icon, .connected)
        XCTAssertEqual(model.header, "Serving at s.d.foundation")
        XCTAssertEqual(model.sections.count, 2)
        XCTAssertEqual(model.sections[0].health, .notSetUp)
        XCTAssertTrue(model.sections[0].showSetUp)
        XCTAssertEqual(model.sections[1].health, .ok)
    }

    // MARK: - attention profiles

    func testOneAttentionProfileNamesItWithItsStatus() {
        let profiles = makeProfiles([
            makeEntry(name: "default", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false)),
            makeEntry(name: "dfoundation", state: makeSnapshot(state: "stopped", servesHere: true)),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())

        XCTAssertEqual(model.icon, .disconnected)
        XCTAssertEqual(model.header, "Needs attention: dfoundation (Stopped)")
        XCTAssertTrue(model.sections[1].showSetUp, "a stopped profile can be set up again")
        XCTAssertEqual(model.sections[1].host, "s.han.ws")
    }

    func testTunnelDownAndErrorBothCountAsAttention() {
        let down = makeProfiles([makeEntry(name: "dfoundation", state: makeSnapshot(state: "serving", ready: false))])
        XCTAssertEqual(MenuModel(profiles: down, failure: nil, now: Date()).header, "Needs attention: dfoundation (Tunnel not connected)")

        let errored = makeProfiles([makeEntry(name: "Bad", error: "share: bad profile name 'Bad'")])
        let model = MenuModel(profiles: errored, failure: nil, now: Date())
        XCTAssertEqual(model.header, "Needs attention: Bad (Error: share: bad profile name 'Bad')")
        XCTAssertEqual(model.sections[0].status, "Error: share: bad profile name 'Bad'")
        XCTAssertFalse(model.sections[0].showSetUp, "an error section offers no action")
        XCTAssertFalse(model.sections[0].showStart)
        XCTAssertFalse(model.sections[0].showStop)
    }

    func testTwoAttentionProfilesListBothNames() {
        let profiles = makeProfiles([
            makeEntry(name: "a", state: makeSnapshot(state: "stopped", servesHere: true)),
            makeEntry(name: "b", state: makeSnapshot(state: "serving", ready: false)),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())
        XCTAssertEqual(model.header, "Needs attention: a, b")
    }

    // MARK: - serving / elsewhere / not set up

    func testServingAtHost() {
        let profiles = makeProfiles([makeEntry(name: "default", state: makeSnapshot(state: "serving", ready: true, host: "s.han.ws"))])
        XCTAssertEqual(MenuModel(profiles: profiles, failure: nil, now: Date()).header, "Serving at s.han.ws")
    }

    func testNotServingOnThisMacWhenEverySetUpProfileIsElsewhere() {
        let profiles = makeProfiles([
            makeEntry(name: "a", state: makeSnapshot(state: "stopped", hosts: "other-mac", servesHere: false)),
            makeEntry(name: "b", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false)),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())
        XCTAssertEqual(model.header, "Not serving on this Mac")
        XCTAssertEqual(model.icon, .disconnected)
    }

    func testNotSetUpWhenNoProfileIsSetUp() {
        let profiles = makeProfiles([
            makeEntry(name: "default", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false)),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())
        XCTAssertEqual(model.header, "Not set up")
        XCTAssertEqual(model.icon, .disconnected)
    }

    // MARK: - working header

    func testWorkingPlainShowsThePlainLine() {
        let model = MenuModel(profiles: try? loadFixtureProfiles(), failure: nil, now: Date(), working: .plain)
        XCTAssertEqual(model.header, "Working…")
    }

    func testWorkingGatedAddNamesTheGateWait() {
        let model = MenuModel(profiles: try? loadFixtureProfiles(), failure: nil, now: Date(), working: .gatedAdd)
        XCTAssertEqual(model.header, "Working… (a login gate can take minutes)")
    }

    func testWorkingWinsEvenOverAFailure() {
        let model = MenuModel(profiles: nil, failure: .cliNotFound, now: Date(), working: .plain)
        XCTAssertEqual(model.header, "Working…")
    }

    // MARK: - stale snapshot (failed refresh keeps the last good one)

    func testFailedRefreshKeepsSectionsButSlashesIconAndShowsFailure() {
        let profiles = makeProfiles([
            makeEntry(name: "dfoundation", state: makeSnapshot(state: "serving", ready: true, host: "s.d.foundation")),
        ])
        let model = MenuModel(profiles: profiles, failure: .other("share: timed out"), now: Date())

        XCTAssertEqual(model.sections.count, 1, "the good snapshot still renders")
        XCTAssertEqual(model.sections[0].health, .ok)
        XCTAssertEqual(model.header, "share: timed out")
        XCTAssertEqual(model.icon, .disconnected)
    }

    /// Row 14c through the real fold: a good read lands, then `.oldCLI`, then
    /// `.cliNotFound`, each folded over what the previous step left.
    func testCliNotFoundAndOldCLIClearTheSections() {
        let good = CLIResult(status: 0, stdout: """
        {"schema":1,"profiles":[{"name":"dfoundation","state":{"schema":1,"state":"serving",
         "ready":true,"mode":"named","host":"s.d.foundation","hosts":"","serves_here":true,
         "service":false,"access_pending":0,"shares":[]}}]}
        """, stderr: "", timedOut: false)
        let oldCLI = CLIResult(status: 0, stdout: "default\tnot_setup\t-\n", stderr: "", timedOut: false)
        let notFound = CLIResult(status: 127, stdout: "", stderr: "share: CLI not found", timedOut: false)

        let first = ProfilesSnapshot.fold(good, over: nil)
        XCTAssertEqual(MenuModel(profiles: first.profiles, failure: first.failure, now: Date()).sections.count, 1)

        let second = ProfilesSnapshot.fold(oldCLI, over: first.profiles)
        let old = MenuModel(profiles: second.profiles, failure: second.failure, now: Date())
        XCTAssertTrue(old.sections.isEmpty)
        XCTAssertEqual(old.header, "Update share CLI")

        let third = ProfilesSnapshot.fold(notFound, over: first.profiles)
        let missing = MenuModel(profiles: third.profiles, failure: third.failure, now: Date())
        XCTAssertTrue(missing.sections.isEmpty)
        XCTAssertEqual(missing.header, "share CLI not found")
    }

    func testAnOtherFailureKeepsTheLastGoodSnapshot() {
        let previous = makeProfiles([
            makeEntry(name: "dfoundation", state: makeSnapshot(state: "serving", ready: true)),
        ])
        let timedOut = CLIResult(status: 1, stdout: "", stderr: "share: timed out", timedOut: true)
        let folded = ProfilesSnapshot.fold(timedOut, over: previous)
        XCTAssertEqual(folded.profiles, previous)
        XCTAssertNotNil(folded.failure)
    }
}
