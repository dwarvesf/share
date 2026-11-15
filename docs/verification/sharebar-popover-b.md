# Verification: Share Bar popover B (SPEC-009 TASK-4b10 to TASK-4b13)

Change: drop-in publish with a progress row, drag out, Quick Look, the Control-Option-S hotkey. `mac/` only; nothing deployed.

## Recorded run

Command: swift build --package-path mac
Exit: 0
Output: Build complete! (0,43 secs)
Verdict: pass

Command: swift test --package-path mac
Exit: 0
Output: Executed 336 tests, with 0 failures (0 unexpected) in 6.501 (6.524) seconds
Verdict: pass. 16 new rows: PublishFlowTests (5), DragOutTests (5), QuickLookModelTests (2), HotkeyTests (4), plus the existing PopoverStateTests row for the hotkey from `issues`.

Command: swift test --package-path mac (after merging origin/main, which brought the Settings tasks)
Exit: 0
Output: Executed 378 tests, with 0 failures (0 unexpected) in 7.097 (7.132) seconds
Verdict: pass

Command: bash mac/build.sh 0.0.0
Exit: 0
Output: mac/build/Share-Bar-0.0.0.zip
Verdict: pass

Command: bash mac/compat-check.sh v0.9.0
Exit: 0
Output: ok   <tmp>/live/state.json (1 profile)
Verdict: pass

Command: /bin/bash -n bin/share
Exit: 0
Output: (none; the CLI is untouched by this change)
Verdict: pass

Command: swift test --package-path mac --filter HotkeyTests/testASecondRegistrationOfTheSameKeyReportsInUse (negative control, with `HotkeyCenter` made to report `registered` whatever the registrar answers)
Exit: 1
Output: HotkeyTests.swift:46: error: XCTAssertEqual failed: ("registered") is not equal to ("inUse") - the key is held: it reports in use
Verdict: red as required; the mutation was reverted and the same filter on the real code is green (4 tests, 0 failures).

Command: mac/Tests/fixtures/popover/popover-b-shots.sh docs/verification/share-bar/popover-b
Exit: 0
Output: 20 images (10 scenes, light and dark), no pointer, key or drag input; `publish-live` printed `argv.log: --profile default add <home>/Q4-plan.pdf`
Verdict: pass

Command: mac/Tests/fixtures/popover/popover-b-parity.sh docs/verification/share-bar/popover-b docs/verification/share-bar/popover-b/parity
Exit: 0
Output: 18 x `VERDICT: every sample within its allowance` (background, primary and secondary text, placeholder, separator, footer text, overlay and header colors; 6 steps, the placeholder 16)
Verdict: pass. The design render is beside the capture in `parity/*-parity.png`; samples in `parity/run.txt`; deviations in `share-bar/popover-b/README.md`.

Command: Mobbin MCP, three screen searches (upload progress, file preview modal, drop zone)
Exit: 0
Output: nine reference screens; the comparison per screen is `share-bar/popover-b/mobbin.md`
Verdict: no change followed

## AC map

| AC row | Test or capture |
|---|---|
| `progress lines move the publishing entry's step` | PublishFlowTests.testProgressLinesMoveThePublishingEntrysStep |
| `a drop with no tenant is refused with the first-run panel` | PublishFlowTests.testADropWithNoTenantIsRefusedWithTheFirstRunPanel |
| a drop leaves `add <path>` in `argv.log` | `publish-live` capture run (real drop path, fake CLI) |
| `the drag item carries the URL as url and text`, `expired and revoked do not drag`, `an internal drag never enters dropTarget` | DragOutTests |
| `preview source per row kind`, `close returns focus to the row id` | QuickLookModelTests |
| `the hotkey event from issues lands in list with search focused` | PopoverStateTests.testHotkeyFromIssuesLandsInListWithSearchFocused |
| a second registration of the same key reports in use | HotkeyTests (fake and real Carbon) |
| the nine named screens | `share-bar/popover-b/*.png`, light and dark |

## Review

Advisor (critique) and code-reviewer lenses ran on the frozen diff. Fixed: the hotkey ring without field focus, Quick Look dismissal and activation, duplicate dropped paths, a placeholder with no tenant, a stuck overlay after an unreadable drop, spliced progress output (now a scanner, not lines), a share name used as a path component, an unlocked probe flag, a stale focus after close, a drag over Quick Look. Open minor: Quick Look keys other than Space, Esc and Return are swallowed (no keyboard path to Open in browser).

## Not attempted

- A real Finder drag, a real ⌃⌥S from another app, a real Space on a focused row, a real drag into TextEdit (owner rule: no live input). The reducer rows, the Carbon registration test and the offscreen captures stand in; the TextEdit screen is not captured.
- Live tenants: the app was never pointed at a real tenant or Worker.

## Rollback

Persistent state: none written. The popover keeps `PopoverCurrentProfile`, `PopoverScope.<profile>` and `RecentLinkCount` in user defaults, unchanged by this change. Revert the three commits of the PR; the classic menu (`LegacyMenu`) keeps the old drop dialog throughout.

## UAT

Exercised the drop path end to end against the fake CLI (`publish-live`): a drop on the popover ran `add` with `SHARE_PROGRESS=1` through the queue, the row showed `Step 2 of 3 · Uploading`. Accepted for the fake CLI only; no live tenant, no real desktop input.
