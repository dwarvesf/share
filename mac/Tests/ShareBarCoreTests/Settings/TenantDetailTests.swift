import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b17: the Tenants detail, its buttons per role, tier and phase, and removal.
final class TenantDetailTests: XCTestCase {
    private func entry(
        role: String, tier: String?, phase: String?, reason: String? = nil, servesHere: Bool = true,
        ops: [OpInfo]? = nil, token: TokenInfo? = nil, member: MemberInfo? = nil, host: String = "s.test.example", shares: [Share] = []
    ) -> ProfileEntry {
        let serving = phase == "serving" || phase == "starting" || phase == "tunnel_down"
        return makeEntry(name: "test", state: makeSnapshot(
            state: serving ? "serving" : "stopped", ready: phase == "serving", host: host, servesHere: servesHere,
            shares: shares, r2: tier == "t1" || tier == "t2" ? true : nil, role: role, tier: tier,
            serve: phase.map { ServeInfo(phase: $0, reason: reason) }, ops: ops, token: token, member: member
        ))
    }

    private func detail(_ e: ProfileEntry) throws -> TenantDetail { try XCTUnwrap(TenantDetail(entry: e)) }

    func testButtonsPerRoleTierAndPhase() throws {
        struct Case {
            let name: String
            let entry: ProfileEntry
            let actions: [TenantAction]
        }
        let dead = OpInfo(verb: "setup-r2", step: 13, of: 16, name: "route", alive: false,
                          rerun: "share setup s.test.example --r2 --bucket share-s-test-example",
                          rerunArgv: ["--profile", "test", "setup", "s.test.example", "--r2", "--bucket", "share-s-test-example"],
                          rollback: "share setup s.test.example --no-r2",
                          rollbackArgv: ["--profile", "test", "setup", "s.test.example", "--no-r2"])
        let cases = [
            Case(name: "owner T0 serving", entry: entry(role: "origin", tier: "t0", phase: "serving"),
                 actions: [.stop, .turnOnCloud, .openInBrowser]),
            Case(name: "owner T0 stopped", entry: entry(role: "origin", tier: "t0", phase: "stopped"),
                 actions: [.start, .turnOnCloud, .openInBrowser]),
            Case(name: "owner T0 failed", entry: entry(role: "origin", tier: "t0", phase: "failed", reason: "port_busy"),
                 actions: [.start, .turnOnCloud, .openInBrowser]),
            Case(name: "owner T0 starting", entry: entry(role: "origin", tier: "t0", phase: "starting"),
                 actions: [.stop, .turnOnCloud, .openInBrowser]),
            Case(name: "owner T0 tunnel down", entry: entry(role: "origin", tier: "t0", phase: "tunnel_down"),
                 actions: [.stop, .turnOnCloud, .openInBrowser]),
            Case(name: "tenant owner T1 serving", entry: entry(role: "tenant_origin", tier: "t1", phase: "serving"),
                 actions: [.stop, .turnOnMembers, .openInBrowser]),
            Case(name: "admin T2 serving", entry: entry(role: "tenant_origin", tier: "t2", phase: "serving"),
                 actions: [.stop, .openInBrowser]),
            Case(name: "member serving", entry: entry(role: "member", tier: "t2", phase: "serving"),
                 actions: [.stop, .openInBrowser]),
            Case(name: "member serving with a key about to expire",
                 entry: entry(role: "member", tier: "t2", phase: "serving", token: TokenInfo(source: "keychain", status: "expiring", expiresOn: "2026-12-01")),
                 actions: [.stop, .copyRequest, .openInBrowser]),
            Case(name: "member stopped", entry: entry(role: "member", tier: "t2", phase: "stopped"),
                 actions: [.start, .openInBrowser]),
            Case(name: "cloud-mode member has no serve buttons",
                 entry: entry(role: "member", tier: "t2", phase: "stopped", member: MemberInfo(id: "m-an-1a2b3c4d", mode: "cloud", status: "active")),
                 actions: [.openInBrowser]),
            Case(name: "owner T1 with a stopped cloud setup",
                 entry: entry(role: "tenant_origin", tier: "t1", phase: "stopped", ops: [dead]),
                 actions: [.resume, .rollBack, .start, .openInBrowser]),
            Case(name: "elsewhere shows no serve buttons", entry: entry(role: "origin", tier: "t0", phase: "elsewhere", servesHere: false),
                 actions: [.turnOnCloud, .openInBrowser]),
        ]
        for c in cases {
            XCTAssertEqual(try detail(c.entry).actions, c.actions, c.name)
        }
    }

