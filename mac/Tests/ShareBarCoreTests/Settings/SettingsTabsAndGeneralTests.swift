import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b14: the tab set and General's writes.
final class SettingsTabsAndGeneralTests: XCTestCase {
    private func profile(_ name: String, role: String, tier: String?, r2: Bool? = nil) -> ProfileEntry {
        makeEntry(name: name, state: makeSnapshot(host: "s.\(name).test", r2: r2, role: role, tier: tier,
                                                  serve: ServeInfo(phase: "serving", reason: "ok")))
    }

    func testMembersTabHiddenForANonAdmin() {
        let cases: [(String, [ProfileEntry], Bool)] = [
            ("no profiles", [], false),
            ("a member of a T2 tenant", [profile("a", role: "member", tier: "t2")], false),
            ("an owner at T0", [profile("a", role: "origin", tier: "t0")], false),
            ("an owner at T1", [profile("a", role: "tenant_origin", tier: "t1")], false),
            ("an admin of a T2 tenant", [profile("a", role: "tenant_origin", tier: "t2")], true),
            ("a member and an admin", [profile("a", role: "member", tier: "t2"), profile("b", role: "tenant_origin", tier: "t2")], true),
        ]
        for (name, entries, shows) in cases {
            let tabs = SettingsTabs.visible(profiles: makeProfiles(entries))
            XCTAssertEqual(tabs.contains(.members), shows, name)
            XCTAssertEqual(tabs.filter { $0 != .members }, [.general, .tenants, .advanced], name)
        }
        XCTAssertEqual(SettingsTabs.visible(profiles: nil), [.general, .tenants, .advanced], "before the first read")
    }

    func testArrowsMoveTabsAndWrap() {
        let tabs: [SettingsPane] = [.general, .tenants, .advanced]
        XCTAssertEqual(SettingsTabs.moved(from: .general, forward: true, in: tabs), .tenants)
        XCTAssertEqual(SettingsTabs.moved(from: .advanced, forward: true, in: tabs), .general)
        XCTAssertEqual(SettingsTabs.moved(from: .general, forward: false, in: tabs), .advanced)
    }

    func testGeneralsExpiryWritesArgvShareConfigTtl7d() {
        XCTAssertEqual(ConfigWrites.ttl(profile: "console", .sevenDays), ["--profile", "console", "config", "ttl", "7d"])
        XCTAssertEqual(ConfigWrites.ttl(profile: "console", .never).suffix(3), ["config", "ttl", "never"])
        for choice in ExpiryChoice.allCases { XCTAssertEqual(ExpiryChoice(configValue: choice.rawValue + "\n"), choice) }
        XCTAssertNil(ExpiryChoice(configValue: "12h"), "a value the picker has no row for is not a choice")
        XCTAssertEqual(ConfigWrites.storageDefault(profile: "console", .cloud).suffix(3), ["config", "storage_default", "cloud"])
    }

    func testStoreNewLinksOnlyOnTenantsWithCloudStorage() {
        XCTAssertFalse(ConfigWrites.offersStorage(profile("a", role: "origin", tier: "t0")))
        XCTAssertTrue(ConfigWrites.offersStorage(profile("a", role: "tenant_origin", tier: "t1", r2: true)))
        XCTAssertTrue(ConfigWrites.offersStorage(profile("a", role: "tenant_origin", tier: "t2")))
    }

    func testGeneralWritesTargetTheCurrentTenantThenTheFirstUsable() {
        let entries = [profile("m", role: "member", tier: "t2"), profile("a", role: "origin", tier: "t0"), profile("b", role: "tenant_origin", tier: "t1")]
        let profiles = makeProfiles(entries)
        XCTAssertEqual(ConfigWrites.target(profiles: profiles, current: "b")?.name, "b")
        XCTAssertEqual(ConfigWrites.target(profiles: profiles, current: "m")?.name, "a", "a member has no CLI defaults to set")
        XCTAssertNil(ConfigWrites.target(profiles: makeProfiles([entries[0]]), current: nil))
    }

    func testPreferencesRoundTripAndMenuShowsSetsEveryTenantScope() throws {
        let suite = "sharebar.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = GeneralPrefs(defaults: defaults)
        XCTAssertTrue(prefs.copyAfterSharing)
        XCTAssertFalse(prefs.notifyExpiry)
        prefs.setMenuShows(.team, profiles: ["a", "b"])
        XCTAssertEqual(prefs.menuShows, .team)
        let popover = PopoverPrefs(defaults: defaults)
        XCTAssertEqual(popover.scope(for: "a"), .team)
        XCTAssertEqual(popover.scope(for: "b"), .team)
        prefs.recentCount = 12
        XCTAssertEqual(popover.recentCount, 12, "General's count is the popover's own key")
        prefs.notifyMember = false
        XCTAssertFalse(prefs.notifyMember)
    }
}
