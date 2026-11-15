# Proof: popover design parity

Parity images and per-gap samples: `docs/verification/share-bar/popover-parity/README.md`.

## Recorded run

Command: `swift build --package-path mac`
Exit: 0
Output: Build complete
Verdict: PASS

Command: `swift test --package-path mac`
Exit: 0
Output: Executed 320 tests, with 0 failures (0 unexpected); RowAgeTests 4 of 4
Verdict: PASS

Command: `bash mac/build.sh 0.0.0`
Exit: 0
Output: Share-Bar-0.0.0.zip written
Verdict: PASS

Command: `bash mac/compat-check.sh v0.9.0`
Exit: 0
Output: every fixture and the live CLI decode
Verdict: PASS

Command: `bash mac/Tests/fixtures/popover/parity-shots.sh docs/verification/share-bar/popover-parity/parity/after`
Exit: 0
Output: wrote calm and menu, light and dark
Verdict: PASS

Command: `parity-sample <design> 1250 841 680 528 <build> <composite> light|dark`
Exit: 0
Output: every sample within tolerance (6 steps, the deliberate placeholder 16); placeholder 15 light, 7 dark
Verdict: PASS

## Not attempted

- A capture of the real `NSPopover` over a light and a dark desktop: the harness takes no pointer input and a window capture of the vibrancy reads black here. The root fill is opaque, so the body does not depend on the desktop; the native arrow is unsampled.
- `share state` does not print `added`, so the age column is empty on a live tenant until `bin/share` emits it (outside this change's touches).

- Review: kit:advisor critique folded: stray capture files moved out, age gets a VoiceOver label, menu highlight resets per row. Real-popover sizing stays unproven (listed under Not attempted).
