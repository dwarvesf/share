import XCTest
@testable import ShareBarCore

/// The screenshot scenarios drive the popover through the fake CLI. These rows pin what each
/// scenario must show, so a screen named by an acceptance criterion never drifts from its words.
final class ScenarioFixtureTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")!

    private func scenarioURL(_ path: String, _ file: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/\(path)/\(file)")
    }

    /// The roster stays empty: the popover never reads `member ls` (DEC-54), so these scenarios hold
    /// only the lines `state` itself produces.
    private func load(_ path: String) throws -> (ProfilesSnapshot, [String: MemberList]) {
        let profiles = try JSONDecoder().decode(ProfilesSnapshot.self, from: Data(contentsOf: scenarioURL(path, "profiles.json")))
        let text = try String(contentsOf: scenarioURL(path, "member-ls.json"), encoding: .utf8)
        let list = try XCTUnwrap(MemberList.decode(text))
        var members: [String: MemberList] = [:]
        if path.hasPrefix("scenarios/") {
            for entry in profiles.profiles where Role(raw: entry.state?.role) == .tenantOrigin { members[entry.name] = list }
        }
        return (profiles, members)
    }

    func testFourNeedALook() throws {
        let (profiles, members) = try load("popover/scenarios/needs-four")
        let issues = IssueList(profiles: profiles, current: "console", members: members, now: now)
        XCTAssertEqual(issues.lines.map(\.title), ["Setup stopped at step 3 of 9", "This Mac stopped serving", "Your key expires soon", "Your key expired"])
        let model = PopoverViewModel(profiles: profiles, current: "console", scope: .mine, query: "", needCount: issues.count, now: now)
        XCTAssertEqual(model.footer.text, "4 need a look")
    }

    func testThreeTenantsGroupedCurrentFirst() throws {
        let (profiles, members) = try load("popover/scenarios/issues-three")
        let issues = IssueList(profiles: profiles, current: "console", members: members, now: now)
        XCTAssertEqual(issues.groups.map(\.host), ["s.console.so", "s.d.foundation", "s.han.ws"])
        XCTAssertEqual(issues.groups.map(\.isCurrent), [true, false, false])
        XCTAssertEqual(issues.groups.map { $0.lines.count }, [2, 1, 2])
    }

    func testCalmHasNothingToLookAt() throws {
        let (profiles, members) = try load("scenarios/calm")
        let issues = IssueList(profiles: profiles, current: "default", members: members, now: now)
        XCTAssertEqual(issues.count, 0)
        XCTAssertEqual(PopoverViewModel(profiles: profiles, current: "default", scope: .mine, query: "", now: now).footer, .allAnswer)
    }

    func testAdminScenarioShowsTeamAndTheOthersLinks() throws {
        let (profiles, members) = try load("scenarios/admin")
        let mine = PopoverViewModel(profiles: profiles, current: "console", scope: .mine, query: "", needCount: 0, now: now)
        XCTAssertEqual(mine.rows.map(\.title), ["notes.txt", "design-review.key"])
        XCTAssertNotNil(mine.scope)
        let team = PopoverViewModel(profiles: profiles, current: "console", scope: .team, query: "", now: now)
        XCTAssertEqual(team.rows.count, 5, "expired never shows; revoked and the others do")
        XCTAssertEqual(mine.header.tenants.count, 3)
        XCTAssertGreaterThan(IssueList(profiles: profiles, current: "console", members: members, now: now).count, 0)
    }

    func testMemberScenarioKnowsItsOwnRows() throws {
        let (profiles, _) = try load("scenarios/member")
        let model = PopoverViewModel(profiles: profiles, current: "console", scope: .mine, query: "", now: now)
        XCTAssertNil(model.scope, "every live link is the member's own")
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertTrue(model.rows.allSatisfy(\.own))
    }

    func testFirstRunScenarioHasNoTenant() throws {
        let (profiles, _) = try load("scenarios/firstrun")
        XCTAssertTrue(PopoverViewModel(profiles: profiles, current: nil, scope: .mine, query: "").header.tenants.isEmpty)
    }
}
