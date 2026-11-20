import XCTest
@testable import ShareBarCore

/// SPEC-010 SB-01 to SB-05 and SPEC-009 TASK-4b2: the serve sentence, publish
/// eligibility and the link meta line, derived from the new keys when present and from
/// today's rules when not.
final class DerivationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ snapshot: Snapshot) -> ProfileEntry { makeEntry(name: "p", state: snapshot) }

    // MARK: serve sentence (SB-01, SB-02, SB-03)

    /// One row per `serve.phase`: the state the CLI pairs it with, the copy it reads.
    private struct PhaseRow {
        let phase: String
        let reason: String?
        let state: String
        let ready: Bool
        let servesHere: Bool
        let health: Health
        let copy: String
        let today: String
    }

    private let phaseRows: [PhaseRow] = [
        PhaseRow(phase: "serving", reason: "ok", state: "serving", ready: true, servesHere: true, health: .ok, copy: "Serving", today: "Serving"),
        PhaseRow(phase: "starting", reason: "starting", state: "serving", ready: false, servesHere: true, health: .tunnelDown, copy: "Starting…", today: "Tunnel not connected"),
        PhaseRow(phase: "tunnel_down", reason: "tunnel_down", state: "serving", ready: false, servesHere: true, health: .tunnelDown, copy: "Tunnel not connected", today: "Tunnel not connected"),
        PhaseRow(phase: "worker_down", reason: "worker_down", state: "serving", ready: false, servesHere: false, health: .tunnelDown, copy: "Worker not answering", today: "Tunnel not connected"),
        PhaseRow(phase: "stopped", reason: "stopped", state: "stopped", ready: false, servesHere: true, health: .stopped, copy: "Stopped", today: "Stopped"),
        PhaseRow(phase: "failed", reason: "cloudflared_died", state: "stopped", ready: false, servesHere: true, health: .stopped, copy: "Stopped: the tunnel process exited", today: "Stopped"),
        PhaseRow(phase: "failed", reason: "caddy_failed", state: "stopped", ready: false, servesHere: true, health: .stopped, copy: "Stopped: the web server failed", today: "Stopped"),
        PhaseRow(phase: "elsewhere", reason: "elsewhere", state: "stopped", ready: false, servesHere: false, health: .elsewhere, copy: "Not serving on this Mac (hosts=mini-2)", today: "Not serving on this Mac (hosts=mini-2)"),
        PhaseRow(phase: "not_setup", reason: "not_setup", state: "not_setup", ready: false, servesHere: false, health: .notSetUp, copy: "Not set up", today: "Not set up"),
    ]

    private func snapshot(for row: PhaseRow, serve: ServeInfo?) -> Snapshot {
        makeSnapshot(state: row.state, ready: row.ready, hosts: "mini-2", servesHere: row.servesHere, serve: serve)
    }

    func testEveryServePhaseReadsItsCopy() {
        for row in phaseRows {
            let withKey = entry(snapshot(for: row, serve: ServeInfo(phase: row.phase, reason: row.reason)))
            XCTAssertEqual(Health.of(withKey), row.health, "\(row.phase): the classification never changes")
            XCTAssertEqual(Health.statusText(of: withKey), row.copy, "\(row.phase) \(row.reason ?? "")")
            let without = entry(snapshot(for: row, serve: nil))
            XCTAssertEqual(Health.statusText(of: without), row.today, "\(row.phase) with no serve key reads today's text")
            XCTAssertEqual(Health.of(without), row.health)
        }
    }

    func testAnUnknownServePhaseFallsBackToTodaysDerivation() {
        for row in phaseRows {
            let odd = entry(snapshot(for: row, serve: ServeInfo(phase: "warp_drive", reason: "x")))
            XCTAssertEqual(Health.statusText(of: odd), row.today)
            XCTAssertNotEqual(Health.statusText(of: odd), "Error: state not readable")
            XCTAssertEqual(Health.of(odd), row.health)
        }
    }

    func testAServePhaseThatContradictsStateReadyIsNotTrusted() {
        let lying = entry(makeSnapshot(state: "stopped", ready: false, servesHere: true, serve: ServeInfo(phase: "serving", reason: "ok")))
        XCTAssertEqual(Health.statusText(of: lying), "Stopped")
    }

    func testAnUnknownFailedReasonStillReadsAsASentence() {
        let odd = entry(makeSnapshot(state: "stopped", ready: false, serve: ServeInfo(phase: "failed", reason: "port_busy")))
        XCTAssertEqual(Health.statusText(of: odd), "Stopped: port busy")
        let blank = entry(makeSnapshot(state: "stopped", ready: false, serve: ServeInfo(phase: "failed", reason: nil)))
        XCTAssertEqual(Health.statusText(of: blank), "Stopped: it exited")
    }

    func testAMigratedRoleReadsMovedToAnotherMachineAndStaysNeutral() {
        for serve in [nil, ServeInfo(phase: "not_setup", reason: "not_setup")] {
            let moved = entry(makeSnapshot(state: "not_setup", ready: false, servesHere: false, role: "migrated", serve: serve))
            XCTAssertEqual(Health.statusText(of: moved), "Moved to another machine")
            XCTAssertEqual(Health.of(moved), .notSetUp)
            XCTAssertTrue(Health.of(moved).isNeutral)
            XCTAssertFalse(Health.of(moved).isAttention)
        }
        let section = Section(entry: entry(makeSnapshot(state: "not_setup", ready: false, servesHere: false, role: "migrated")), rowCap: 10, now: now)
        XCTAssertEqual(section.status, "Moved to another machine")
    }

    func testOldFixturesDeriveExactlyAsToday() throws {
        let profiles = try loadFixtureTenantProfiles()
        for profile in profiles.profiles {
            XCTAssertNil(profile.state?.role)
            let text = Health.statusText(of: profile)
            switch Health.of(profile) {
            case .ok: XCTAssertEqual(text, "Serving")
            case .tunnelDown: XCTAssertEqual(text, "Tunnel not connected")
            case .stopped: XCTAssertEqual(text, "Stopped")
            case .notSetUp: XCTAssertEqual(text, "Not set up")
            case .elsewhere: XCTAssertTrue(text.hasPrefix("Not serving on this Mac (hosts="))
            case .error: XCTAssertTrue(text.hasPrefix("Error: "))
            }
        }
    }

    // MARK: ProfileView roles and publish eligibility (TASK-4b2)

    func testEveryRoleMapsAndAnUnknownOneReadsAsUnknown() {
        let table: [(String?, Role)] = [
            ("none", .unset), ("quick", .quick), ("origin", .origin), ("tenant_origin", .tenantOrigin),
            ("r2_profile", .r2Profile), ("member", .member), ("migrated", .migrated),
            ("surprise", .unknown), (nil, .unknown),
        ]
        for (raw, expected) in table {
            XCTAssertEqual(Role(raw: raw), expected, raw ?? "nil")
        }
        XCTAssertTrue(Role.origin.isOrigin)
        XCTAssertTrue(Role.tenantOrigin.isOrigin)
        XCTAssertFalse(Role.member.isOrigin)
        let view = ProfileView(entry: entry(makeSnapshot(role: "member")))
        XCTAssertEqual(view.role, .member)
    }

    func testEveryIneligibleReasonHasItsCopy() {
        struct Row { let name: String; let snapshot: Snapshot; let reason: String; let neutral: Bool }
        let rows: [Row] = [
            Row(name: "migrated", snapshot: makeSnapshot(state: "not_setup", ready: false, servesHere: false, role: "migrated"), reason: "Moved to another machine", neutral: true),
            Row(name: "paused", snapshot: makeSnapshot(role: "member", member: MemberInfo(id: "m-an-1a2b3c4d", status: "paused")), reason: "This member is paused: ask an admin to resume you.", neutral: false),
            Row(name: "left", snapshot: makeSnapshot(role: "member", member: MemberInfo(id: "m-an-1a2b3c4d", status: "left")), reason: "You left s.home.example.com.", neutral: true),
            Row(name: "removed", snapshot: makeSnapshot(role: "member", member: MemberInfo(id: "m-an-1a2b3c4d", status: "removed")), reason: "You were removed from s.home.example.com.", neutral: false),
            Row(name: "member token expired", snapshot: makeSnapshot(role: "member", token: TokenInfo(status: "expired")), reason: "Your key expired; ask the admin to renew it.", neutral: false),
            Row(name: "member token invalid", snapshot: makeSnapshot(role: "member", token: TokenInfo(status: "invalid")), reason: "Your key stopped working; ask the admin.", neutral: false),
            Row(name: "admin token expired", snapshot: makeSnapshot(role: "tenant_origin", token: TokenInfo(status: "expired")), reason: "The stored key expired; run handout api-token.", neutral: false),
            Row(name: "admin token invalid", snapshot: makeSnapshot(role: "tenant_origin", token: TokenInfo(status: "invalid")), reason: "Cloudflare rejected the stored key; run handout api-token.", neutral: false),
            Row(name: "cli below min", snapshot: makeSnapshot(role: "tenant_origin", compat: CompatInfo(status: "cli_below_min", minCLI: "0.10.0")), reason: "Upgrade share to 0.10.0; s.home.example.com requires it.", neutral: false),
            Row(name: "not set up (today's rule)", snapshot: makeSnapshot(state: "not_setup", ready: false, servesHere: false), reason: "Not set up", neutral: true),
        ]
        for row in rows {
            let view = ProfileView(entry: entry(row.snapshot))
            XCTAssertEqual(view.publish, .ineligible(reason: row.reason, neutral: row.neutral), row.name)
            XCTAssertFalse(PublishChoice.isEligible(entry(row.snapshot)), row.name)
        }
    }

    func testEligibleStatesPublishAndOnlyAnIneligibleKeyBlocks() {
        let eligible: [Snapshot] = [
            makeSnapshot(),
            makeSnapshot(state: "stopped", ready: false),
            makeSnapshot(role: "tenant_origin", token: TokenInfo(status: "ok"), compat: CompatInfo(status: "ok")),
            makeSnapshot(role: "tenant_origin", token: TokenInfo(status: "expiring")),
            makeSnapshot(role: "member", member: MemberInfo(id: "m-an-1a2b3c4d", status: "active")),
            makeSnapshot(role: "member", token: TokenInfo(status: "unchecked"), compat: CompatInfo(status: "worker_older")),
        ]
        for snapshot in eligible {
            XCTAssertEqual(ProfileView(entry: entry(snapshot)).publish, .eligible)
            XCTAssertTrue(PublishChoice.isEligible(entry(snapshot)))
        }
        XCTAssertEqual(ProfileView(entry: makeEntry(name: "bad", error: "x")).publish, .ineligible(reason: "Error: x", neutral: false))
    }

    // MARK: link meta line (TASK-4b2)

    func testTheMetaLineByLinkState() {
        let future = Int(now.timeIntervalSince1970) + 3 * 86_400 + 60
        struct Row { let state: String?; let expectedWord: String?; let meta: String }
        let rows: [Row] = [
            Row(state: "live", expectedWord: nil, meta: "this Mac · 3d left"),
            Row(state: "offline", expectedWord: "offline", meta: "this Mac · offline"),
            Row(state: "paused", expectedWord: "paused", meta: "this Mac · paused"),
            Row(state: "expired", expectedWord: "expired", meta: "this Mac · expired"),
            Row(state: "revoked", expectedWord: "removed by admin", meta: "this Mac · removed by admin"),
            Row(state: "shadowed", expectedWord: "replaced", meta: "this Mac · replaced"),
            Row(state: "gate_missing", expectedWord: "no login gate", meta: "this Mac · no login gate"),
            Row(state: "something_new", expectedWord: nil, meta: "this Mac · 3d left"),
        ]
        for row in rows {
            let view = LinkView(share: makeShare(expires: future, storage: "machine", linkState: row.state), now: now)
            XCTAssertEqual(view.meta, row.meta, row.state ?? "nil")
            XCTAssertEqual(view.stateWord, row.expectedWord, row.state ?? "nil")
        }
    }

    func testTheMetaLineWithNoLinkStateOrOrigin() {
        let past = Int(now.timeIntervalSince1970) - 10
        let plain = LinkView(share: makeShare(expires: Int(now.timeIntervalSince1970) + 7_200), now: now)
        XCTAssertEqual(plain.meta, "2h left", "an older CLI row has no storage word")
        XCTAssertEqual(plain.state, .live)
        let lapsed = LinkView(share: makeShare(expires: past), now: now)
        XCTAssertEqual(lapsed.meta, "expired", "the clock stands in for a missing link_state")
        XCTAssertEqual(LinkView(share: makeShare(expires: 0, storage: "machine"), now: now).meta, "this Mac", "never expires: no time word")
        XCTAssertEqual(LinkView(share: makeShare(kind: "live", expires: past, storage: "machine"), now: now).meta, "this Mac · live server")
    }

    func testTheMetaLineOwnerPlaceAndViews() {
        let share = makeShare(expires: 0, storage: "machine", by: "An's MacBook", origin: "m-an-1a2b3c4d", linkState: "offline")
        XCTAssertEqual(LinkView(share: share, scope: .mine, now: now).meta, "an's machine · offline")
        XCTAssertEqual(LinkView(share: share, scope: .team, now: now).meta, "an · an's machine · offline")
        let cloud = makeShare(expires: 0, storage: "cloud", by: "Mac-mini", linkState: "live", views: 12)
        XCTAssertEqual(LinkView(share: cloud, scope: .team, now: now).meta, "Mac-mini · cloud · 12 views")
        XCTAssertEqual(LinkView(share: makeShare(expires: 0, storage: "cloud", views: 1), now: now).meta, "cloud · 1 view")
        XCTAssertEqual(LinkView(share: makeShare(expires: 0, storage: "cloud", views: nil), now: now).meta, "cloud")
    }

    func testMemberIDParsing() {
        XCTAssertEqual(MemberID.name(of: "m-an-1a2b3c4d"), "an")
        XCTAssertEqual(MemberID.name(of: "m-ngoc-anh-1a2b3c4d"), "ngoc-anh")
        XCTAssertEqual(MemberID.suffix(of: "m-an-1a2b3c4d"), "1a2b3c4d")
        XCTAssertNil(MemberID.name(of: "an"))
        XCTAssertNil(MemberID.name(of: "m-an-1a2b3c4"))
        XCTAssertNil(MemberID.name(of: "m-an-zzzzzzzz"))
        XCTAssertNil(MemberID.name(of: "m--1a2b3c4d"))
    }

    // MARK: menu: copy, ops (SB-04, SB-05)

    func testCopyLinkIsDisabledOnExpiredAndAnUnknownValueReadsAsLive() {
        func row(_ state: String?) -> Row {
            Row(share: makeShare(linkState: state), profile: "p", now: now)
        }
        XCTAssertFalse(row("expired").canCopy)
        XCTAssertFalse(row("revoked").canCopy)
        XCTAssertEqual(row("expired").trailing, "expired")
        for state in [nil, "live", "offline", "paused", "shadowed", "gate_missing", "something_new"] {
            XCTAssertTrue(row(state).canCopy, state ?? "nil")
        }
        XCTAssertEqual(row("something_new").linkState, .live)
        let pending = Row(share: makeShare(url: "https://s.home.example.com/<pending>"), profile: "p", now: now)
        XCTAssertFalse(pending.canCopy)
    }

    func testAnAliveOpShowsWorkingAndADeadOneAnAttentionLineWithTheRerunTextOnly() throws {
        let rerun = "share --profile p setup s.example.test --r2 --bucket 'a b; $(touch x)'"
        let dead = OpInfo(verb: "setup-r2", step: 13, of: 16, name: "route", alive: false, rerun: rerun)
        let alive = OpInfo(verb: "teardown", step: 2, of: 5, name: "dns", alive: true, rerun: "share teardown")
        let state = makeSnapshot(ops: [dead, alive, OpInfo(verb: "?", alive: false)])
        let model = MenuModel(profiles: makeProfiles([("p", state)]), failure: nil, now: now)
        XCTAssertEqual(model.header, "Working: teardown (2/5)")
        let lines = try XCTUnwrap(model.sections.first).ops
        XCTAssertEqual(lines.map(\.text), [
            "Working: teardown (2/5)",
            "setup-r2 stopped at step 13 of 16 (route); rerun: \(rerun)",
        ], "the unreadable placeholder is skipped; a running op lists first")
        let onlyDead = MenuModel(profiles: makeProfiles([("p", makeSnapshot(ops: [dead]))]), failure: nil, now: now)
        XCTAssertEqual(onlyDead.header, "Serving at s.home.example.com", "a stopped op adds a line, not a header")
        XCTAssertEqual(onlyDead.sections.first?.ops.count, 1)
    }

    func testARerunDisplayStringIsOneLineWithNoControlCharacters() throws {
        let hostile = OpInfo(verb: "setup-r2", step: 1, of: 16, name: "na\nme", alive: false, rerun: "share setup\nrm -rf x\u{7}")
        let line = try XCTUnwrap(OpLine(hostile))
        XCTAssertFalse(line.text.contains("\n"))
        XCTAssertFalse(line.text.unicodeScalars.contains { $0.value < 32 })
    }

    func testAMutationHeaderBeatsAnAliveOp() {
        let alive = OpInfo(verb: "teardown", step: 2, of: 5, name: "dns", alive: true)
        let model = MenuModel(profiles: makeProfiles([("p", makeSnapshot(ops: [alive]))]), failure: nil, now: now, working: .plain)
        XCTAssertEqual(model.header, MenuModel.workingHeader)
    }
}
