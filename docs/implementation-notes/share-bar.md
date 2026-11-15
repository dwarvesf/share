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

## Decisions added in the wave run

- D8. The `light` capture reads grey: `screencapture -l` takes the one window, and a translucent `NSMenu` has no backdrop to blur. The dark capture is true to the menu. Kept as is; the spec names `-l`.
- D9. Dark comes from a DEBUG-only default, `-ShareBarShotsAppearance dark`, that sets `NSApp.appearance` and the menu's appearance. D3's `-AppleInterfaceStyle Dark` did not change the status item menu (both images were byte-identical). A release build never compiles the read.
- D10. A collapsed menu bar manager (Hidden Bar here) pushes every third-party status item out of the bar, and AppKit then reports none (`AXExtrasMenuBar` returns no value, for the installed Share Bar and Control Center too). `shots.sh` expands Hidden Bar once when the status item is missing, before the launch check and before each `click status-item`, and fails with the control's name if that does not help. Without Hidden Bar the guard does nothing.
- D11. The fake CLI answers the fixtures' `expires` value `4102444800` as 14 days from now, so a capture reads `14d left` and not `26709d left`. A real past epoch (`1700000000`) stays expired.
- D12. `compat-check.sh` decodes a `profiles --json` fixture with `ProfilesSnapshot.from` and a single `state` fixture with `Snapshot`, then fails on any profile whose `Health.of` is `.error`. The `cli-old` scenario (a TSV listing) is skipped on purpose: it stands for a CLI older than the tag.
- D13. `JournalRun` tests cover SPEC-010 DEC-21: the allowed verb per journal verb, the profile check, argument limits, a stand-in CLI that logs one line per argument (a hostile argument arrives as one literal argument and the marker file never appears).
- D14. The serial run had no tests for SB-06 and SB-07. `MutationErrorJSONTests` adds them.

## AC map

| Row | Test |
|---|---|
| G11a SB-01 | `DerivationTests.testOldFixturesDeriveExactlyAsToday`, `StateMappingTests` unchanged |
| G11a SB-02 | `DerivationTests.testEveryServePhaseReadsItsCopy`, `testAnUnknownServePhaseFallsBackToTodaysDerivation` |
| G11a SB-03 | `DerivationTests.testAMigratedRoleReadsMovedToAnotherMachineAndStaysNeutral` |
| G11b SB-04 | `DerivationTests` (expired and unknown `link_state` rows), `TokensAndStateWordTests.testLinkStateRulesMatchTheSpecTable` |
| G11b SB-05 | `DerivationTests.testAnAliveOpShowsWorkingAndADeadOneAnAttentionLineWithTheRerunTextOnly`, `JournalRunTests` |
| G11c SB-06, SB-07 | `MutationErrorJSONTests` |
| 4b1 decode rows | `NewKeyDecodeTests` (present, absent, unknown extra, member ls with can[], progress line); `mac/compat-check.sh v0.9.0` |
| 4b2 | `DerivationTests` (serve phase, role, ineligible reason, meta line by link state, no `link_state`) |
| 4b3 | `PopoverStateTests` (one row per rule named in the AC, plus the table-equality row) |
| 4b4 | `mac/shots.sh calm open-popover`, `missing-control` (negative), `remove-link` (`rm <id>` in `argv.log`) |
| 4b5 | `TokensAndStateWordTests` (state words, dark overrides semantic only, contrast math) |
