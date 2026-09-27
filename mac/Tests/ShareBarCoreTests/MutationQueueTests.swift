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
}
