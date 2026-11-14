# SG-06 Share Bar foundations (SPEC-010 G11a G11b G11c, SPEC-009 TASK-4b1 to 4b5)
Model: sonnet
Effort: high
**Branch:** feat/sharebar-foundations
Design: bearing
Done-mode: proof
Wall budget: 480 min
Port base: 27000

## Done =
SPEC-010 G11a, G11b, G11c and SPEC-009 TASK-4b1 to 4b5 pass their AC. `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass. `bash mac/compat-check.sh v0.9.0` exits 0. Journal `rerun_argv`/`rollback_argv` are decoded and run by exec with no shell, after checking the verb and profile (SPEC-010 DEC-21). The fake CLI and `mac/shots.sh` exist; `bash mac/shots.sh calm open-popover` writes a light and a dark screenshot reached by a real click on the status item (Accessibility events, never by setting state), and its negative control (a step naming a missing control) fails with the control's name and writes no image. `member ls --json` and the progress line decode from fixtures built to the spec's shapes (TASK-1i may land in parallel in SG-05).

## Scope edges
`mac/` only, plus the proof and notes files. No change to `bin/share`.
If the Accessibility permission for the terminal is missing, try `tccutil`-free paths first (the harness already running under a granted parent); if still blocked, record the blocker and finish everything else.

## Proof
`docs/verification/share-bar/foundations.md` with the swift runs, compat-check and the screenshot paths.

## Touches
mac/**
docs/verification/share-bar/**
docs/implementation-notes/share-bar.md
