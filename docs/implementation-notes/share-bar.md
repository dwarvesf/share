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

## Review round (code lens and advisor)

Folded: the argv shape check of `JournalRun` (a flag allowlist per journal verb, `rm` only for the add's own id, `OpInfo.id` and `aliveKnown` decoded so an op with unreadable liveness never runs, `\z` in the profile pattern); an `expires` far in the past no longer traps (`secondsLeft`); `MemberRecord.isRunning` uses the CLI's own status list; `expect-argv` matches a whole logged call and refuses an empty argument; `shots.sh all` runs a `negative` step file and requires it to fail with no image; `compat-check.sh` gained a live leg (the checked-out CLI's `profiles --json` and `state` from a throwaway HOME) and takes extra fixture files; the full `Snapshot` field checks in `GroundworkCompatTests` are back.

- D15. SB-05 "attention line": a dead op is a distinct disabled line under its profile title with the `rerun` display string as text. It does not move the header to attention; the issues list that does so is a later task of the redesign.
- D16. `JournalRun` is built now and not yet called by the menu: the Done line of this sub-goal names it, and G11b says the menu only shows the string. Its first caller is the Resume and Roll back buttons of a later task.
- D17. Not attempted: the "drag from Finder" step of TASK-4b4. A drag needs a Finder window and a drop target; today's `NSMenu` has no drop target. The step arrives with the popover shell and its drop state. The proof index `docs/verification/multi-member.md` named by the spec is left to the sub-goal that owns the popover screens; this run's proof is `docs/verification/share-bar/foundations.md`.
- D18. A panel's button can drop a click while the app is not active (the remove confirm sits on another display of the Mini). `axdrive click` sends the real click first and, if an `AXButton` is still on screen half a second later, performs its `AXPress`. The status item and menu rows only ever take the real click.

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
