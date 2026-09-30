import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import ShareBarCore

final class CLIRunTests: XCTestCase {
    override func tearDown() {
        unsetenv("SHARE_BIN")
        super.tearDown()
    }

    func testLargeStdoutDrainsWithoutDeadlock() async throws {
        // A pipe's kernel buffer is far smaller than 200KB, so this only completes if both
        // pipes are drained continuously while the process runs, not just after it exits.
        let script = "#!/bin/sh\nyes A | head -c 200000\n"
        setenv("SHARE_BIN", try writeStubScript(script), 1)

        let result = await CLI.run([], timeout: 10)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.utf8.count, 200_000)
        XCTAssertFalse(result.timedOut)
    }

    func testTimeoutKillsTheWholeProcessGroupIncludingAGrandchild() async throws {
        setenv("SHARE_BIN", "/bin/sh", 1)

        let result = await CLI.run(["-c", "sleep 30 & echo $!; wait"], timeout: 0.3)

        XCTAssertTrue(result.timedOut)
        let pidLine = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let grandchildPid = pid_t(pidLine) else {
            XCTFail("expected the backgrounded sleep's pid on stdout, got \(result.stdout.debugDescription)")
            return
        }
        // A brief allowance for the kernel to finish reaping after the KILL.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(kill(grandchildPid, 0), -1, "grandchild pid \(grandchildPid) is still alive")
        XCTAssertEqual(errno, ESRCH)
    }

    func testNilTimeoutIsNeverKilled() async throws {
        let script = "#!/bin/sh\nsleep 0.5\necho done\n"
        setenv("SHARE_BIN", try writeStubScript(script), 1)

        let result = await CLI.run([], timeout: nil)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    func testProfilesRunsProfilesJson() async throws {
        let script = "#!/bin/sh\necho \"$@\"\n"
        setenv("SHARE_BIN", try writeStubScript(script), 1)

        let result = await CLI.profiles(timeout: 5)

        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "profiles --json")
    }

    func testConcurrentProfilesCallsShareOneInFlightProcess() async throws {
        let dir = try makeTempDir()
        let counterPath = dir.appendingPathComponent("count.log").path
        let script = """
        #!/bin/sh
        echo x >> "\(counterPath)"
        sleep 0.3
        echo '{}'
        """
        setenv("SHARE_BIN", try writeStubScript(script), 1)

        async let a = CLI.profiles(timeout: 5)
        async let b = CLI.profiles(timeout: 5)
        async let c = CLI.profiles(timeout: 5)
        _ = await (a, b, c)

        let contents = try String(contentsOfFile: counterPath, encoding: .utf8)
        let invocations = contents.split(separator: "\n")
        XCTAssertEqual(invocations.count, 1, "expected exactly one spawn, got: \(contents.debugDescription)")
    }

    /// A fresh caller never joins a run that started before it: it waits for that run to
    /// end, then spawns a new one whose result it keeps.
    func testFreshProfilesCallStartsANewRunAfterTheInFlightOne() async throws {
        let dir = try makeTempDir()
        let spawnsPath = dir.appendingPathComponent("spawns.log").path
        let script = """
        #!/bin/sh
        n=$(cat "\(dir.path)/count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "\(dir.path)/count"
        echo "start $n" >> "\(spawnsPath)"
        sleep 0.4
        echo "end $n" >> "\(spawnsPath)"
        echo "run-$n"
        """
        setenv("SHARE_BIN", try writeStubScript(script), 1)

        let firstTask = Task { await CLI.profiles(timeout: 5) }
        // Poll for the run to actually be in flight; a plain sleep could lose the race on
        // a busy machine.
        for _ in 0..<100 {
            if (try? String(contentsOfFile: spawnsPath))?.contains("start 1") == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let fresh = await CLI.profiles(fresh: true, timeout: 5)
        let first = await firstTask.value

        let log = try String(contentsOfFile: spawnsPath, encoding: .utf8)
        XCTAssertEqual(log, "start 1\nend 1\nstart 2\nend 2\n", "the fresh call's run starts only after the in-flight one ends")
        XCTAssertEqual(first.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "run-1")
        XCTAssertEqual(fresh.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "run-2")
    }

    /// A plain caller that arrives while a fresh run is in flight joins it.
    func testPlainCallJoinsAFreshRunAlreadyInFlight() async throws {
        let dir = try makeTempDir()
        let counterPath = dir.appendingPathComponent("count.log").path
        let script = """
        #!/bin/sh
        echo x >> "\(counterPath)"
        sleep 0.3
        echo '{}'
        """
        setenv("SHARE_BIN", try writeStubScript(script), 1)

        let freshTask = Task { await CLI.profiles(fresh: true, timeout: 5) }
        try await Task.sleep(nanoseconds: 100_000_000) // the fresh run is the one in flight
        let plain = await CLI.profiles(timeout: 5)
        _ = await freshTask.value
        _ = plain

        let contents = try String(contentsOfFile: counterPath, encoding: .utf8)
        XCTAssertEqual(contents.split(separator: "\n").count, 1, "the plain caller joins the fresh run: \(contents.debugDescription)")
    }

    /// `verb=` in the log names the verb, never `--profile`.
    func testVerbForLogSkipsTheProfilePrefix() {
        XCTAssertEqual(CLI.verbForLog(["--profile", "dfoundation", "rm", "abc123"]), "rm")
        XCTAssertEqual(CLI.verbForLog(["--profile", "default", "start"]), "start")
        XCTAssertEqual(CLI.verbForLog(["profiles", "--json"]), "profiles")
        XCTAssertEqual(CLI.verbForLog([]), "")
    }

    /// Every child's environment drops the location overrides and the profile selection;
    /// SHARE_BIN, PATH, LANG and SHARE_CLIPBOARD rules from the menu-bar spec hold.
    func testChildEnvironmentStripsOverridesAndKeepsTheRest() {
        let env = CLI.childEnvironment(
            cliDirectory: "/cli",
            inherited: [
                "HOME": "/h",
                "PATH": "/custom/bin",
                "LANG": "C.UTF-8",
                "SHARE_BIN": "/bin/share",
                "SHARE_ROOT": "/r",
                "SHARE_CONFIG_DIR": "/c",
                "SHARE_PORT": "1",
                "SHARE_HOSTNAME": "h",
                "SHARE_HOSTS": "x",
                "SHARE_SERVICE_LABEL": "l",
                "SHARE_PROFILE": "p",
                "SHARE_CLIPBOARD": "1",
            ]
        )

        for key in CLI.strippedEnvironmentKeys {
            XCTAssertNil(env[key], "\(key) must not reach the child")
        }
        XCTAssertEqual(env["SHARE_BIN"], "/bin/share")
        XCTAssertEqual(env["HOME"], "/h")
        // PATH is the cli directory plus the fixed fallback list; the inherited PATH is
        // replaced, never inherited (a test harness PATH must not leak into the child).
        XCTAssertEqual(env["PATH"], "/cli:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/h/.local/bin:/opt/local/bin:/h/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(env["LANG"], "C.UTF-8")
        XCTAssertEqual(env["SHARE_CLIPBOARD"], "0")
    }

    func testChildEnvironmentBuildsTheFallbackPathAndFillsLang() {
        let env = CLI.childEnvironment(cliDirectory: "/cli", inherited: ["HOME": "/h"])

        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["PATH"], "/cli:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/h/.local/bin:/opt/local/bin:/h/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testSpawnCancellableStreamsOutputAndCancelKillsTheGroup() async throws {
        setenv("SHARE_BIN", "/bin/sh", 1)
        let collected = OutputBox()

        let job = CLI.spawnCancellable(["-c", "sleep 30 & echo $!; wait"]) { chunk in
            collected.append(chunk)
        }
        try await Task.sleep(nanoseconds: 200_000_000) // let the pid line arrive
        job.cancel()
        _ = await job.result
        try await Task.sleep(nanoseconds: 500_000_000) // allow the KILL to be reaped

        let output = collected.value
        let pidLine = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let grandchildPid = pid_t(pidLine) else {
            XCTFail("expected the backgrounded sleep's pid streamed via onOutput, got \(output.debugDescription)")
            return
        }
        XCTAssertEqual(kill(grandchildPid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
