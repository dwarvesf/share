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

## Design parity pass (revision 8)

- D8. Surface: the popover root paints the design's rendered window color (`#eff0f3`, dark `#2b2c31`) opaque, held in `Theme.surface`; `primitive.window` stays the contrast reference. A tint over the material would still follow the wallpaper.
- D9. Placeholder: drawn as an overlay `Text` in the tertiary ink; SwiftUI ignores a color on `prompt:`. The darker tertiary (`#6b6b70`) is kept, so the placeholder sits 15 steps from the design in light by intent.
- D10. Trailing age (supersedes D3 in part): the spec lists a relative age on every row, the design's "Nd left" is the meta line, so both show. `Share` decodes an optional `added` (lenient); `RowAge` turns the day into `today`, `Nd`, `Nw`, `Nmo`, `Ny`. `share state` does not print `added` yet, so a live tenant shows no age until `bin/share` adds the key (open, outside Touches).
- D11. Row menu: the popover's measured height was always zero (a preference that never fired), so the menu flipped to the top. The overlay now reads its own size, and the popover grows (`minHeight`) to hold the menu under the row. The first item is lit on open and the highlight follows the pointer.
- D12. Native arrow kept; the root fill is opaque inside the arrow-less body.
- D13. Capture without input: DEBUG-only `-ShareBarShotsRender <png> [-ShareBarShotsMenuRow <id>]` draws `ShareBarView` offscreen. `Snapshot.swift` gained one field outside the listed touches because the age needs it.

# Popover B (TASK-4b10 to TASK-4b13)

Delta from SPEC-009 for the drop, drag-out, Quick Look and hotkey tasks. Foundations and popover A decisions above still hold.

## Decisions the spec left open

- D14. Input-free captures (owner decision 2026-11-15, replaces DEC-56 for these tasks): the DEBUG hook `-ShareBarShotsRender <png>` gains `-ShareBarShotsScene <name>`, read inside `PopoverController.debugRender` so the frozen `AppDelegate` stays untouched. A scene sets state through the same reducer events a real drag, key or hotkey sends, then draws the popover (or the Quick Look view) offscreen. No pointer or key input reaches the desktop. SPEC-009 gets DEC-83 and the four AC lines are amended.
- D15. AC map (row to test): `progress lines move the publishing entry's step` is `PublishFlowTests.testProgressLinesMoveThePublishingEntrysStep`; `a drop with no tenant is refused with the first-run panel` is `PublishFlowTests.testADropWithNoTenantIsRefusedWithTheFirstRunPanel`; `the drag item carries the URL as url and text`, `expired and revoked do not drag`, `an internal drag never enters dropTarget` are in `DragOutTests`; `preview source per row kind` and `close returns focus to the row id` are in `QuickLookModelTests`; `the hotkey event from issues lands in list with search focused` is the existing `PopoverStateTests.testHotkeyFromIssuesLandsInListWithSearchFocused`; the negative control (a second registration of one key reports in use) is `HotkeyTests.testASecondRegistrationOfTheSameKeyReportsInUse`.
- D16. A drop runs `add` on the popover's current tenant with `SHARE_PROGRESS=1`, through the app's `MutationQueue`. `MutationQueue.run` gained optional `environment` and `onOutput` parameters (default empty), so the popover streams the journal's lines without a second queue. Callers of `run(_:)` are unchanged.
- D17. The status item drag opens the popover (`dragEnter`); leaving the item sends `dragLeave` but leaves the popover open, so moving the drag from the item into the popover does not close it under the cursor. The popover's own `onDrop` then re-enters `dropTarget`.
- D18. A drag out reports its end by polling `NSEvent.pressedMouseButtons` on the popover clock: SwiftUI's `onDrag` has no end callback, and an `NSDraggingSource` wrapper would fight the row's tap and hover handling.
- D19. Quick Look is a non-activating `NSPanel`; while it is open the popover's behavior is `applicationDefined`, so a click on the panel does not dismiss the popover under it.
- D20. The `state` rows carry no port, so a port share shows `Live server`, the port read from a name like `localhost:3000` when it has one, and a local TCP connect probe says whether anything answers. No HTTP request leaves the Mac for any row (DEC-55).
- D21. `pub/<id>` is the served tree, not the file: a file share keeps `pub/<id>/<name>` and a folder share keeps `pub/<id>/<name>/` (`bin/share` stage and publish). The Quick Look preview source is therefore `pub/<id>/<row name>`; a file goes to `QLPreviewView`, a folder to the entry list. The spec's "previews `pub/<id>`" is read that way.
- D22. Deliberate deviations from revision 8, all listed in `docs/verification/share-bar/popover-b/README.md`: the search keeps its focus ring after ⌃⌥S (the prototype shows a caret that an offscreen capture cannot draw); the drop overlay says `Stored on this Mac` where the prototype says the machine name (the spec wins); the uploading row says `Step n of m` where the prototype says a percent (SPEC-010 G9 reports steps); the Quick Look pdf capture composes the file's thumbnail because `QLPreviewView` draws out of process and an offscreen window captures it blank; the cloud preview is the glyph and the meta line, no fetch (DEC-55).
- D23. A drop on the status item opens the popover with the overlay; a drop with no tenant sends `reveal`, which opens the popover on the first-run panel. The legacy `NSMenu` keeps the old publish dialog (`LegacyMenu`).

## Open questions

- `share state` prints no port for a port share, so Quick Look reads it from a name like `localhost:3000`. A `port` key in the row would remove the guess.
- The footer drag hint names the dragged link, as the prototype does; AppKit gives the source no way to learn the destination app's name.
- Not exercised on a live desktop (owner rule): a real Finder drag onto the status item, a real ⌃⌥S press from another app, a real Space on a focused row, a real drag of a row into TextEdit. The reducer, the Carbon registration and the offscreen captures stand in; SG-16 or the owner's own run closes them.

## Popover in settings B

- D24. Loading, CLI missing and CLI too old replace the list body (`AppStateView`); `Working: add (3/6)` replaces the baseline footer for another process's alive op; a failure footer splits `Next:` into a copyable mono line. Scenes for them: `-ShareBarShotsScene loading|cli-missing|cli-old|focus-third|menu-shift-f10|publish-failure` (`PopoverStore.freezeForShots` holds them against the controller's reads).
- D25. Row actions: VoiceOver gets every row-menu item as an action. Focus moves and restores through `RowFocus`.