    func testTheTierButtonsAreAdminOnly() throws {
        for role in ["member"] {
            for tier in ["t0", "t1", "t2"] {
                let actions = try detail(entry(role: role, tier: tier, phase: "serving")).actions
                XCTAssertFalse(actions.contains(.turnOnCloud), "\(role) \(tier)")
                XCTAssertFalse(actions.contains(.turnOnMembers), "\(role) \(tier)")
            }
        }
        // T1 to T2 is the admin's: an `origin` (no bucket) never offers it.
        XCTAssertFalse(try detail(entry(role: "origin", tier: "t1", phase: "serving")).actions.contains(.turnOnMembers))
        XCTAssertTrue(try detail(entry(role: "tenant_origin", tier: "t1", phase: "serving")).actions.contains(.turnOnMembers))
        XCTAssertFalse(try detail(entry(role: "tenant_origin", tier: "t2", phase: "serving")).actions.contains(.turnOnMembers))
    }

    func testRemovedMemberShowsCleanUp() throws {
        let d = try detail(entry(role: "member", tier: "t2", phase: "stopped",
                                 member: MemberInfo(id: "m-han-1a2b3c4d", name: "han", mode: "machine", status: "removed")))
        XCTAssertEqual(d.banner, .removed(host: "s.test.example"))
        XCTAssertEqual(d.banner?.text, "You were removed from s.test.example")
        XCTAssertTrue(d.actions.contains(.cleanUp))
        XCTAssertEqual(d.removal, .cleanUp)
        XCTAssertEqual(d.removal?.argv(profile: "test"), ["--profile", "test", "leave", "--local"])
        XCTAssertFalse(d.actions.contains(.start), "a removed member cannot start serving")
    }

    func testExpiredOrInvalidKeyNeverShowsCleanUp() throws {
        for (status, banner, text) in [
            ("expired", TenantBanner.keyExpired, "Your key expired; ask the admin to renew it"),
            ("invalid", TenantBanner.keyInvalid, "Your key stopped working; ask the admin"),
        ] {
            let d = try detail(entry(role: "member", tier: "t2", phase: "serving",
                                     token: TokenInfo(source: "keychain", status: status),
                                     member: MemberInfo(id: "m-han-1a2b3c4d", name: "han", mode: "machine", status: "active")))
            XCTAssertEqual(d.banner, banner, status)
            XCTAssertEqual(d.banner?.text, text, status)
            XCTAssertTrue(d.actions.contains(.copyRequest), status)
            XCTAssertFalse(d.actions.contains(.cleanUp), status)
            XCTAssertEqual(d.removal, .leave, "\(status): leaving stays an explicit action behind the impact sheet")
            XCTAssertEqual(d.removal?.argv(profile: "test"), ["--profile", "test", "leave"])
        }
    }

    func testRemovalPerRole() throws {
        XCTAssertEqual(try detail(entry(role: "origin", tier: "t0", phase: "serving")).removal, .teardown(cloudLinksKeepAnswering: false))
        XCTAssertEqual(try detail(entry(role: "tenant_origin", tier: "t1", phase: "serving")).removal, .teardown(cloudLinksKeepAnswering: true))
        XCTAssertEqual(try detail(entry(role: "tenant_origin", tier: "t1", phase: "serving")).removal?.argv(profile: "x"), ["--profile", "x", "teardown", "--yes"])
        XCTAssertEqual(try detail(entry(role: "tenant_origin", tier: "t2", phase: "serving")).removal, .refusedMembers)
        XCTAssertNil(try detail(entry(role: "tenant_origin", tier: "t2", phase: "serving")).removal?.argv(profile: "x"), "refused: nothing runs")
        XCTAssertEqual(try detail(entry(role: "member", tier: "t2", phase: "serving")).removal, .leave)
    }

