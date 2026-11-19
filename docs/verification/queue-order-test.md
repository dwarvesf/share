# Verification -- queue-order-test

`testTwoQueuedVerbsRunStrictlyInOrder` failed on a main CI run (`XCTAssertEqual failed: ("B...`). It started two `async let` calls, and Swift does not fix which one reaches the queue first. The test now queues the second verb only after the first has started. The queue code is unchanged.

## Green run
```
Command: swift test --package-path mac --filter 'MutationQueueTests/testTwoQueuedVerbsRunStrictlyInOrder', 8 times
Exit: 0
Output:
8 of 8: Executed 1 test, with 0 failures (0 unexpected)
Verdict: PASS
```
`swift test --package-path mac --filter MutationQueueTests`: Executed 6 tests, with 0 failures.

## Negative control
```
Command: MutationQueue.run no longer awaits the previous task (`_ = previous`), then the same test
Exit: 1
Output:
MutationQueueTests.swift:28: error: -[ShareBarCoreTests.MutationQueueTests testTwoQueuedVerbsRunS...
Executed 1 test, with 1 failure (0 unexpected)
Verdict: PASS (the test still catches a queue that does not serialize; the source was restored)
```

## Not proven
- Slow hosted macOS runners: the wait for the first verb's start allows 5 s.
