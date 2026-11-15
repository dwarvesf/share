import XCTest
@testable import ShareBarCore

/// SPEC-010 DEC-21: a stopped op's `rerun_argv` / `rollback_argv` run by exec with no shell,
/// and only after the verb and the profile check out.
final class JournalRunTests: XCTestCase {
    private func op(_ json: String) throws -> OpInfo {
        try JSONDecoder().decode(OpInfo.self, from: Data(json.utf8))
    }

    private func dead(verb: String, rerun: [String]?, rollback: [String]? = nil, alive: Bool = false, id: String? = nil) throws -> OpInfo {
        func array(_ a: [String]?) -> String {
            guard let a else { return "null" }
            let data = (try? JSONSerialization.data(withJSONObject: a)) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        return try op("""
        {"verb":"\(verb)","step":2,"of":4,"name":"x","alive":\(alive),"id":\(id.map { "\"\($0)\"" } ?? "null"),
         "rerun_argv":\(array(rerun)),"rollback_argv":\(array(rollback)),
         "rerun":"display only; rm -rf ~","rollback":"display only"}
        """)
    }

    func testRerunArgvLeadsWithProfileAndIsTheStoredArray() throws {
        let o = try dead(verb: "setup-r2", rerun: ["--profile", "p", "setup", "s.example.com", "--r2", "--bucket", "b"])
        XCTAssertEqual(JournalRun.argv(op: o, kind: .rerun, profile: "p"),
                       ["--profile", "p", "setup", "s.example.com", "--r2", "--bucket", "b"])
    }

    func testRollbackArgvRuns() throws {
        let o = try dead(verb: "setup-r2", rerun: ["setup", "s.example.com"], rollback: ["--profile", "p", "setup", "s.example.com", "--no-r2"])
        XCTAssertEqual(JournalRun.argv(op: o, kind: .rollback, profile: "p"),
                       ["--profile", "p", "setup", "s.example.com", "--no-r2"])
    }

    func testStoredArgvWithoutProfileGetsTheListedProfile() throws {
        let o = try dead(verb: "setup-r2", rerun: ["setup", "s.example.com"])
        XCTAssertEqual(JournalRun.argv(op: o, kind: .rerun, profile: "p"), ["--profile", "p", "setup", "s.example.com"])
    }

    func testAnArgvNamingAnotherProfileDoesNotRun() throws {
        let o = try dead(verb: "setup-r2", rerun: ["--profile", "other", "setup", "s.example.com"])
        XCTAssertNil(JournalRun.argv(op: o, kind: .rerun, profile: "p"))
    }

    func testAVerbOutsideTheJournalsOwnVerbDoesNotRun() throws {
        let o = try dead(verb: "setup-r2", rerun: ["--profile", "p", "teardown", "--purge"])
        XCTAssertNil(JournalRun.argv(op: o, kind: .rerun, profile: "p"))
        let rm = try dead(verb: "setup-r2", rerun: ["rm", "x"])
        XCTAssertNil(JournalRun.argv(op: rm, kind: .rerun, profile: "p"))
    }

    func testAnAddJournalMayRerunAddAndRollBackWithRm() throws {
        let o = try dead(verb: "add", rerun: ["--profile", "p", "add", "/tmp/a.txt"], rollback: ["--profile", "p", "rm", "4f9ff2"], id: "4f9ff2")
        XCTAssertNotNil(JournalRun.argv(op: o, kind: .rerun, profile: "p"))
        XCTAssertEqual(JournalRun.argv(op: o, kind: .rollback, profile: "p"), ["--profile", "p", "rm", "4f9ff2"])
    }

    func testAFlagTheVerbsOwnJournalNeverWritesDoesNotRun() throws {
        // A plain teardown must not become a purge, and setup must not take a token flag.
        let teardown = try dead(verb: "teardown", rerun: ["--profile", "p", "teardown", "--yes", "--purge"])
        XCTAssertNil(JournalRun.argv(op: teardown, kind: .rerun, profile: "p"))
        let purge = try dead(verb: "teardown-purge", rerun: ["--profile", "p", "teardown", "--yes", "--purge"])
        XCTAssertNotNil(JournalRun.argv(op: purge, kind: .rerun, profile: "p"))
        let setup = try dead(verb: "setup-tunnel", rerun: ["setup", "attacker.example", "--force", "--token-stdin"])
        XCTAssertNil(JournalRun.argv(op: setup, kind: .rerun, profile: "p"))
        let value = try dead(verb: "setup-r2", rerun: ["setup", "s.example.com", "--r2", "--bucket", "--force"])
        XCTAssertNil(JournalRun.argv(op: value, kind: .rerun, profile: "p"), "a flag is never a flag's value")
        let second = try dead(verb: "setup-r2", rerun: ["--profile", "p", "setup", "a.example", "b.example"])
        XCTAssertNil(JournalRun.argv(op: second, kind: .rerun, profile: "p"))
    }

    func testAnAddRollbackNamesOnlyItsOwnShareID() throws {
        let other = try dead(verb: "add", rerun: ["add", "/tmp/a.txt"], rollback: ["rm", "someone-elses"], id: "4f9ff2")
        XCTAssertNil(JournalRun.argv(op: other, kind: .rollback, profile: "p"))
        let noID = try dead(verb: "add", rerun: ["add", "/tmp/a.txt"], rollback: ["rm", "4f9ff2"])
        XCTAssertNil(JournalRun.argv(op: noID, kind: .rollback, profile: "p"))
        let prune = try dead(verb: "add", rerun: ["add", "/tmp/a.txt"], rollback: ["prune"])
        XCTAssertEqual(JournalRun.argv(op: prune, kind: .rollback, profile: "p"), ["--profile", "p", "prune"])
    }

    func testAJoinRollsBackWithLeaveLocal() throws {
        let o = try dead(verb: "join", rerun: ["join"], rollback: ["leave", "--local"])
        XCTAssertEqual(JournalRun.argv(op: o, kind: .rerun, profile: "p"), ["--profile", "p", "join"])
        XCTAssertEqual(JournalRun.argv(op: o, kind: .rollback, profile: "p"), ["--profile", "p", "leave", "--local"])
        let code = try dead(verb: "join", rerun: ["join", "s.example.com", "a-single-use-code"])
        XCTAssertNil(JournalRun.argv(op: code, kind: .rerun, profile: "p"), "a join journal never carries a code")
    }

    func testAnOpWithUnreadableLivenessNeverRuns() throws {
        let unknown = try op("""
        {"verb":"setup-r2","alive":"yes","rerun_argv":["setup","s.example.com"]}
        """)
        XCTAssertFalse(unknown.aliveKnown)
        XCTAssertNil(JournalRun.argv(op: unknown, kind: .rerun, profile: "p"))
        let missing = try op("""
        {"verb":"setup-r2","rerun_argv":["setup","s.example.com"]}
        """)
        XCTAssertNil(JournalRun.argv(op: missing, kind: .rerun, profile: "p"))
    }

    func testAnUnknownJournalVerbNeverRuns() throws {
        let o = try dead(verb: "evil", rerun: ["--profile", "p", "setup", "x"])
        XCTAssertNil(JournalRun.argv(op: o, kind: .rerun, profile: "p"))
    }

    func testALiveOpNeverRuns() throws {
        let o = try dead(verb: "setup-r2", rerun: ["--profile", "p", "setup", "x"], alive: true)
        XCTAssertNil(JournalRun.argv(op: o, kind: .rerun, profile: "p"))
    }

    func testAMissingOrEmptyArgvNeverRuns() throws {
        XCTAssertNil(JournalRun.argv(op: try dead(verb: "setup-r2", rerun: nil), kind: .rerun, profile: "p"))
        XCTAssertNil(JournalRun.argv(op: try dead(verb: "setup-r2", rerun: []), kind: .rerun, profile: "p"))
        XCTAssertNil(JournalRun.argv(op: try dead(verb: "setup-r2", rerun: ["setup"]), kind: .rollback, profile: "p"))
    }

    func testTheDisplayStringIsNeverUsed() throws {
        // `rerun` carries shell syntax; the argv is the only input to the run.
        let o = try dead(verb: "setup-r2", rerun: ["--profile", "p", "setup", "s.example.com"])
        XCTAssertEqual(JournalRun.argv(op: o, kind: .rerun, profile: "p"), ["--profile", "p", "setup", "s.example.com"])
        XCTAssertFalse(JournalRun.argv(op: o, kind: .rerun, profile: "p")!.joined().contains("rm -rf"))
    }

    func testABadProfileNameOrOversizedArgumentDoesNotRun() throws {
        let o = try dead(verb: "setup-r2", rerun: ["setup", "x"])
        XCTAssertNil(JournalRun.argv(op: o, kind: .rerun, profile: "../etc"))
        XCTAssertNil(JournalRun.argv(op: o, kind: .rerun, profile: "A;b"))
        XCTAssertNil(JournalRun.argv(op: o, kind: .rerun, profile: "p\n"), "a trailing newline is not a profile name")
        let big = try dead(verb: "setup-r2", rerun: ["setup", String(repeating: "a", count: 5000)])
        XCTAssertNil(JournalRun.argv(op: big, kind: .rerun, profile: "p"))
    }

    func testMemberVerbJournalsRerunAsMember() throws {
        let o = try dead(verb: "member-add", rerun: ["--profile", "p", "member", "add", "alice"])
        XCTAssertNotNil(JournalRun.argv(op: o, kind: .rerun, profile: "p"))
        let bad = try dead(verb: "member-add", rerun: ["--profile", "p", "setup", "x"])
        XCTAssertNil(JournalRun.argv(op: bad, kind: .rerun, profile: "p"))
    }

    func testRunExecsTheArgvWithNoShell() async throws {
        // A stand-in CLI records each argument on its own line. A shell metacharacter in an
        // argument must reach it as one literal argument, and the marker file must not appear.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journalrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("share")
        let log = dir.appendingPathComponent("argv.txt")
        let marker = dir.appendingPathComponent("injected")
        try "#!/bin/bash\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> '\(log.path)'; done\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        setenv("SHARE_BIN", script.path, 1)
        defer { unsetenv("SHARE_BIN") }

        let hostile = "a b; touch \(marker.path)"
        let o = try dead(verb: "setup-r2", rerun: ["setup", hostile])
        let result = await JournalRun.run(op: o, kind: .rerun, profile: "p", timeout: 10)
        XCTAssertEqual(result?.status, 0)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["--profile", "p", "setup", hostile])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let refused = try dead(verb: "setup-r2", rerun: ["teardown"])
        let none = await JournalRun.run(op: refused, kind: .rerun, profile: "p", timeout: 10)
        XCTAssertNil(none)
    }
}