    func testMembersPresentMapsToTheRefusalSheet() {
        let sheet = RefusalSheet.from(code: "members_present", message: "s.test.example has 3 members", next: "share member ls", host: "s.test.example")
        XCTAssertEqual(sheet.title, "Can't remove s.test.example yet")
        XCTAssertEqual(sheet.sentence, "s.test.example has members. Remove every member first; then this Mac can remove the tenant.")
        XCTAssertEqual(sheet.next, "Open Members")
        XCTAssertEqual(sheet.action, .openMembers)
        XCTAssertEqual(sheet, Impact.refusedMembers(host: "s.test.example"), "the same sheet as the check before anything runs")
        let other = RefusalSheet.from(code: "port_busy", message: "Port 8787 is in use", next: "share --profile x start", host: "h")
        XCTAssertEqual(other.sentence, "Port 8787 is in use")
        XCTAssertEqual(other.action, .copyCommand("share --profile x start"))
        XCTAssertEqual(RefusalSheet.from(code: "x", message: "m", next: nil, host: "h").action, RefusalSheet.Action.none)
    }

    func testStatusWordsToneAndListLine() throws {
        let serving = try detail(entry(role: "origin", tier: "t0", phase: "serving"))
        XCTAssertEqual(serving.status, TenantStatus(word: "Serving", tone: .ok))
        XCTAssertEqual(serving.listLine, "Owner · Serving")
        XCTAssertFalse(serving.needsLook)
        let starting = try detail(entry(role: "origin", tier: "t0", phase: "starting"))
        XCTAssertEqual(starting.status.tone, .spinner)
        let failed = try detail(entry(role: "origin", tier: "t0", phase: "failed", reason: "port_busy"))
        XCTAssertEqual(failed.status.word, "Stopped: port busy")
        XCTAssertEqual(failed.status.tone, .attention)
        XCTAssertEqual(failed.listLine, "Owner · Stopped")
        XCTAssertTrue(failed.needsLook)
        let down = try detail(entry(role: "origin", tier: "t0", phase: "tunnel_down"))
        XCTAssertEqual(down.status.word, "Tunnel not connected")
        XCTAssertEqual(try detail(entry(role: "tenant_origin", tier: "t2", phase: "serving")).listLine, "Admin · Serving")
        XCTAssertEqual(try detail(entry(role: "member", tier: "t2", phase: "serving")).listLine, "Member · Serving")
    }

