import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b6 and TASK-4b7: the popover's view model.
final class PopoverViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let far = 4_102_444_800

    private func full() throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: loadFixtureData("state-full"))
    }

    private func fullProfiles() throws -> ProfilesSnapshot {
        makeProfiles([("console", try full())])
    }

    private func model(
        _ profiles: ProfilesSnapshot?, scope: LinkScope = .mine, query: String = "", count: Int = 8, need: Int = 0
    ) -> PopoverViewModel {
        PopoverViewModel(profiles: profiles, current: "console", scope: scope, query: query, recentCount: count, needCount: need, now: now)
    }

    private func own(_ id: String, _ name: String = "x.txt", linkState: String? = nil, expires: Int? = nil, by: String = "Mac-mini") -> Share {
        makeShare(id: id, name: name, url: "https://s.test/\(id)/\(name)", expires: expires ?? far, storage: "machine", by: by, linkState: linkState)
    }

    private func other(_ id: String, _ name: String = "y.txt", member: String = "an", linkState: String? = nil) -> Share {
        makeShare(id: id, name: name, url: "https://s.test/\(id)/\(name)", expires: far, storage: "machine", by: "\(member.capitalized)'s MacBook",
                  origin: "m-\(member)-\(member == "an" ? "1a2b3c4d" : "5e6f7a8b")", linkState: linkState)
    }

    private func profiles(_ shares: [Share], role: String = "tenant_origin", member: MemberInfo? = nil) -> ProfilesSnapshot {
        makeProfiles([("console", makeSnapshot(host: "s.example.com", shares: shares, role: role, tier: "t2", member: member))])
    }

    func testTheViewModelListsHeaderSearchScopeListShowAllFooterInOrder() throws {
        let vm = model(try fullProfiles())
        XCTAssertEqual(vm.regions, [.header, .search, .scope, .list, .showAll, .footer])
        XCTAssertEqual(vm.header.title, "s.example.com")
        XCTAssertEqual(vm.header.manageTitle, "Manage tenants…")
        XCTAssertEqual(vm.search.placeholder, "Search links")
        XCTAssertNotNil(vm.scope)
        XCTAssertEqual(vm.rows.map(\.id), ["c4c2a0", "b99924", "9d10aa"])
        XCTAssertEqual(vm.showAllTitle, "Show all 7 links…")
        XCTAssertEqual(vm.footer, .allAnswer)
        XCTAssertEqual(vm.footer.text, "All links answer")
    }

    func testTheFooterNamesTheCountAndTheStatusItemLabelCarriesIt() throws {
        let vm = model(try fullProfiles(), need: 4)
        XCTAssertEqual(vm.footer, .needLook(4))
        XCTAssertEqual(vm.footer.text, "4 need a look")
        XCTAssertEqual(vm.statusItemLabel, "Handout Bar, 4 need a look")
        XCTAssertEqual(model(try fullProfiles()).statusItemLabel, "Handout Bar")
    }

    func testMineHidesOthers() {
        let vm = model(profiles([own("a1"), other("b1")]))
        XCTAssertEqual(vm.rows.map(\.id), ["a1"])
    }

    func testTeamAddsTheOwner() {
        let vm = model(profiles([own("a1"), other("b1")]), scope: .team)
        XCTAssertEqual(vm.rows.map(\.id), ["a1", "b1"])
        XCTAssertTrue(vm.rows[0].meta.hasPrefix("You · "), vm.rows[0].meta)
        XCTAssertTrue(vm.rows[1].meta.hasPrefix("An · "), vm.rows[1].meta)
        XCTAssertFalse(model(profiles([own("a1"), other("b1")])).rows[0].meta.contains("You"))
    }

    func testScopeIsRememberedPerTenant() throws {
        let suite = "popover-prefs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = PopoverPrefs(defaults: defaults)
        XCTAssertEqual(prefs.scope(for: "console"), .mine)
        prefs.setScope(.team, for: "console")
        XCTAssertEqual(prefs.scope(for: "console"), .team)
        XCTAssertEqual(prefs.scope(for: "han"), .mine)
        XCTAssertEqual(PopoverPrefs(defaults: defaults).scope(for: "console"), .team, "a new reader sees the stored choice")
    }

    func testScopeIsHiddenWhenEveryLinkIsOwn() {
        let vm = model(profiles([own("a1"), own("a2")]), scope: .team)
        XCTAssertNil(vm.scope)
        XCTAssertEqual(vm.regions, [.header, .search, .list, .showAll, .footer])
        XCTAssertEqual(vm.rows.count, 2, "a hidden control never filters")
    }

    func testAnExpiredOthersLinkDoesNotShowTheControl() {
        let vm = model(profiles([own("a1"), other("b1", linkState: "expired")]))
        XCTAssertNil(vm.scope)
    }

    func testSearchMatchesNameAndOwner() {
        let shares = [own("a1", "notes.txt"), other("b1", "plan.pdf", member: "an"), other("c1", "deck.key", member: "binh")]
        XCTAssertEqual(model(profiles(shares), scope: .team, query: "note").rows.map(\.id), ["a1"])
        XCTAssertEqual(model(profiles(shares), scope: .team, query: "AN").rows.map(\.id), ["b1"], "the owner matches, case ignored")
        XCTAssertEqual(model(profiles(shares), scope: .team, query: "binh").rows.map(\.id), ["c1"])
        XCTAssertEqual(model(profiles(shares), scope: .mine, query: "plan").rows.map(\.id), [], "Mine still hides others")
    }

    func testNoMatchSaysSoAndAnEmptyTenantHasItsOwnSentence() {
        let none = model(profiles([own("a1")]), query: "zz")
        XCTAssertEqual(none.emptyText, "No links match \"zz\".")
        XCTAssertTrue(none.rows.isEmpty)
        let empty = model(profiles([]))
        XCTAssertEqual(empty.emptyText, "No links yet. Drop a file on the menu bar icon to share it.")
        XCTAssertNil(empty.showAllTitle)
        XCTAssertEqual(empty.regions, [.header, .search, .list, .footer])
    }

    func testCapFollowsGeneral() {
        let shares = (1...14).map { own("a\($0)", "f\($0).txt") }
        XCTAssertEqual(model(profiles(shares)).rows.count, 8, "the default")
        XCTAssertEqual(model(profiles(shares), count: 5).rows.count, 5)
        XCTAssertEqual(model(profiles(shares), count: 12).rows.count, 12)
        XCTAssertEqual(model(profiles(shares), count: 5).rows.map(\.id), ["a1", "a2", "a3", "a4", "a5"], "the CLI's order is kept, newest first")
        XCTAssertEqual(model(profiles(shares)).showAllTitle, "Show all 14 links…")
    }

    func testRecentCountReadsOnlyTheThreeChoices() throws {
        let suite = "popover-count-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = PopoverPrefs(defaults: defaults)
        XCTAssertEqual(prefs.recentCount, 8)
        prefs.recentCount = 12
        XCTAssertEqual(prefs.recentCount, 12)
        defaults.set(7, forKey: PopoverPrefs.recentKey)
        XCTAssertEqual(prefs.recentCount, 8, "an unknown count reads as the default")
    }

    func testExpiredNeverInTheMenu() {
        let past = Int(now.timeIntervalSince1970) - 10
        let shares = [own("a1", linkState: "expired"), own("a2", expires: past), own("a3")]
        let vm = model(profiles(shares))
        XCTAssertEqual(vm.rows.map(\.id), ["a3"], "an expired link by state or by the clock never shows")
        XCTAssertEqual(vm.showAllTitle, "Show all 3 links…", "the count is every link")
    }

    func testAMembersOwnRowsAreTheOnesWithItsMemberId() {
        let me = MemberInfo(id: "m-an-1a2b3c4d", name: "an", mode: "machine", status: "active")
        let shares = [other("b1", member: "an"), other("c1", member: "binh")]
        let vm = model(profiles(shares, role: "member", member: me), scope: .team)
        XCTAssertEqual(vm.rows.map(\.own), [true, false])
        XCTAssertTrue(vm.rows[0].meta.hasPrefix("You · "))
    }

    func testTheTenantMenuCarriesRoleAndCheck() {
        let admin = makeSnapshot(host: "s.example.com", role: "tenant_origin")
        let owner = makeSnapshot(host: "s.home.example.com", role: "origin")
        let unset = makeSnapshot(host: nil, role: "none")
        let vm = PopoverViewModel(profiles: makeProfiles([("console", admin), ("han", owner), ("default", unset)]), current: "han", scope: .mine, query: "")
        XCTAssertEqual(vm.header.tenants.map(\.host), ["s.example.com", "s.home.example.com"], "a profile with no role is not a tenant")
        XCTAssertEqual(vm.header.tenants.map(\.roleLabel), ["Admin", "Owner"])
        XCTAssertEqual(vm.header.tenants.map(\.isCurrent), [false, true])
        XCTAssertTrue(vm.header.hasChevron)
        XCTAssertEqual(vm.header.title, "s.home.example.com")
    }

    func testOneTenantHasNoChevron() {
        let vm = model(profiles([]))
        XCTAssertFalse(vm.header.hasChevron)
    }

    func testLegacyMenuBuildsTodaysMenuModel() throws {
        let profiles = try fullProfiles()
        let legacy = LegacyMenu.model(profiles: profiles, failure: nil, now: now)
        let today = MenuModel(profiles: profiles, failure: nil, now: now, working: nil)
        XCTAssertEqual(legacy.header, today.header)
        XCTAssertEqual(legacy.sections, today.sections)
        XCTAssertEqual(legacy.icon, today.icon)
        XCTAssertEqual(legacy.canPublish, today.canPublish)
        let suite = "popover-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(LegacyMenu.isOn(defaults), "off by default: the popover is the shell")
        defaults.set(true, forKey: LegacyMenu.key)
        XCTAssertTrue(LegacyMenu.isOn(defaults))
        XCTAssertEqual(LegacyMenu.key, "LegacyMenu")
    }
}

extension PopoverViewModelTests {
    func testAnotherMembersMachineReadsWithACapitalisedName() {
        let vm = PopoverViewModel(profiles: profilesFor([other("b1", member: "an")]), current: "console", scope: .team, query: "", now: now)
        XCTAssertTrue(vm.rows[0].meta.hasPrefix("An · An's machine"), vm.rows[0].meta)
    }

    func testAMembersOwnLinkOnItsOwnMacReadsThisMac() {
        let me = MemberInfo(id: "m-an-1a2b3c4d", name: "an", mode: "machine", status: "active")
        let vm = PopoverViewModel(profiles: profilesFor([other("b1", member: "an")], role: "member", member: me), current: "console", scope: .mine, query: "", now: now)
        XCTAssertTrue(vm.rows[0].meta.contains("this Mac"), vm.rows[0].meta)
        XCTAssertFalse(vm.rows[0].meta.contains("machine"))
    }

    fileprivate func profilesFor(_ shares: [Share], role: String = "tenant_origin", member: MemberInfo? = nil) -> ProfilesSnapshot {
        makeProfiles([("console", makeSnapshot(host: "s.example.com", shares: shares, role: role, tier: "t2", member: member))])
    }
}
