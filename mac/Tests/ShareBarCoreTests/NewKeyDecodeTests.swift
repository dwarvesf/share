import XCTest
@testable import ShareBarCore

/// TASK-4b1: the keys SPEC-010 and SPEC-009 added to `share state`, and the two new
/// outputs, `member ls --json` and the progress line. Fixtures are built to the spec's
/// shapes (`state-full.json`, `member-ls.json`).
final class NewKeyDecodeTests: XCTestCase {
    private func full() throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: loadFixtureData("state-full"))
    }

    func testDecodeEveryNewKeyPresent() throws {
        let state = try full()
        XCTAssertEqual(state.role, "tenant_origin")
        XCTAssertEqual(state.tier, "t2")
        XCTAssertEqual(state.serve, ServeInfo(phase: "serving", reason: "ok"))
        XCTAssertEqual(state.token, TokenInfo(source: "keychain", status: "expiring", expiresOn: "2026-12-01"))
        XCTAssertEqual(state.compat, CompatInfo(cli: "0.10.0", worker: "5 a1b2c3d4e5f6", status: "ok", minCLI: "0.10.0"))
        XCTAssertEqual(state.member, MemberInfo(id: "m-an-1a2b3c4d", name: "an", mode: "machine", status: "active", step: nil, tokenExpires: "2027-01-15"))

        let ops = try XCTUnwrap(state.ops)
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(ops[0].verb, "setup-r2")
        XCTAssertEqual(ops[0].step, 13)
        XCTAssertEqual(ops[0].of, 16)
        XCTAssertEqual(ops[0].name, "route")
        XCTAssertFalse(ops[0].alive)
        XCTAssertEqual(ops[0].rerunArgv, ["--profile", "console", "setup", "s.console.so", "--r2", "--bucket", "console-share"])
        XCTAssertEqual(ops[0].rollbackArgv, ["--profile", "console", "setup", "s.console.so", "--no-r2"])
        XCTAssertTrue(ops[1].alive)
        XCTAssertNil(ops[1].rollbackArgv)

        let rows = Dictionary(uniqueKeysWithValues: state.shares.map { ($0.id, $0) })
        XCTAssertEqual(rows["7f3a21"]?.origin, "m-an-1a2b3c4d")
        XCTAssertEqual(rows["7f3a21"]?.linkState, "offline")
        XCTAssertEqual(rows["2be8d0"]?.reason, "paused_by=han")
        XCTAssertEqual(rows["9d10aa"]?.views, 12)
        XCTAssertEqual(rows["30c9bb"]?.linkState, "revoked")
        XCTAssertNil(rows["c4c2a0"]?.origin)
    }

    func testDecodeEveryNewKeyAbsent() throws {
        let old = [
            try loadFixtureSnapshot(),
            try XCTUnwrap(loadFixtureProfiles().profiles.compactMap(\.state).first),
            try XCTUnwrap(loadFixtureTenantProfiles().profiles.compactMap(\.state).first),
        ]
        for state in old {
            XCTAssertNil(state.role)
            XCTAssertNil(state.tier)
            XCTAssertNil(state.serve)
            XCTAssertNil(state.ops)
            XCTAssertNil(state.token)
            XCTAssertNil(state.compat)
            XCTAssertNil(state.member)
            for share in state.shares {
                XCTAssertNil(share.origin)
                XCTAssertNil(share.linkState)
                XCTAssertNil(share.reason)
                XCTAssertNil(share.views)
            }
        }
        let base = try loadFixtureSnapshot()
        XCTAssertEqual(base.state, "serving")
        XCTAssertEqual(base.host, "s.han.ws")
        XCTAssertEqual(base.shares.map(\.id), ["4f9ff2", "b99924", "4a8ca7", "c4c2a0"])
    }

    func testAnUnknownExtraKeyIsIgnored() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: loadFixtureData("state-full")) as? [String: Any])
        object["brand_new_key"] = ["nested": [1, 2, 3]]
        var rows = try XCTUnwrap(object["shares"] as? [[String: Any]])
        rows[0]["brand_new_row_key"] = "x"
        object["shares"] = rows
        let state = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(state, try full())
    }

    func testAMalformedNewKeyReadsAsAbsentNeverAsAnError() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: loadFixtureData("state-full")) as? [String: Any])
        object["role"] = 7
        object["tier"] = ["t2"]
        object["serve"] = "serving"
        object["ops"] = [["verb": 5], ["verb": "add", "alive": true, "step": "two"]]
        object["token"] = ["status": 3]
        object["compat"] = "ok"
        object["member"] = []
        var rows = try XCTUnwrap(object["shares"] as? [[String: Any]])
        rows[0]["link_state"] = 1
        rows[0]["views"] = "many"
        object["shares"] = rows
        let listing = Data(#"{"schema":1,"profiles":[{"name":"p","state":\#(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))}]}"#.utf8)
        let entry = try XCTUnwrap(JSONDecoder().decode(ProfilesSnapshot.self, from: listing).profiles.first)
        XCTAssertNil(entry.error, "one odd new key never turns a readable state into 'state not readable'")
        let state = try XCTUnwrap(entry.state)
        XCTAssertNil(state.role)
        XCTAssertNil(state.serve)
        XCTAssertNil(state.token)
        XCTAssertNil(state.compat)
        XCTAssertNil(state.member)
        XCTAssertEqual(state.ops?.count, 1, "the readable op survives; the unreadable one is dropped")
        XCTAssertEqual(state.ops?.first?.verb, "add")
        XCTAssertNil(state.ops?.first?.step)
        XCTAssertNil(state.shares[0].linkState)
        XCTAssertNil(state.shares[0].views)
        XCTAssertEqual(Health.of(entry), .ok)
    }

    func testMemberLsJSONWithCan() throws {
        let list = try XCTUnwrap(MemberList.decode(String(decoding: loadFixtureData("member-ls"), as: UTF8.self)))
        XCTAssertEqual(list.members.map(\.name), ["an", "nam", "linh", "?"])
        let an = list.members[0]
        XCTAssertEqual(an.memberID, "m-an-1a2b3c4d")
        XCTAssertEqual(an.status, "active")
        XCTAssertEqual(an.mode, "machine")
        XCTAssertTrue(an.deployBound)
        XCTAssertFalse(an.deployPaused)
        XCTAssertEqual(an.connectors, 0)
        XCTAssertFalse(an.isOnline)
        XCTAssertEqual(an.tokenExpires, "2027-01-15")
        XCTAssertEqual(an.can, ["pause", "invite", "rotate", "renew", "rm"])

        let nam = list.members[1]
        XCTAssertTrue(nam.isRunning)
        XCTAssertEqual(nam.step, 2)
        XCTAssertEqual(nam.of, 3)
        XCTAssertEqual(nam.stepName, "deploy")
        XCTAssertEqual(nam.lease?.live, false)
        XCTAssertEqual(nam.lease?.verb, "pause")
        XCTAssertTrue(nam.can.contains("finish"))
        XCTAssertEqual(nam.drift, ["deploy_paused_record_active"])
        XCTAssertTrue(nam.isOnline)

        let linh = list.members[2]
        XCTAssertTrue(linh.expired)
        XCTAssertEqual(linh.mode, "cloud")
        XCTAssertEqual(linh.inviteExpires, 1_763_600_000)

        XCTAssertEqual(list.members[3].status, "invalid")
        XCTAssertEqual(list.members[3].can, [])
        XCTAssertEqual(list.members[3].drift, ["record_invalid"])
    }

    func testMemberLsSkipsAnEntryItCannotReadAndRejectsANonArray() throws {
        let some = MemberList.decode(#"[{"member_id":"m-an-1a2b3c4d","name":"an","status":"active","can":["rm"]},{"name":5}]"#)
        XCTAssertEqual(some?.members.count, 1)
        XCTAssertNil(MemberList.decode("share: usage: share member <verb>"))
        XCTAssertEqual(MemberList.decode("[]")?.members.count, 0)
    }

    func testProgressLine() throws {
        let line = #"{"progress":{"verb":"setup-r2","step":13,"of":16,"name":"route"}}"#
        XCTAssertEqual(Progress.parse(line: line), Progress(verb: "setup-r2", step: 13, of: 16, name: "route"))
        XCTAssertNil(Progress.parse(line: "share: setup-r2 failed"))
        XCTAssertNil(Progress.parse(line: #"{"error":{"code":"x","message":"m"}}"#))
        XCTAssertNil(Progress.parse(line: #"{"progress":{"verb":"x"}}"#))
        let stderr = "share: warming up\n\(line)\n{\"progress\":{\"verb\":\"setup-r2\",\"step\":14,\"of\":16,\"name\":\"dns\"}}\n"
        XCTAssertEqual(Progress.last(inStderr: stderr)?.step, 14)
        XCTAssertNil(Progress.last(inStderr: "share: nothing here\n"))
    }
}
