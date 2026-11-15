import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b19: the Members tab's list model, its row menu and its argv.
final class MembersModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ name: String, _ status: String, mode: String = "machine", connectors: Int = 1, can: [String] = [],
        expired: Bool = false, lease: MemberLease? = nil, step: Int? = nil, of: Int? = nil, stepName: String? = nil,
        inviteExpires: Int? = nil
    ) -> MemberRecord {
        MemberRecord(memberID: "m-\(name)-1a2b3c4d", name: name, mode: mode, status: status, expired: expired, step: step, of: of,
                     stepName: stepName, lease: lease, connectors: connectors, inviteExpires: inviteExpires, can: can)
    }

    /// The design's CAN table, one entry per stored status, in the CLI's own order.
    private let canByStatus: [String: [String]] = [
        "invited": ["invite", "renew", "rm"], "joining": ["finish", "rm"], "active": ["pause", "invite", "rotate", "renew", "rm"],
        "paused": ["resume", "rotate", "renew", "rm"], "left": ["invite", "rm"], "removed": ["purge"],
        "pausing": ["finish", "rm"], "resuming": ["finish", "rm"], "rotating": ["finish", "rm"], "removing": ["finish"],
    ]

    func testRowMenuEqualsCanForEveryStoredStatus() {
        for (status, can) in canByStatus {
            let menu = MembersModel.menu(for: record("x", status, can: can)).map(\.rawValue)
            XCTAssertEqual(Set(menu), Set(can), "\(status): the menu lists exactly can[]")
            XCTAssertEqual(menu.count, can.count, "\(status): nothing twice")
        }
    }

    func testTheMenuOrderPutsTheDestructiveVerbLast() {
        let menu = MembersModel.menu(for: record("x", "active", can: ["rm", "renew", "pause", "rotate", "invite"]))
        XCTAssertEqual(menu, [.pause, .invite, .rotate, .renew, .rm])
        XCTAssertEqual(menu.last?.isDestructive, true)
        XCTAssertEqual(MembersModel.menu(for: record("x", "removed", can: ["purge"])), [.purge])
    }

    func testAVerbTheAppDoesNotKnowNeverShows() {
        XCTAssertEqual(MembersModel.menu(for: record("x", "active", can: ["pause", "adopt", "join", "sync", "leave"])), [.pause])
        XCTAssertEqual(MembersModel.menu(for: record("x", "active", can: [])), [])
    }

    func testEachVerbMapsToItsArgv() {
        let member = record("an", "active")
        for verb in [MemberVerb.resume, .pause, .invite, .rotate, .renew, .rm, .purge] {
            XCTAssertEqual(MembersModel.argv(verb, member: member, profile: "console"), ["--profile", "console", "member", verb.rawValue, "an"])
        }
    }

    func testFinishRerunsTheVerbTheStatusStoppedOn() {
        let cases = [("pausing", "pause"), ("resuming", "resume"), ("rotating", "rotate"), ("renewing", "renew"), ("removing", "rm"), ("inviting", "invite")]
        for (status, verb) in cases {
            XCTAssertEqual(MembersModel.argv(.finish, member: record("minh", status, can: ["finish"]), profile: "p"), ["--profile", "p", "member", verb, "minh"])
        }
        XCTAssertNil(MembersModel.argv(.finish, member: record("x", "adding"), profile: "p"), "adding reruns through Invite, not Finish")
    }

    func testANameWithALeadingDashNeverReachesArgv() {
        XCTAssertNil(MembersModel.argv(.pause, member: record("-rf", "active"), profile: "p"))
        XCTAssertNil(MembersModel.argv(.pause, member: record("an", "active"), profile: ""))
    }

    func testFiltersCount() throws {
        let members = [
            record("an", "active", connectors: 0), record("bao", "active"), record("chi", "paused"), record("dung", "invited", expired: true),
            record("ha", "left"), record("minh", "pausing", lease: MemberLease(verb: "pause", step: 2, live: false)), record("quan", "removed"),
        ]
        let shares = [makeShare(id: "a1", url: "u", by: "An's MacBook", origin: "m-an-1a2b3c4d")]
        let all = MembersModel(members: members, shares: shares, filter: .all, query: "", now: now)
        XCTAssertEqual(all.counts[.all], 6, "removed members are not in All")
        XCTAssertEqual(all.counts[.removed], 1)
        XCTAssertEqual(all.counts[.needsLook], 5, "offline with links, paused, expired code, left, stopped verb")
        XCTAssertEqual(all.rows.map(\.name), ["An", "Bao", "Chi", "Dung", "Ha", "Minh"])
        XCTAssertEqual(MembersModel(members: members, shares: shares, filter: .removed, query: "", now: now).rows.map(\.name), ["Quan"])
        XCTAssertEqual(MembersModel(members: members, shares: shares, filter: .needsLook, query: "", now: now).rows.map(\.name), ["An", "Chi", "Dung", "Ha", "Minh"])
    }

    func testSearchFiltersByNameAndSaysWhenNothingMatches() {
        let members = [record("an", "active"), record("bao", "active")]
        XCTAssertEqual(MembersModel(members: members, shares: [], filter: .all, query: "ba", now: now).rows.map(\.name), ["Bao"])
        let none = MembersModel(members: members, shares: [], filter: .all, query: "zz", now: now)
        XCTAssertEqual(none.emptyText, "No members match.")
        XCTAssertEqual(MembersModel(members: members, shares: [], filter: .needsLook, query: "", now: now).emptyText, "Nobody needs a look.")
        XCTAssertEqual(MembersModel(members: members, shares: [], filter: .removed, query: "", now: now).emptyText, "No removed members.")
    }

    func testTheRowShowsAChipOrThePresenceWordAndTheLinkCount() {
        let shares = [makeShare(id: "a1", url: "u", by: "An's MacBook", origin: "m-an-1a2b3c4d"), makeShare(id: "a2", url: "u", origin: "m-an-1a2b3c4d")]
        let rows = MembersModel(members: [record("an", "active"), record("chi", "paused"), record("dung", "invited", inviteExpires: Int(now.timeIntervalSince1970) + 6 * 86_400 + 60)],
                                shares: shares, filter: .all, query: "", now: now).rows
        XCTAssertEqual(rows[0].presence, "Online")
        XCTAssertNil(rows[0].chip)
        XCTAssertEqual(rows[0].linkText, "2 links")
        XCTAssertEqual(rows[0].subLine, "An's MacBook")
        XCTAssertEqual(rows[1].chip, MemberChip(text: "Paused", tone: .quiet))
        XCTAssertEqual(rows[2].chip, MemberChip(text: "Invited", tone: .info))
        XCTAssertEqual(rows[2].subLine, "code expires in 6d")
    }

    func testARunningVerbShowsItsStepAndAStaleLeaseShowsFinish() {
        let running = record("minh", "pausing", can: ["finish", "rm"], lease: MemberLease(holder: "han", verb: "pause", step: 2, live: true), stepName: "deploy")
        let stale = record("nam", "pausing", can: ["finish", "rm"], lease: MemberLease(holder: "han", verb: "pause", step: 2, live: false))
        let rows = MembersModel(members: [running, stale], shares: [], filter: .all, query: "", now: now).rows
        XCTAssertEqual(rows[0].subLine, "Pausing, step 2 (deploy)")
        XCTAssertEqual(rows[0].chip, MemberChip(text: "Pausing", tone: .attention))
        XCTAssertEqual(rows[1].subLine, "pausing stopped at step 2")
        XCTAssertEqual(rows[1].chip, MemberChip(text: "Stopped", tone: .attention))
        XCTAssertEqual(rows[1].menu, [.finish, .rm])
        XCTAssertEqual(MemberVerb.finish.title(status: "pausing"), "Finish pausing")
    }

    func testAnOfflineMachineMemberSaysSoInItsSubLine() {
        let rows = MembersModel(members: [record("nam", "active", connectors: 0)], shares: [], filter: .all, query: "", now: now).rows
        XCTAssertEqual(rows[0].presence, "Offline")
        XCTAssertEqual(rows[0].subLine, "Nam's machine · offline")
    }

    func testAMemberLsFailureShowsItsSentence() {
        let json = CLIResult(status: 1, stdout: "", stderr: "share: x\n{\"error\":{\"code\":\"member_failed\",\"message\":\"The bucket refused the read.\",\"next\":\"share member ls\"}}\n", timedOut: false)
        XCTAssertEqual(MembersModel.failureSentence(json), "The bucket refused the read.")
        let plain = CLIResult(status: 1, stdout: "", stderr: "share: needs the admin key\n", timedOut: false)
        XCTAssertEqual(MembersModel.failureSentence(plain), "needs the admin key")
        XCTAssertEqual(MembersModel.failureSentence(CLIResult(status: 1, stdout: "", stderr: "", timedOut: false)).hasPrefix("Couldn't read the members"), true)
    }

    func testTheListArgvAsksForJSONOnTheProfile() {
        XCTAssertEqual(MembersModel.listArgv(profile: "console"), ["--profile", "console", "member", "ls", "--json"])
    }

    func testTheFixtureRosterDecodesIntoRows() throws {
        let list = try XCTUnwrap(MemberList.decode(String(data: loadFixtureData("member-ls"), encoding: .utf8) ?? ""))
        let model = MembersModel(members: list.members, shares: [], filter: .all, query: "", now: now)
        XCTAssertEqual(model.rows.first?.menu, [.pause, .invite, .rotate, .renew, .rm])
    }
}
