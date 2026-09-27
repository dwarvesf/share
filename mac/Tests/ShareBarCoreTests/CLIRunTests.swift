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

    func testConcurrentStateCallsShareOneInFlightProcess() async throws {
        let dir = try makeTempDir()
        let counterPath = dir.appendingPathComponent("count.log").path
        let script = """
        #!/bin/sh
        echo x >> "\(counterPath)"
        sleep 0.3
        echo '{}'
        """
        setenv("SHARE_BIN", try writeStubScript(script), 1)

        async let a = CLI.state(timeout: 5)
        async let b = CLI.state(timeout: 5)
        async let c = CLI.state(timeout: 5)
        _ = await (a, b, c)

        let contents = try String(contentsOfFile: counterPath, encoding: .utf8)
        let invocations = contents.split(separator: "\n")
        XCTAssertEqual(invocations.count, 1, "expected exactly one spawn, got: \(contents.debugDescription)")
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
