# Share Bar popover A: proof (partial, screenshots pending)

Status: code, unit tests and build gates are done. The final screenshot run is NOT done. The desktop session was locked (`CGSSessionScreenIsLocked` true) from the middle of the run, so real clicks stopped landing and no image was taken against the final code. An earlier run of the same screens, before three small fixes (member name capitalisation, keyboard-only focus ring, search placeholder colour) and two scenario changes, passed every step. Its images are not kept because they no longer match the code.

## Recorded run

Command: `swift build --package-path mac`
Exit: 0
Verdict: pass

Command: `swift test --package-path mac`
Exit: 0
Verdict: pass, 316 tests (258 before this sub-goal)

Command: `bash mac/build.sh 0.0.0`
Exit: 0
Verdict: pass (run before the review fixes, which touch only Core and the store)

Command: `bash mac/compat-check.sh v0.9.0`
Exit: 0
Verdict: pass

Command: `bash mac/Tests/fixtures/popover/run-shots.sh` (earlier run, 15 step files, light and dark)
Exit: 0
Verdict: pass. An undone Remove left 0 `rm` in argv.log, a completed Remove left exactly 1, and Resume left `setup s.console.so --members`. A re-run is needed.

## To finish

1. Unlock the desktop, then `bash mac/Tests/fixtures/popover/run-shots.sh` (writes `4b-*-light|dark.png` here).
2. Score each image against `docs/design/share-bar-redesign.html` revision 8 and `docs/design/share-bar-interactions.md`.
3. `bash mac/shots.sh all` (the foundations step files now drive the popover).

## Mobbin comparison (against the first run)

| Screen | Reference | Result |
|---|---|---|
| Copied toast, undo footer | Calm and Square "link copied" toasts | Same shape: icon, one sentence, action on the right |
| Row menu, revoke item | Voicenotes share sheet "Revoke" | Same: compact menu, destructive item last after a separator, red ink |
| Search field | Microsoft Copilot file search | Same: rounded low-contrast fill, icon left |

## Limits

- Status item dot: no image. This host's display capture is black and the item's window is not listed. `status-item-check.sh` asserts the Accessibility label that carries the count.
- Popover width is fixed at 340 pt (spec: fixed widths), so light, dark and the narrowest width are one size.
- The light capture reads grey (a translucent popover with no backdrop).
