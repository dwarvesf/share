import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b16 (sheets) and TASK-4b18 (journaled flows).
final class SheetsAndFlowTests: XCTestCase {
    // MARK: 4b16

    func testStopServingCountsFromRows() {
        let rows = [
            makeShare(id: "1", storage: "machine"), makeShare(id: "2", storage: "machine"),
            makeShare(id: "3", storage: "machine"), makeShare(id: "4", storage: "machine"),
            makeShare(id: "5", storage: "cloud"), makeShare(id: "6", storage: "cloud"),
            makeShare(id: "7", storage: "machine", origin: "m-an-1a2b3c4d"),
        ]
        let sheet = Impact.stopServing(host: "s.console.so", shares: rows)
        XCTAssertEqual(sheet.title, "Stop serving s.console.so from this Mac?")
        XCTAssertEqual(sheet.lines, [
            ImpactLine(.stops, "4 links on this Mac stop answering until you start again"),
            ImpactLine(.keeps, "3 cloud and member links keep working"),
        ])
        XCTAssertEqual(sheet.actionTitle, "Stop serving")
        let one = Impact.stopServing(host: "h", shares: [makeShare(id: "1", storage: "machine"), makeShare(id: "2", storage: "cloud")])
        XCTAssertEqual(one.lines.map(\.text), ["1 link on this Mac stops answering until you start again", "1 cloud and member link keeps working"])
        let none = Impact.stopServing(host: "h", shares: [])
        XCTAssertEqual(none.lines.map(\.kind), [.stops, .keeps], "no rows still names both effects")
    }

    func testPauseCountsTheMembersMachineLinks() {
        let rows = [
            makeShare(id: "1", storage: "machine", by: "An", origin: "m-an-1a2b3c4d"),
            makeShare(id: "2", storage: "machine", by: "An", origin: "m-an-1a2b3c4d"),
            makeShare(id: "3", storage: "machine", by: "Dung", origin: "m-dung-5e6f7a8b"),
            makeShare(id: "4", storage: "cloud", by: "An"),
            makeShare(id: "5", storage: "machine"),
        ]
        let sheet = Impact.pause(member: "An", shares: rows)
        XCTAssertEqual(sheet.title, "Pause An?")
        XCTAssertEqual(sheet.lines, [
            ImpactLine(.stops, "2 links on their computer answer \"paused\" until you resume"),
            ImpactLine(.stops, "An cannot add links while paused"),
            ImpactLine(.keeps, "Their 1 link in the cloud keeps working"),
        ])
        XCTAssertFalse(sheet.destructive)
    }

    func testRemoveMemberAndRollBackSheets() {
        let remove = Impact.removeMember(member: "An", shares: [makeShare(id: "1", storage: "machine", origin: "m-an-1a2b3c4d")])
        XCTAssertEqual(remove.title, "Remove An?")
        XCTAssertTrue(remove.destructive)
        XCTAssertEqual(remove.lines.first, ImpactLine(.stops, "1 link on their computer stop answering now"))
        let roll = Impact.rollBack(what: "cloud storage", command: "share setup s.d.foundation --no-r2")
        XCTAssertEqual(roll.body, "Runs \"share setup s.d.foundation --no-r2\". The last step is undone and the earlier ones stay as they were.")
    }

    func testTheAskedKeyReachesTheChildEnvironmentOnly() {
        let key = "ask-once-" + String(repeating: "Qq7", count: 12)
        let command = AskedKeyCommand(argv: ["--profile", "console", "setup", "s.example.com"], variable: KeyKind.admin.environmentName, key: key)
        XCTAssertEqual(command.environment, ["CLOUDFLARE_API_TOKEN": key])
        XCTAssertFalse(command.argv.joined(separator: " ").contains(key), "argv holds no token")
        let minter = AskedKeyCommand(argv: ["member", "add", "an"], variable: KeyKind.minter.environmentName, key: key)
        XCTAssertEqual(minter.environment.keys.sorted(), ["SHARE_MINTER_TOKEN"])
        // The app's own defaults hold nothing of it: nothing in Core writes a key.
        let suite = "sharebar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeySourceStore(defaults: defaults)
        store.save(.askEachTime, kind: .admin, profile: "console")
        GeneralPrefs(defaults: defaults).copyAfterSharing = false
        let dump = defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        XCTAssertFalse(dump.contains(key))
    }

