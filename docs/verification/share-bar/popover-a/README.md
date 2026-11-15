# Share Bar popover A: proof

Status: done. Every screen an AC names is captured by real clicks, key events and the Accessibility API on the final code, light and dark (40 images, `4b-*-light|dark.png`). Spot-checked against revision 8 and the interactions doc: layout, copy, state colours, destructive ink, focus ring and the needs-a-look grouping match; no gap found.

## Recorded run

Command: `swift build --package-path mac`
Exit: 0
Verdict: pass

Command: `swift test --package-path mac`
Exit: 0
Verdict: pass, 316 tests

Command: `bash mac/build.sh 0.0.0`
Exit: 0
Verdict: pass

Command: `bash mac/compat-check.sh v0.9.0`
Exit: 0
Verdict: pass

Command: `bash mac/Tests/fixtures/popover/run-shots.sh` (15 step files, light and dark, on the final code)
Exit: 0
Verdict: pass. An undone Remove left 0 `rm` in argv.log, a completed Remove left exactly 1, Resume left `setup s.console.so --members`.

Command: `SHOTS_OUT=<existing dir> bash mac/shots.sh all` (foundations step files, now driving the popover)
Exit: 0
Verdict: pass. `SHOTS_OUT` must exist already or the script exits 1 silently.

UAT: exercised in the real app bundle against the fake CLI on this Mac, accepted. Nothing deployed; no Worker, setup or persistent state touched, so no rollback section.

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
