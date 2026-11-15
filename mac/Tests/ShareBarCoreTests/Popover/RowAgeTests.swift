import XCTest
@testable import ShareBarCore

/// Popover design parity: the trailing age of a link row (`1d`, `8d`), SPEC-009 `### Components & states`
/// ("Link row: ... relative age"). The CLI reports the day a link was added; the age is built from it.
final class RowAgeTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func now(_ day: String) -> Date {
        let p = day.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 15))!
    }

    func testAgeReadsInTheLargestWholeUnit() {
        let today = now("2026-11-15")
        XCTAssertEqual(RowAge.text(added: "2026-11-15", now: today, calendar: calendar), "today")
        XCTAssertEqual(RowAge.text(added: "2026-11-14", now: today, calendar: calendar), "1d")
        XCTAssertEqual(RowAge.text(added: "2026-11-07", now: today, calendar: calendar), "8d")
        XCTAssertEqual(RowAge.text(added: "2026-10-25", now: today, calendar: calendar), "3w")
        XCTAssertEqual(RowAge.text(added: "2026-06-15", now: today, calendar: calendar), "5mo")
        XCTAssertEqual(RowAge.text(added: "2023-11-15", now: today, calendar: calendar), "3y")
    }

    func testNoAddedDayOrAMalformedOneShowsNoAge() {
        let today = now("2026-11-15")
        XCTAssertNil(RowAge.text(added: nil, now: today, calendar: calendar))
        XCTAssertNil(RowAge.text(added: "yesterday", now: today, calendar: calendar))
        XCTAssertNil(RowAge.text(added: "2026-1-5", now: today, calendar: calendar))
    }

    func testAFutureDayReadsAsToday() {
        XCTAssertEqual(RowAge.text(added: "2026-11-20", now: now("2026-11-15"), calendar: calendar), "today")
    }

    func testTheRowCarriesTheAgeOfItsShare() throws {
        let json = #"{"id":"a1","name":"n.html","url":"https://s.test/a1/n.html","kind":"snapshot","own_host":null,"expires":0,"storage":"machine","by":"Mac","added":"2026-11-14"}"#
        let share = try JSONDecoder().decode(Share.self, from: Data(json.utf8))
        XCTAssertEqual(share.added, "2026-11-14")
        let bad = #"{"id":"a2","name":"n.html","url":"https://s.test/a2/n.html","kind":"snapshot","own_host":null,"expires":0,"added":7}"#
        XCTAssertNil(try JSONDecoder().decode(Share.self, from: Data(bad.utf8)).added)
        let profiles = makeProfiles([("p", makeSnapshot(host: "s.test", shares: [share]))])
        let model = PopoverViewModel(profiles: profiles, current: "p", scope: .mine, query: "", recentCount: 8, needCount: 0, now: Date())
        XCTAssertNotNil(model.rows.first?.age)
    }
}
