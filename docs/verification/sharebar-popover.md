# Proof: Share Bar popover A

Screens and the Mobbin comparison: `docs/verification/share-bar/popover-a/README.md`.

## Recorded run

Command: `swift test --package-path mac`
Exit: 0
Output: Executed 316 tests, with 0 failures (0 unexpected)
Verdict: PASS

Command: `bash mac/build.sh 0.0.0`
Exit: 0
Output: build completed, no error
Verdict: PASS

Command: `bash mac/compat-check.sh v0.9.0`
Exit: 0
Output: v0.9.0 decoder accepts the fixtures and the live CLI
Verdict: PASS

Command: `bash mac/Tests/fixtures/popover/run-shots.sh`
Exit: 0
Output: 40 images written to docs/verification/share-bar/popover-a/; undone Remove left 0 rm, completed Remove left 1 rm
Verdict: PASS

Command: `SHOTS_OUT=<existing dir> bash mac/shots.sh all`
Exit: 0
Output: foundations step files drive the popover; remove-link left `rm 4f9ff2` in argv.log
Verdict: PASS

UAT: exercised in the app bundle against the fake CLI on this Mac and accepted. Nothing deployed; no Worker, setup or persistent state touched, so no rollback section.