    func testTheAskedKeyReachesTheSpawnedChildThroughItsEnvironment() async throws {
        let marker = try makeTempDir().appendingPathComponent("seen").path
        let script = try writeStubScript("#!/bin/bash\nprintf '%s|%s' \"${CLOUDFLARE_API_TOKEN:-none}\" \"$*\" > '\(marker)'\n")
        setenv("SHARE_BIN", script, 1)
        defer { unsetenv("SHARE_BIN") }
        let command = AskedKeyCommand(argv: ["setup", "s.example.com"], variable: "CLOUDFLARE_API_TOKEN", key: "k-123")
        let result = await command.spawn().result
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOfFile: marker, encoding: .utf8), "k-123|setup s.example.com")
    }

    func testEscNeverClosesProgress() {
        for kind in [SheetKind.add, .confirm, .refusal, .code, .invite, .askKey, .removeMember] {
            XCTAssertTrue(kind.escCloses, "\(kind)")
        }
        XCTAssertFalse(SheetKind.progress.escCloses)
    }

    func testInviteFormArgvAndValidation() {
        var form = InviteForm()
        XCTAssertFalse(form.isValid)
        XCTAssertNil(form.argv(profile: "console"))
        form.name = "linh"
        XCTAssertEqual(form.argv(profile: "console"), ["--profile", "console", "member", "add", "linh", "--machine", "--invite-ttl", "7d"])
        form.mode = .cloud
        form.ttlDays = 30
        XCTAssertEqual(form.argv(profile: "console")?.suffix(3), ["--cloud", "--invite-ttl", "30d"])
        form.name = "--evil"
        XCTAssertNil(form.argv(profile: "console"))
        form.name = "a b"
        XCTAssertFalse(form.isValid)
        form.name = "linh"
        form.ttlDays = 3
        XCTAssertNil(form.argv(profile: "console"))
    }

    func testCodeSheetShowsTheCodeOnceWithItsCopy() {
        let invite = CodeSheet(member: "linh", code: "SHR-7Q4K-M2XD-9PLA-3VTB", rotate: false, ttlDays: 7)
        XCTAssertEqual(invite.title, "Invite code for linh")
        XCTAssertEqual(invite.body, "Send this to linh. It works once, for 7 days.")
        XCTAssertEqual(invite.note, "Share Bar shows the code only now. If it is lost, send a new one.")
        XCTAssertEqual(CodeSheet(member: "linh", code: "c", rotate: false, ttlDays: 1).body, "Send this to linh. It works once, for 1 day.")
        XCTAssertEqual(CodeSheet(member: "linh", code: "c", rotate: true, ttlDays: 7).title, "New keys for linh")
    }

    // MARK: 4b18

    func testProgressSheetFollowsProgressLines() throws {
        var run = FlowRun(kind: .join, title: "Joining s.console.so")
        XCTAssertEqual(run.steps.count, 6)
        XCTAssertEqual(run.mark(of: 0), .now)
        var stream = ProgressStream()
        let chunk1 = "{\"progress\":{\"verb\":\"join\",\"step\":1,\"of\":6,\"name\":\"redeem\"}}\n{\"progress\":{\"verb\":\"join\",\"ste"
        for p in stream.feed(chunk1) { run.apply(p) }
        XCTAssertEqual(run.step, 1)
        let chunk2 = "p\":4,\"of\":6,\"name\":\"service\"}}\nnoise\n"
        for p in stream.feed(chunk2) { run.apply(p) }
        XCTAssertEqual(run.step, 4)
        XCTAssertEqual([0, 1, 2, 3, 4, 5].map { run.mark(of: $0) }, [.done, .done, .done, .now, .pending, .pending])
        XCTAssertEqual(run.title(of: 3), "Start the server on this Mac")
        XCTAssertEqual(run.statusLine, "Step 4 of 6. Stopping keeps your place; Resume continues from this step.")
        // A line of another verb is not this run's.
        run.apply(Progress(verb: "setup-r2", step: 6, of: 16, name: "snapshot"))
        XCTAssertEqual(run.step, 4)
        // A CLI that reports another total shows the names it printed, never a wrong table.
        var odd = FlowRun(kind: .setupMembers, title: "t")
        odd.apply(Progress(verb: "setup-members", step: 2, of: 7, name: "carry"))
        XCTAssertEqual(odd.steps.count, 7)
        XCTAssertEqual(odd.title(of: 1), "carry", "an unknown step name falls back to the raw name")
        XCTAssertEqual(odd.title(of: 0), "Step 1")
        // The copy table covers every journal name of the four verbs.
        for kind in [FlowKind.join, .setupTunnel, .setupR2, .setupMembers] {
            for name in kind.stepNames {
                XCTAssertNotEqual(StepCopy.title(verb: kind.rawValue, name: name), name, "\(kind.rawValue) \(name) has copy")
            }
        }
    }

    func testAFinishedRunMarksEveryStepDone() {
        var run = FlowRun(kind: .setupMembers, title: "t")
        run.apply(Progress(verb: "setup-members", step: 5, of: 5, name: "release"))
        run.exited(status: 0, stderr: "")
        XCTAssertEqual(run.phase, .done)
        XCTAssertEqual((0..<5).map { run.mark(of: $0) }, Array(repeating: FlowRun.StepMark.done, count: 5))
    }

    func testAFailedRunKeepsTheCLISentenceAndItsNextCommand() {
        var run = FlowRun(kind: .join, title: "t")
        run.apply(Progress(verb: "join", step: 1, of: 6, name: "redeem"))
        run.exited(status: 1, stderr: "share: the code was already used\n{\"error\":{\"code\":\"invite_unknown_or_used\",\"message\":\"the code was already used\",\"next\":\"ask your admin for a new code\"}}\n")
        XCTAssertEqual(run.phase, .failed(sentence: "the code was already used", next: "ask your admin for a new code"))
        var plain = FlowRun(kind: .join, title: "t")
        plain.exited(status: 2, stderr: "share: no route\n")
        XCTAssertEqual(plain.phase, .failed(sentence: "no route", next: nil))
    }

    func testStopSendsSIGTERMAndLeavesTheCallout() async throws {
        // A journaled verb that prints four steps, then waits; SIGTERM ends it as the real CLI does.
        let log = try makeTempDir().appendingPathComponent("term").path
        let script = try writeStubScript("""
        #!/bin/bash
        trap 'echo termed > "\(log)"; exit 143' TERM
        for n in 1 2 3 4; do
          echo "{\\"progress\\":{\\"verb\\":\\"join\\",\\"step\\":$n,\\"of\\":6,\\"name\\":\\"s$n\\"}}" >&2
        done
        while true; do sleep 0.1; done
        """)
        setenv("SHARE_BIN", script, 1)
        defer { unsetenv("SHARE_BIN") }
        let changed = expectation(description: "stopped")
        changed.assertForOverFulfill = false
        let runner = FlowRunner(argv: ["--profile", "console", "join", "s.console.so", "SHR-CODE"], kind: .join, title: "Joining s.console.so") { run in
            if case .stopped = run.phase { changed.fulfill() }
        }
        runner.start()
        for _ in 0..<100 where runner.run.step < 4 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(runner.run.step, 4)
        runner.stop()
        await fulfillment(of: [changed], timeout: 10)
        XCTAssertEqual(runner.run.phase, .stopped(at: 4))
        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "termed")

        // The journal keeps the step: the next `profiles` read carries the dead op, and the tenant shows the callout.
        let op = OpInfo(verb: "join", step: 4, of: 6, name: "service", alive: false, rerun: "share join", rerunArgv: ["--profile", "console", "join"],
                        rollback: "share leave --local", rollbackArgv: ["--profile", "console", "leave", "--local"])
        let entry = makeEntry(name: "console", state: makeSnapshot(host: "s.console.so", role: "member", tier: "t2",
                                                                 serve: ServeInfo(phase: "stopped", reason: nil), ops: [op]))
        let detail = try XCTUnwrap(TenantDetail(entry: entry))
        XCTAssertEqual(detail.callout?.title, "Joining stopped at step 4 of 6")
        XCTAssertEqual(detail.listLine, "Member · Interrupted")
    }

    func testResumeRunsRerunAndRollBackRunsRollback() {
        let join = OpInfo(verb: "join", step: 4, of: 6, name: "service", alive: false, rerun: "share join", rerunArgv: ["join"],
                          rollback: "share leave --local", rollbackArgv: ["leave", "--local"])
        XCTAssertEqual(JournalRun.argv(op: join, kind: .rerun, profile: "console"), ["--profile", "console", "join"])
        XCTAssertEqual(JournalRun.argv(op: join, kind: .rollback, profile: "console"), ["--profile", "console", "leave", "--local"])
        let r2 = OpInfo(verb: "setup-r2", step: 13, of: 16, name: "route", alive: false, rerun: "r",
                        rerunArgv: ["setup", "s.d.foundation", "--r2", "--bucket", "share-s-d-foundation"], rollback: "b", rollbackArgv: ["setup", "s.d.foundation", "--no-r2"])
        XCTAssertEqual(JournalRun.argv(op: r2, kind: .rerun, profile: "dfoundation")?.suffix(5), ["s.d.foundation", "--r2", "--bucket", "share-s-d-foundation"][...].map { $0 }.suffix(5))
        XCTAssertEqual(JournalRun.argv(op: r2, kind: .rollback, profile: "dfoundation")?.suffix(2), ["s.d.foundation", "--no-r2"])
    }

    func testFlowArgvAndNaming() {
        XCTAssertEqual(ProfileName.slug(host: "s.example.com"), "s-example-com")
        XCTAssertEqual(ProfileName.bucket(host: "s.example.com"), "share-s-example-com")
        XCTAssertEqual(FlowArgv.join(host: "s.console.so", code: "SHR-7Q4K-M2XD-9PLA-3VTB"),
                       ["--profile", "s-console-so", "join", "s.console.so", "SHR-7Q4K-M2XD-9PLA-3VTB"])
        XCTAssertNil(FlowArgv.join(host: "not a host", code: "SHR-1"))
        XCTAssertNil(FlowArgv.join(host: "s.console.so", code: "-evil"))
        XCTAssertNil(FlowArgv.join(host: "s.console.so", code: ""))
        XCTAssertEqual(FlowArgv.setup(host: "s.example.com"), ["--profile", "s-example-com", "setup", "s.example.com"])
        XCTAssertNil(FlowArgv.setup(host: "Bad Host"))
        XCTAssertEqual(FlowArgv.turnOnCloud(profile: "console", host: "s.console.so"),
                       ["--profile", "console", "setup", "s.console.so", "--r2", "--bucket", "share-s-console-so"])
        XCTAssertEqual(FlowArgv.turnOnMembers(profile: "console", host: "s.console.so")?.last, "--members")
        // The profile name is always one the CLI's own pattern accepts.
        XCTAssertTrue(JournalRun.isProfileName(ProfileName.slug(host: "a-very-long-hostname-for-a-tenant.example.com")))
        XCTAssertLessThanOrEqual(ProfileName.slug(host: String(repeating: "a.", count: 40) + "com").count, 32)
    }

    func testAPastedJoinLineFillsBothFields() {
        let pasted = JoinInput.parse(codeField: "share join s.console.so SHR-7Q4K-M2XD-9PLA-3VTB\n", hostField: "")
        XCTAssertEqual(pasted.host, "s.console.so")
        XCTAssertEqual(pasted.code, "SHR-7Q4K-M2XD-9PLA-3VTB")
        let typed = JoinInput.parse(codeField: " SHR-1 ", hostField: " s.console.so ")
        XCTAssertEqual(typed.host, "s.console.so")
        XCTAssertEqual(typed.code, "SHR-1")
    }
}
