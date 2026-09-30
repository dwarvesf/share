import XCTest
@testable import ShareBarCore

final class RowAndModelRulesTests: XCTestCase {
    // MARK: - Trailing text

    func testLiveKindShowsLiveRegardlessOfExpires() {
        let now = Date()
        let share = makeShare(kind: "live", expires: Int(now.timeIntervalSince1970) + 3_600)
        XCTAssertEqual(rowFor(share, now: now).trailing, "live")
    }

    func testExpiresZeroShowsNever() {
        let share = makeShare(kind: "snapshot", expires: 0)
        XCTAssertEqual(rowFor(share).trailing, "never")
    }

    func testExpiresEqualToNowShowsExpired() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970))
        XCTAssertEqual(rowFor(share, now: now).trailing, "expired")
    }

    func testExpiresInThePastShowsExpired() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970) - 10)
        XCTAssertEqual(rowFor(share, now: now).trailing, "expired")
    }

    func testExactlyTwentyFourHoursLeftShowsOneDayNotTwentyFourHours() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970) + 86_400)
        XCTAssertEqual(rowFor(share, now: now).trailing, "1d left")
    }

    func testExactlySixtyMinutesLeftShowsOneHourNotSixtyMinutes() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970) + 3_600)
        XCTAssertEqual(rowFor(share, now: now).trailing, "1h left")
    }

    func testUnderOneMinuteLeftFloorsToOneMinuteNeverZero() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970) + 5)
        XCTAssertEqual(rowFor(share, now: now).trailing, "1m left")
    }

    func testFortyFiveMinutesLeftShowsMinutes() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970) + 45 * 60)
        XCTAssertEqual(rowFor(share, now: now).trailing, "45m left")
    }

    func testTwoDaysLeftShowsDays() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970) + 2 * 86_400 + 100)
        XCTAssertEqual(rowFor(share, now: now).trailing, "2d left")
    }

    func testJustUnderTwoDaysLeftFloorsToOneDayNotTwo() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970) + 2 * 86_400 - 1)
        XCTAssertEqual(rowFor(share, now: now).trailing, "1d left")
    }

    func testJustUnderTwoHoursLeftFloorsToOneHourNotTwo() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970) + 2 * 3_600 - 1)
        XCTAssertEqual(rowFor(share, now: now).trailing, "1h left")
    }

    func testOneHundredNineteenSecondsLeftFloorsToOneMinuteNotTwo() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970) + 119)
        XCTAssertEqual(rowFor(share, now: now).trailing, "1m left")
    }

    func testThirtySecondsLeftFloorsToTheOneMinuteMinimum() {
        let now = Date()
        let share = makeShare(expires: Int(now.timeIntervalSince1970) + 30)
        XCTAssertEqual(rowFor(share, now: now).trailing, "1m left")
    }

    // MARK: - canCopy / canRefresh

    func testCanCopyIsFalseForAPendingQuickURL() {
        let share = makeShare(url: "https://<pending>.trycloudflare.com/abc123/notes.txt")
        XCTAssertFalse(rowFor(share).canCopy)
    }

    func testCanCopyIsFalseForANoHostnameURL() {
        let share = makeShare(url: "https://<no-hostname>/abc123/notes.txt")
        XCTAssertFalse(rowFor(share).canCopy)
    }

    func testCanCopyIsTrueForAResolvedURL() {
        let share = makeShare(url: "https://s.han.ws/abc123/notes.txt")
        XCTAssertTrue(rowFor(share).canCopy)
    }

    func testCanRefreshIsTrueOnlyForSnapshot() {
        XCTAssertTrue(rowFor(makeShare(kind: "snapshot")).canRefresh)
        XCTAssertFalse(rowFor(makeShare(kind: "live")).canRefresh)
    }

    // MARK: - removeText

    func testRemoveTextForAPlainShare() {
        let share = makeShare(name: "notes.txt", ownHost: nil)
        XCTAssertEqual(rowFor(share).removeText, "Remove notes.txt? The copy goes to the Trash.")
    }

    func testRemoveTextForAnOwnHostShareNamesTheDNSRecord() {
        let share = makeShare(name: "docs.example.com", ownHost: "docs.example.com")
        XCTAssertEqual(
            rowFor(share).removeText,
            "Remove docs.example.com? This also deletes the DNS record for docs.example.com."
        )
    }

    // MARK: - Title

    func testOwnHostRowIsTitledByTheHost() {
        let share = makeShare(name: "docs.example.com", ownHost: "docs.example.com")
        XCTAssertEqual(rowFor(share).title, "docs.example.com")
    }

    func testPlainRowIsTitledByTheName() {
        let share = makeShare(name: "notes.txt", ownHost: nil)
        XCTAssertEqual(rowFor(share).title, "notes.txt")
    }

    // MARK: - gated rows

    func testGatedRowGetsTheGateTextAndMarker() {
        let gated = rowFor(makeShare(name: "ops-report.pdf", access: "group:dwarves-ops"))
        XCTAssertEqual(gated.access, "group:dwarves-ops")
        XCTAssertEqual(gated.accessibilityTitle, "ops-report.pdf, never, login required")
        XCTAssertEqual(gated.removeText, "Remove ops-report.pdf? The copy goes to the Trash and its login gate is deleted.")

        let gatedOwnHost = rowFor(makeShare(name: "docs", ownHost: "docs.example.com", access: "email:a@x.io"))
        XCTAssertEqual(
            gatedOwnHost.removeText,
            "Remove docs? This also deletes the DNS record for docs.example.com and its login gate."
        )
    }

    func testPublicRowHasNoGateText() {
        let row = rowFor(makeShare(name: "notes.txt"))
        XCTAssertNil(row.access)
        XCTAssertEqual(row.accessibilityTitle, "notes.txt, never")
    }

    // MARK: - per-profile section rules

    func testShowStartAndShowStopApplyPerProfile() {
        let profiles = makeProfiles([
            makeEntry(name: "a", state: makeSnapshot(state: "stopped", servesHere: true)),
            makeEntry(name: "b", state: makeSnapshot(state: "serving", servesHere: true)),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())

        XCTAssertTrue(model.sections[0].showStart)
        XCTAssertFalse(model.sections[0].showStop)
        XCTAssertFalse(model.sections[1].showStart)
        XCTAssertTrue(model.sections[1].showStop)
    }

    func testAnR2ProfileOffersNeitherStartNorStop() throws {
        // the shape `share state` prints on an r2 profile: serving, never serves_here
        let json = """
        {"schema":1,"profiles":[
          {"name":"f","state":{"schema":1,"state":"serving","ready":true,"mode":"named",
            "host":"f.example.test","hosts":"","serves_here":false,"service":false,
            "access_pending":0,"backend":"r2","shares":[
              {"id":"abc123","name":"n","url":"https://f.example.test/abc123/n","kind":"snapshot",
               "own_host":null,"expires":0,"access":"email:a@x.io"}]}},
          {"name":"t","state":{"schema":1,"state":"serving","ready":true,"mode":"named",
            "host":"t.example.test","hosts":"h","serves_here":true,"service":false,
            "access_pending":0,"shares":[]}}
        ]}
        """
        let profiles = try JSONDecoder().decode(ProfilesSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(profiles.profiles[0].state?.backend, "r2")
        XCTAssertNil(profiles.profiles[1].state?.backend, "a tunnel state has no backend key")

        let model = MenuModel(profiles: profiles, failure: nil, now: Date())
        XCTAssertEqual(model.sections[0].health, .ok)
        XCTAssertEqual(model.sections[0].rows.first?.access, "email:a@x.io")
        XCTAssertFalse(model.sections[0].showStart)
        XCTAssertFalse(model.sections[0].showStop, "the CLI refuses stop on an r2 profile")
        XCTAssertTrue(model.sections[1].showStop, "a serving tunnel profile still offers Stop")
    }

    func testShowSetUpFollowsTheNotServingRuleExceptForErrorSections() {
        let profiles = makeProfiles([
            makeEntry(name: "a", state: makeSnapshot(state: "stopped", servesHere: true)),
            makeEntry(name: "b", state: makeSnapshot(state: "serving", servesHere: true)),
            makeEntry(name: "Bad", error: "share: bad profile name 'Bad'"),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())

        XCTAssertTrue(model.sections[0].showSetUp, "stopped: rerunning setup is the recovery")
        XCTAssertFalse(model.sections[1].showSetUp, "serving has nothing to set up")
        XCTAssertFalse(model.sections[2].showSetUp, "an error section offers no action")
    }

    func testSectionTitleFieldsAndCommand() {
        let profiles = makeProfiles([
            makeEntry(name: "default", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false)),
            makeEntry(name: "dfoundation", state: makeSnapshot(state: "serving", ready: true, host: "s.d.foundation")),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())

        XCTAssertEqual(model.sections[0].profile, "default")
        XCTAssertNil(model.sections[0].host)
        XCTAssertEqual(model.sections[0].status, "Not set up")
        XCTAssertEqual(model.sections[0].command, "share")
        XCTAssertEqual(model.sections[1].command, "share --profile dfoundation")
    }

    func testShowCopyInstallCommandIsTrueOnlyWhenCLIIsNotFound() {
        XCTAssertTrue(MenuModel(profiles: nil, failure: .cliNotFound, now: Date()).showCopyInstallCommand)
        XCTAssertFalse(MenuModel(profiles: nil, failure: .oldCLI, now: Date()).showCopyInstallCommand)
        XCTAssertFalse(MenuModel(profiles: try? loadFixtureProfiles(), failure: nil, now: Date()).showCopyInstallCommand)
    }

    func testShowCopyUpgradeCommandIsTrueOnlyWhenCLIIsOld() {
        XCTAssertTrue(MenuModel(profiles: nil, failure: .oldCLI, now: Date()).showCopyUpgradeCommand)
        XCTAssertFalse(MenuModel(profiles: nil, failure: .cliNotFound, now: Date()).showCopyUpgradeCommand)
        XCTAssertFalse(MenuModel(profiles: try? loadFixtureProfiles(), failure: nil, now: Date()).showCopyUpgradeCommand)
    }

    // MARK: - row caps

    func testOneSetUpProfileCapsAt25() {
        let shares = (1...30).map { makeShare(id: "id\($0)", name: "file\($0).txt") }
        let profiles = makeProfiles([
            makeEntry(name: "default", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false)),
            makeEntry(name: "a", state: makeSnapshot(state: "serving", shares: shares)),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())

        let section = model.sections[1]
        XCTAssertEqual(section.rows.count, 25)
        XCTAssertEqual(section.more, 5)
        XCTAssertEqual(section.command, "share --profile a")
        XCTAssertEqual(section.rows.map(\.id), shares.prefix(25).map(\.id), "cap keeps the given order")
    }

    func testTwoSetUpProfilesCapAt10Each() {
        let shares = (1...30).map { makeShare(id: "id\($0)", name: "file\($0).txt") }
        let profiles = makeProfiles([
            makeEntry(name: "a", state: makeSnapshot(state: "serving", shares: shares)),
            makeEntry(name: "b", state: makeSnapshot(state: "serving", shares: shares)),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())

        for section in model.sections {
            XCTAssertEqual(section.rows.count, 10)
            XCTAssertEqual(section.more, 20)
        }
    }

    func testTheSameIdUnderTwoProfilesKeepsDistinctKeys() {
        let share = makeShare(id: "abc123")
        let profiles = makeProfiles([
            makeEntry(name: "a", state: makeSnapshot(state: "serving", shares: [share])),
            makeEntry(name: "b", state: makeSnapshot(state: "serving", shares: [share])),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())

        let keys = model.sections.flatMap { $0.rows.map(\.key) }
        XCTAssertEqual(keys, ["a|abc123", "b|abc123"])
        XCTAssertEqual(Set(keys).count, 2)
    }

    // MARK: - access_pending

    func testAccessPendingCountLandsOnTheSection() {
        let profiles = makeProfiles([
            makeEntry(name: "a", state: makeSnapshot(state: "serving", accessPending: 2)),
        ])
        let model = MenuModel(profiles: profiles, failure: nil, now: Date())

        XCTAssertEqual(model.sections[0].accessPending, 2)
        XCTAssertEqual(model.sections[0].command, "share --profile a")
    }

    // MARK: - helpers

    private func rowFor(_ share: Share, now: Date = Date()) -> Row {
        Row(share: share, profile: "default", now: now)
    }
}