    func testInterruptedCalloutAndItsButtonsFollowTheJournalCheck() throws {
        let rerun = ["--profile", "test", "join"]
        let join = OpInfo(verb: "join", step: 4, of: 6, name: "service", alive: false, rerun: "share join", rerunArgv: rerun,
                          rollback: "share leave --local", rollbackArgv: ["--profile", "test", "leave", "--local"])
        let d = try detail(entry(role: "member", tier: "t2", phase: "stopped", ops: [join]))
        XCTAssertEqual(d.callout?.title, "Joining stopped at step 4 of 6")
        XCTAssertEqual(d.callout?.canResume, true)
        XCTAssertEqual(d.callout?.canRollBack, true)
        XCTAssertEqual(d.listLine, "Member · Interrupted")
        XCTAssertTrue(d.needsLook)
        // Resume runs the journal's rerun; Roll back its rollback (bare `share join`, then `leave --local`).
        XCTAssertEqual(JournalRun.argv(op: join, kind: .rerun, profile: "test"), ["--profile", "test", "join"])
        XCTAssertEqual(JournalRun.argv(op: join, kind: .rollback, profile: "test"), ["--profile", "test", "leave", "--local"])

        // A journal whose argv fails the shape check offers neither button.
        let forged = OpInfo(verb: "join", step: 2, of: 6, name: "keys", alive: false, rerun: "x", rerunArgv: ["join", "evil; true"],
                            rollback: "y", rollbackArgv: ["rm", "-rf", "x"])
        let f = try detail(entry(role: "member", tier: "t2", phase: "stopped", ops: [forged]))
        XCTAssertEqual(f.callout?.canResume, false)
        XCTAssertEqual(f.callout?.canRollBack, false)
        XCTAssertFalse(f.actions.contains(.resume))
        XCTAssertFalse(f.actions.contains(.rollBack))

        // A teardown or member journal is finished in a terminal or on its own tab: no Resume button here.
        let teardown = OpInfo(verb: "teardown-purge", step: 3, of: 7, name: "marker", alive: false, rerun: "share teardown --yes --purge",
                              rerunArgv: ["--profile", "test", "teardown", "--yes", "--purge"])
        let t = try detail(entry(role: "origin", tier: "t0", phase: "serving", ops: [teardown]))
        XCTAssertEqual(t.callout?.canResume, false)
        XCTAssertFalse(t.actions.contains(.resume))

        // A live op is another process's work: no callout.
        let live = OpInfo(verb: "setup-r2", step: 3, of: 16, name: "bucket", alive: true)
        XCTAssertNil(try detail(entry(role: "tenant_origin", tier: "t1", phase: "serving", ops: [live])).callout)
    }

    func testRowsOfTheDetail() throws {
        let owner = try detail(entry(role: "origin", tier: "t0", phase: "serving"))
        XCTAssertEqual(owner.storage, "This Mac only")
        XCTAssertEqual(owner.members, "Off")
        XCTAssertEqual(owner.servedFrom, "hans-air-m4 (this Mac)")
        XCTAssertEqual(owner.key, "Admin key: Asks each time")
        let admin = try detail(entry(role: "tenant_origin", tier: "t2", phase: "serving"))
        XCTAssertEqual(admin.storage, "This Mac and the cloud")
        XCTAssertEqual(admin.members, "On")
        let member = try detail(entry(role: "member", tier: "t2", phase: "serving",
                                      token: TokenInfo(source: "keychain", status: "ok", expiresOn: "2027-02-12")))
        XCTAssertNil(member.members, "a member never sees the Members row")
        XCTAssertEqual(member.key, "Keychain, expires 2027-02-12")
        let elsewhere = try detail(entry(role: "origin", tier: "t0", phase: "elsewhere", servesHere: false))
        XCTAssertEqual(elsewhere.servedFrom, "Another Mac: hans-air-m4")
        XCTAssertNil(TenantDetail(entry: makeEntry(name: "x", state: makeSnapshot(role: "none"))))
        XCTAssertNil(TenantDetail(entry: makeEntry(name: "x", error: "boom")))
    }

    func testRemoveSheetsPerRoleCountLinksFromRows() throws {
        let rows = [makeShare(id: "a", storage: "machine"), makeShare(id: "b", storage: "machine"), makeShare(id: "c", storage: "cloud")]
        let t0 = try detail(entry(role: "origin", tier: "t0", phase: "serving"))
        XCTAssertEqual(Impact.removeTenant(t0, shares: rows)?.body, "Deletes the tunnel, the DNS record and this Mac's 2 links. Visitors get a Cloudflare error.")
        let t1 = try detail(entry(role: "tenant_origin", tier: "t1", phase: "serving"))
        XCTAssertEqual(Impact.removeTenant(t1, shares: rows)?.body?.hasSuffix("until they expire."), true)
        let member = try detail(entry(role: "member", tier: "t2", phase: "serving"))
        XCTAssertEqual(Impact.removeTenant(member, shares: rows)?.actionTitle, "Leave")
        XCTAssertEqual(Impact.removeTenant(member, shares: rows)?.destructive, true)
        let admin = try detail(entry(role: "tenant_origin", tier: "t2", phase: "serving"))
        XCTAssertNil(Impact.removeTenant(admin, shares: rows), "refused: the refusal sheet opens instead")
    }
}
