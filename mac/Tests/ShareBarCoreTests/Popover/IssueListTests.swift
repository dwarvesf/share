import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b8: the needs-a-look model, one line per row of the interactions doc section 4.
final class IssueListTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")!
    private let far = 4_102_444_800

    private func list(_ states: [(String, Snapshot)], current: String? = nil, members: [String: MemberList] = [:]) -> IssueList {
        IssueList(profiles: makeProfiles(states), current: current ?? states.first?.0, members: members, now: now)
    }

    private func fullState() throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: loadFixtureData("state-full"))
    }

    private func fullMembers() throws -> MemberList {
        try XCTUnwrap(MemberList.decode(String(decoding: loadFixtureData("member-ls"), as: UTF8.self)))
    }

    private func op(_ verb: String, step: Int = 3, of: Int = 9, alive: Bool = false, name: String = "carry") -> OpInfo {
        OpInfo(verb: verb, step: step, of: of, name: name, alive: alive,
               rerun: "share setup s.test --members", rerunArgv: ["--profile", "console", "setup", "s.test", "--members"])
    }

    private func record(_ name: String, status: String, mode: String = "machine", connectors: Int = 1, expired: Bool = false,
                        lease: MemberLease? = nil, step: Int? = nil, can: [String] = []) -> MemberRecord {
        MemberRecord(memberID: "m-\(name)-1a2b3c4d", name: name, mode: mode, status: status, expired: expired, step: step,
                     lease: lease, connectors: connectors, can: can)
    }

    private func link(_ id: String, by: String, member: String, linkState: String = "live") -> Share {
        makeShare(id: id, name: "\(id).txt", url: "https://s.test/\(id)/x", expires: far, storage: "machine", by: by,
                  origin: "m-\(member)-1a2b3c4d", linkState: linkState)
    }

    // MARK: one row per line of the table

    func testInterruptedCommandReadsStepAndResumesTheJournalsRerun() {
        let state = makeSnapshot(host: "s.test", role: "tenant_origin", ops: [op("setup-members")])
        let result = list([("console", state)])
        XCTAssertEqual(result.count, 1)
        let line = result.lines[0]
        XCTAssertEqual(line.title, "Setup stopped at step 3 of 9")
        XCTAssertEqual(line.detail, "The carry step did not finish")
        XCTAssertEqual(line.action, .resume(argv: ["--profile", "console", "setup", "s.test", "--members"]))
        XCTAssertEqual(line.action?.label, "Resume")
    }

    func testARunningJournalIsNotALine() {
        let state = makeSnapshot(role: "origin", ops: [op("add", alive: true)])
        XCTAssertEqual(list([("han", state)]).count, 0)
    }

    func testAJournalArgvThatFailsItsShapeShowsTextWithNoAction() {
        let bad = OpInfo(verb: "setup-members", step: 3, of: 9, name: "carry", alive: false,
                         rerun: "x", rerunArgv: ["--profile", "console", "rm", "-rf", "/"])
        let result = list([("console", makeSnapshot(role: "tenant_origin", ops: [bad]))])
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result.lines[0].action, "an argv that fails its shape never runs")
    }

    func testFailedServeNamesTheReasonAndStarts() {
        let state = makeSnapshot(host: "s.han.ws", role: "origin", serve: ServeInfo(phase: "failed", reason: "port_in_use"))
        let line = list([("han", state)]).lines[0]
        XCTAssertEqual(line.title, "This Mac stopped serving")
        XCTAssertEqual(line.detail, "Port in use")
        XCTAssertEqual(line.action, .start(argv: ["--profile", "han", "start"]))
        XCTAssertEqual(line.action?.label, "Start")
    }

    func testTunnelNotConnectedOpensTheLog() {
        let state = makeSnapshot(role: "origin", serve: ServeInfo(phase: "tunnel_down"))
        let line = list([("han", state)]).lines[0]
        XCTAssertEqual(line.title, "Tunnel not connected")
        XCTAssertEqual(line.action, .openLog(profile: "han"))
        XCTAssertNil(line.action?.argv)
    }

    func testAStoppedServeIsNotAProblem() {
        let state = makeSnapshot(state: "stopped", ready: false, role: "origin", serve: ServeInfo(phase: "stopped"))
        XCTAssertEqual(list([("han", state)]).count, 0)
    }

    func testExpiringKeyPerRole() {
        let token = TokenInfo(source: "keychain", status: "expiring", expiresOn: "2026-12-01")
        let admin = list([("console", makeSnapshot(host: "s.console.so", role: "tenant_origin", token: token))]).lines[0]
        XCTAssertEqual(admin.title, "Your key expires in 5 days")
        XCTAssertEqual(admin.action, .renew(argv: ["--profile", "console", "member", "renew", "console"]))
        let owner = list([("han", makeSnapshot(role: "origin", token: token))]).lines[0]
        XCTAssertEqual(owner.action, .renew(argv: ["--profile", "han", "api-token"]))
        let member = list([("console", makeSnapshot(host: "s.console.so", role: "member", token: token,
                                                    member: MemberInfo(id: "m-an-1a2b3c4d", name: "an", status: "active")))]).lines[0]
        XCTAssertEqual(member.action?.label, "Copy request")
        guard case .copyRequest(let text)? = member.action else { return XCTFail("a member copies a request") }
        XCTAssertTrue(text.contains("s.console.so") && text.contains("share member renew an"), text)
        XCTAssertNil(member.action?.argv)
    }

    func testAnExpiredAndAnInvalidKeyAreLinesToo() {
        for (status, title) in [("expired", "Your key expired"), ("invalid", "Your key stopped working")] {
            let state = makeSnapshot(role: "origin", token: TokenInfo(status: status))
            XCTAssertEqual(list([("han", state)]).lines.first?.title, title)
        }
        XCTAssertEqual(list([("han", makeSnapshot(role: "origin", token: TokenInfo(status: "ok")))]).count, 0)
    }

    func testARemovedMemberCleansUp() {
        let state = makeSnapshot(host: "s.console.so", role: "member", member: MemberInfo(id: "m-an-1a2b3c4d", name: "an", status: "removed"))
        let line = list([("console", state)]).lines[0]
        XCTAssertEqual(line.title, "You were removed from s.console.so")
        XCTAssertEqual(line.action, .cleanUp(argv: ["--profile", "console", "leave", "--local"]))
        XCTAssertEqual(line.action?.label, "Clean up")
    }

    func testOfflineMachineWithLinksOpensMembers() {
        let state = makeSnapshot(host: "s.console.so",
                                 shares: [link("a1", by: "An's MacBook", member: "an"), link("a2", by: "An's MacBook", member: "an")], role: "tenant_origin")
        let members = MemberList(members: [record("an", status: "active", connectors: 0, can: ["pause"])])
        let line = list([("console", state)], members: ["console": members]).lines[0]
        XCTAssertEqual(line.title, "An's MacBook is offline")
        XCTAssertEqual(line.detail, "2 links answer 503 until it is back")
        XCTAssertEqual(line.action, .open(profile: "console", member: "an"))
    }

    func testAnOfflineMachineWithNoLinksIsNotALine() {
        let state = makeSnapshot(role: "tenant_origin")
        let members = MemberList(members: [record("an", status: "active", connectors: 0)])
        XCTAssertEqual(list([("console", state)], members: ["console": members]).count, 0)
    }

    func testPausedLeftAndExpiredCodeMembers() {
        let state = makeSnapshot(host: "s.console.so", shares: [link("d1", by: "Dung's iMac", member: "dung", linkState: "paused")], role: "tenant_origin")
        let members = MemberList(members: [
            record("dung", status: "paused", can: ["resume"]),
            record("ha", status: "left", can: ["purge"]),
            record("chi", status: "invited", mode: "cloud", connectors: 0, expired: true, can: ["invite"]),
        ])
        let lines = list([("console", state)], members: ["console": members]).lines
        XCTAssertEqual(lines.map(\.title), ["Dung is paused", "Ha left", "Chi's code expired"])
        XCTAssertEqual(lines[0].detail, "1 link answers 503")
        XCTAssertEqual(lines[0].action, .resumeMember(argv: ["--profile", "console", "member", "resume", "dung"]))
        XCTAssertEqual(lines[1].action, .remove(profile: "console", member: "ha"))
        XCTAssertEqual(lines[2].action, .sendCode(argv: ["--profile", "console", "member", "invite", "chi"]))
    }

    func testAStoppedVerbFinishesWithItsOwnVerb() {
        let stale = MemberLease(holder: "mac:1:a", verb: "pause", step: 2, live: false)
        let state = makeSnapshot(host: "s.console.so", role: "tenant_origin")
        let members = MemberList(members: [record("minh", status: "pausing", lease: stale, step: 2, can: ["finish", "rm"])])
        let line = list([("console", state)], members: ["console": members]).lines[0]
        XCTAssertEqual(line.title, "Pausing Minh stopped at step 2")
        XCTAssertEqual(line.action, .finish(argv: ["--profile", "console", "member", "pause", "minh"]))
        XCTAssertEqual(line.action?.label, "Finish")
    }

    func testAVerbWithALiveLeaseIsRunningNotALine() {
        let live = MemberLease(holder: "mac:1:a", verb: "pause", step: 2, live: true)
        let members = MemberList(members: [record("minh", status: "pausing", lease: live, step: 2, can: ["finish"])])
        XCTAssertEqual(list([("console", makeSnapshot(role: "tenant_origin"))], members: ["console": members]).count, 0)
    }

    func testInvitedIsNotALine() {
        let members = MemberList(members: [record("linh", status: "invited", mode: "cloud", connectors: 0, can: ["invite", "rm"])])
        XCTAssertEqual(list([("console", makeSnapshot(role: "tenant_origin"))], members: ["console": members]).count, 0)
    }

    // MARK: order and grouping

    func testLineOrderIsInterruptedServingKeyMember() {
        let token = TokenInfo(status: "expiring", expiresOn: "2026-12-01")
        let stale = MemberLease(holder: "m:1:a", verb: "pause", step: 2, live: false)
        let state = makeSnapshot(
            host: "s.console.so", shares: [link("a1", by: "An's MacBook", member: "an")], role: "tenant_origin",
            serve: ServeInfo(phase: "failed", reason: "port_in_use"), ops: [op("setup-members")], token: token
        )
        let members = MemberList(members: [
            record("minh", status: "pausing", lease: stale, step: 2, can: ["finish"]),
            record("an", status: "active", connectors: 0),
        ])
        let titles = list([("console", state)], members: ["console": members]).lines.map(\.title)
        XCTAssertEqual(titles, [
            "Setup stopped at step 3 of 9", "This Mac stopped serving", "Your key expires in 5 days",
            "An's MacBook is offline", "Pausing Minh stopped at step 2",
        ])
        XCTAssertEqual(list([("console", state)], members: ["console": members]).lines.map(\.kind),
                       [.interrupted, .serving, .key, .member, .member])
    }

    func testCurrentTenantFirstWithItsTag() {
        let a = makeSnapshot(host: "s.a.test", role: "origin", serve: ServeInfo(phase: "failed", reason: "port_in_use"))
        let b = makeSnapshot(host: "s.b.test", role: "origin", serve: ServeInfo(phase: "tunnel_down"))
        let c = makeSnapshot(host: "s.c.test", role: "origin")
        let result = list([("a", a), ("b", b), ("c", c)], current: "b")
        XCTAssertEqual(result.groups.map(\.profile), ["b", "a"], "a tenant with no line has no group")
        XCTAssertEqual(result.groups.map(\.isCurrent), [true, false])
        XCTAssertEqual(result.groups.map(\.host), ["s.b.test", "s.a.test"])
    }

    func testEmptyReadsNothingNeedsALook() {
        let result = list([("han", makeSnapshot(role: "origin"))])
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(IssueList.emptyText, "Nothing needs a look.")
    }

    func testEachActionMapsToItsArgv() throws {
        let state = try fullState()
        let result = list([("console", state)], members: ["console": try fullMembers()])
        let actions = result.lines.compactMap(\.action)
        XCTAssertFalse(actions.isEmpty)
        for action in actions {
            switch action {
            case .copyRequest, .open, .remove, .openLog: XCTAssertNil(action.argv)
            default:
                let argv = try XCTUnwrap(action.argv, action.label)
                XCTAssertEqual(argv.prefix(2), ["--profile", "console"], "every command runs on its own profile")
            }
        }
        XCTAssertEqual(
            result.lines.map(\.title),
            ["Setup stopped at step 13 of 16", "Your key expires in 5 days", "An's MacBook is offline",
             "Linh's code expired", "Pausing Nam stopped at step 2"]
        )
    }

    func testAProfileWithAnErrorOrNoRoleHasNoLines() {
        let broken = ProfilesSnapshot(schema: 1, profiles: [makeEntry(name: "x", error: "boom"), makeEntry(name: "d", state: makeSnapshot(state: "not_setup", role: "none"))])
        XCTAssertEqual(IssueList(profiles: broken, current: "x").count, 0)
        XCTAssertEqual(IssueList(profiles: nil, current: nil).count, 0)
    }
}
