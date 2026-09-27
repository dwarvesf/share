import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import ShareBarCore

/// Reproduces the real end-to-end hang: `share stop` (and anything else `CLI.run`/
/// `spawnCancellable` spawns) never received SIGTERM when the spawning thread had it
/// blocked, because `posix_spawn` otherwise carries the calling thread's signal mask into
/// the child. GCD/Swift-concurrency threads commonly block SIGTERM, so this blocks it
/// explicitly on the test's own thread to make the repro deterministic rather than relying
/// on whichever thread XCTest happens to run on.
final class SpawnSignalMaskTests: XCTestCase {
    func testSpawnedChildReceivesSIGTERMEvenWhenTheSpawningThreadBlocksIt() throws {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        var previousMask = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previousMask)
        defer { pthread_sigmask(SIG_SETMASK, &previousMask, nil) }

        let handle = try Spawn.start(
            executablePath: "/bin/sh",
            argv: ["-c", "trap 'exit 7' TERM; while :; do sleep 0.1; done"],
            environment: [:]
        )
        defer {
            close(handle.stdoutFD)
            close(handle.stderrFD)
        }

        usleep(100_000) // let the trap install before signaling
        XCTAssertEqual(kill(handle.pid, SIGTERM), 0)

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(2)
        var reaped = false
        while Date() < deadline {
            if waitpid(handle.pid, &status, WNOHANG) == handle.pid {
                reaped = true
                break
            }
            usleep(20_000)
        }

        XCTAssertTrue(reaped, "child was not reaped within 2s; it never saw the SIGTERM")
        XCTAssertEqual(Spawn.exitStatus(fromWaitStatus: status), 7)
    }
}
