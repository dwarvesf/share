# Implementation notes: Share Bar popover A

Delta from SPEC-009 TASK-4b6 to TASK-4b9. The spec rows are not restated. Foundations notes: `share-bar.md`.

## Decisions the spec left open

- D1. Logic lives in `ShareBarCore/Popover/` (view model, issues, row actions, switch) so `swift test` covers it; the SwiftUI views and the controller live in `ShareBar/Popover/`. The executable target has no tests.
- D2. Ownership of a row: on an origin or admin profile a row with no `origin` is the viewer's; on a member profile a row is the viewer's when its `origin` ends with the same 8 hex as `state.member.id`. Any other row is someone else's.
- D3. The CLI has no created time per row, so the list keeps the CLI's order (the listing is newest first) and the row shows no relative age. A `created` key in `state` rows would add the age column.
- D4. The Team meta line names the owner: `You` for the viewer's rows, else the member name from `origin` with its first letter upper-cased, else `by`.
- D5. The tenant button menu, the row menu and the undo footer are drawn inside the popover (SwiftUI overlay), as the prototype does, not as `NSMenu`. The overlay keeps one window to capture and lets `axdrive` find every item through the popover's tree.
- D6. `shots.sh` is frozen, and it only reads scenarios from `Tests/fixtures/scenarios/<name>`. Popover scenarios live in `Tests/fixtures/popover/scenarios/` and are named `../popover/scenarios/<name>` on the step file's `scenario` line.
- D7. The legacy `remove-link.steps` of the foundations run drove the `NSMenu`. With the popover as default it would fail, so it now drives the popover's row menu and the undo window.

## Open questions

- `<me>` for an admin's `share member renew <me>`: an admin profile has no member record, so the argv uses `state.member.name`, else the profile name. A refusal shows the CLI's sentence.
- The tunnel line of the needs-a-look list says "for more than 2 minutes" in the interactions doc; `state` carries no since-time, so any `tunnel_down` phase is a line.

## Harness quirks found in the final run

- `mac/shots.sh` exits 1 with no message when `SHOTS_OUT` does not exist (its `find` fails under `set -e`). Create the directory first. SG-16 owns the fix.
- The first launch after another run sometimes reports "status item never appeared"; a second run passes. Stale `Share Bar.app` processes under `mac/build/shots` make it more likely; kill them first.
- `row-menu-other` clicked `more-7f3a21` once before the Team list rendered. A `find row-7f3a21` before the click would remove that race.
