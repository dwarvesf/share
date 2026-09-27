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
        XCTAssertEqual(rowFor(share, now: Date()).trailing, "never")
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

    // MARK: - showStart / showSetUp

    func testShowStartIsFalseWhenServing() {
        let snapshot = makeSnapshot(state: "serving", servesHere: true)
        XCTAssertFalse(MenuModel(snapshot: snapshot, failure: nil, now: Date()).showStart)
    }

    func testShowStartIsFalseWhenNotServedHere() {
        let snapshot = makeSnapshot(state: "stopped", servesHere: false)
        XCTAssertFalse(MenuModel(snapshot: snapshot, failure: nil, now: Date()).showStart)
    }

    func testShowStartIsTrueWhenStoppedAndServedHere() {
        let snapshot = makeSnapshot(state: "stopped", servesHere: true)
        XCTAssertTrue(MenuModel(snapshot: snapshot, failure: nil, now: Date()).showStart)
    }

    func testShowSetUpIsTrueWheneverNotServing() {
        for state in ["stopped", "not_setup"] {
            let snapshot = makeSnapshot(state: state)
            XCTAssertTrue(MenuModel(snapshot: snapshot, failure: nil, now: Date()).showSetUp, "state=\(state)")
        }
    }

    func testShowSetUpIsFalseWhenServing() {
        let snapshot = makeSnapshot(state: "serving")
        XCTAssertFalse(MenuModel(snapshot: snapshot, failure: nil, now: Date()).showSetUp)
    }

    func testShowStopIsTrueOnlyWhenServing() {
        XCTAssertTrue(MenuModel(snapshot: makeSnapshot(state: "serving"), failure: nil, now: Date()).showStop)
        XCTAssertFalse(MenuModel(snapshot: makeSnapshot(state: "stopped"), failure: nil, now: Date()).showStop)
        XCTAssertFalse(MenuModel(snapshot: nil, failure: nil, now: Date()).showStop)
    }

    func testShowCopyInstallCommandIsTrueOnlyWhenCLIIsNotFound() {
        XCTAssertTrue(MenuModel(snapshot: nil, failure: .cliNotFound, now: Date()).showCopyInstallCommand)
        XCTAssertFalse(MenuModel(snapshot: nil, failure: .oldCLI, now: Date()).showCopyInstallCommand)
        XCTAssertFalse(MenuModel(snapshot: makeSnapshot(), failure: nil, now: Date()).showCopyInstallCommand)
    }

    func testShowCopyUpgradeCommandIsTrueOnlyWhenCLIIsOld() {
        XCTAssertTrue(MenuModel(snapshot: nil, failure: .oldCLI, now: Date()).showCopyUpgradeCommand)
        XCTAssertFalse(MenuModel(snapshot: nil, failure: .cliNotFound, now: Date()).showCopyUpgradeCommand)
        XCTAssertFalse(MenuModel(snapshot: makeSnapshot(), failure: nil, now: Date()).showCopyUpgradeCommand)
    }

    // MARK: - 25-row cap

    func testRowsAreCappedAt25AndMoreHoldsTheRest() {
        let shares = (1...30).map { makeShare(id: "id\($0)", name: "file\($0).txt") }
        let snapshot = makeSnapshot(shares: shares)

        let model = MenuModel(snapshot: snapshot, failure: nil, now: Date())

        XCTAssertEqual(model.rows.count, 25)
        XCTAssertEqual(model.more, 5)
        XCTAssertEqual(model.rows.map(\.id), shares.prefix(25).map(\.id), "cap keeps the given order")
    }

    func testMoreIsZeroWhenAtOrUnderTheCap() {
        let shares = (1...25).map { makeShare(id: "id\($0)") }
        let snapshot = makeSnapshot(shares: shares)

        let model = MenuModel(snapshot: snapshot, failure: nil, now: Date())

        XCTAssertEqual(model.rows.count, 25)
        XCTAssertEqual(model.more, 0)
    }

    // MARK: - helpers

    private func rowFor(_ share: Share, now: Date = Date()) -> Row {
        let snapshot = makeSnapshot(shares: [share])
        let model = MenuModel(snapshot: snapshot, failure: nil, now: now)
        return model.rows[0]
    }
}
