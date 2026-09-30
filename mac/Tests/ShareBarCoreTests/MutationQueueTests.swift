import XCTest
@testable import ShareBarCore

final class MutationQueueTests: XCTestCase {
    override func tearDown() {
        unsetenv("SHARE_BIN")
        super.tearDown()
    }

    func testTwoQueuedVerbsRunStrictlyInOrder() async throws {
        setenv("SHARE_BIN", "/bin/sh", 1)
        let dir = try makeTempDir()
        let logPath = dir.appendingPathComponent("order.log").path
        let queue = MutationQueue()

        // The first verb sleeps before writing; if the queue did not serialize, the
        // second (instant) write would land first.
        async let first = queue.run(["-c", "sleep 0.3; echo A >> \"\(logPath)\""])
        async let second = queue.run(["-c", "echo B >> \"\(logPath)\""])
        _ = await (first, second)

        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertEqual(contents, "A\nB\n")
    }

    func testQueueReturnsEachCallsOwnResult() async throws {
        setenv("SHARE_BIN", "/bin/sh", 1)
        let queue = MutationQueue()

        async let a = queue.run(["-c", "echo A"])
        async let b = queue.run(["-c", "echo B"])
        let (resultA, resultB) = await (a, b)

        XCTAssertEqual(resultA.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "A")
        XCTAssertEqual(resultB.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "B")
    }

    /// Stop Waiting: `cancel(job:)` with the token of the running verb TERMs its process
    /// group while it's still in flight.
    func testCancelJobTermsTheRunningVerbsProcessGroup() async throws {
        setenv("SHARE_BIN", "/bin/sh", 1)
        let queue = MutationQueue()

        async let result = queue.run(["-c", "sleep 30 & echo $!; wait"])
        // Poll for the job to actually be running; a bare sleep could lose the race.
        var token: JobToken?
        for _ in 0..<100 where token == nil {
            token = await queue.currentJob()
            if token == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        guard let token else { return XCTFail("the verb never reached the running state") }
        await queue.cancel(job: token)

        let finished = await result
        XCTAssertNotEqual(finished.status, 0, "TERM should end the sleep, not let it run to completion")
    }

    /// A stale token (the job it named already ended) cancels nothing: the queued verb
    /// that follows runs to completion.
    func testStaleTokenNeverReachesTheNextJob() async throws {
        setenv("SHARE_BIN", "/bin/sh", 1)
        let queue = MutationQueue()

        async let first = queue.run(["-c", "sleep 0.2; echo one"])
        var token: JobToken?
        for _ in 0..<100 where token == nil {
            token = await queue.currentJob()
            if token == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        guard let token else { return XCTFail("the verb never reached the running state") }
        async let second = queue.run(["-c", "echo two"])

        _ = await first // let the first job end on its own
        await queue.cancel(job: token) // the confirm answered too late: a no-op

        let finished = await second
        XCTAssertEqual(finished.status, 0)
        XCTAssertEqual(finished.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "two")
    }

    /// Cancelling a token while nothing is running is a harmless no-op.
    func testCancelJobWithNothingRunningIsANoOp() async throws {
        let queue = MutationQueue()
        await queue.cancel(job: JobToken()) // must not crash or hang
    }

    /// `currentJob()` is nil between jobs and non-nil while one runs.
    func testCurrentJobTracksTheRunningVerb() async throws {
        setenv("SHARE_BIN", "/bin/sh", 1)
        let queue = MutationQueue()

        let idle = await queue.currentJob()
        XCTAssertNil(idle)
        async let result = queue.run(["-c", "sleep 0.3; echo done"])
        var token: JobToken?
        for _ in 0..<100 where token == nil {
            token = await queue.currentJob()
            if token == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertNotNil(token)
        _ = await result
        let after = await queue.currentJob()
        XCTAssertNil(after)
    }
}
