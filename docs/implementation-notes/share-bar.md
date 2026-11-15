# Implementation notes: Share Bar foundations

Delta from SPEC-010 G11a to G11c and SPEC-009 TASK-4b1 to TASK-4b5. The spec rows are not restated.

## Starting point

A serial run of this sub-goal left a WIP commit (decoders, derivation, reducer, tokens, state words, journal run). It built and passed 232 tests on main at f8042fa. This run kept it, checked it against every AC row, and added what it lacked: `mac/compat-check.sh`, the fake CLI, `mac/shots.sh`, the AX driver, the proof.

## Decisions the spec left open

- D1. The harness drives the app through a small Swift tool (`mac/Tests/fixtures/ax/axdrive.swift`, compiled by `shots.sh` with `swiftc`), not `osascript`. It needs only the Accessibility grant of the parent process; `System Events` would add an Automation prompt.
- D2. A click is a real `CGEvent` mouse click at the centre of the control's AX frame, found by walking the app's own AX tree. Nothing sets state in the app. Menu items of an open `NSMenu` take real clicks the same way.
- D3. Dark mode is the argument `-AppleInterfaceStyle Dark` on the app's own launch line, so the machine's appearance never changes.
- D4. The app under test runs from a throwaway bundle (`mac/build/shots/Share Bar.app`) with its own bundle id, so it never shares `UserDefaults` or a status item slot with an installed Share Bar.
- D5. Images land in a temp directory and move into `docs/verification/share-bar/` only after the last step passes. A failing step leaves no image (the negative control).
- D6. `open-popover` captures today's `NSMenu` (the popover shell is TASK-4b6, a later sub-goal). The name stays, because the step file names the state a user reaches by clicking the status item.
- D7. The fake CLI keeps one writable copy of the scenario per run, so a `rm <id>` removes the row on the next `profiles --json`.

## Open questions

- None blocking. The `can[]` set in `member-ls.json` mirrors `mb_can_list`; a drift there shows up in the SG-05 suite, not here.
