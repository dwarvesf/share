# Verification: Share Bar settings B (SPEC-009 TASK-4b19 to TASK-4b23)

Nothing deployed. `mac/` plus docs. Proof file for the ship gate: `docs/verification/sharebar-settings-b.md`.

## Capture sets

| Set | Command | Images |
|---|---|---|
| Members, All links, sheets (window capture) | `SHOTS_OUT=docs/verification/share-bar/settings-b mac/Tests/fixtures/settings/run-shots.sh <step>...` | `4b-<label>-<light\|dark>.png`, `argv/` |
| Popover states and errors (offscreen render) | `mac/Tests/fixtures/states/states-shots.sh docs/verification/share-bar/settings-b` | `<scene>-<light\|dark>.png` |
| Parity sheets and samples | `parity/compare.sh` against `parity/render-reference.sh` renders of revision 8 | `parity/` |

Every state comes from a DEBUG hook or the fake CLI. No pointer or key input reached the desktop.

## Screens per task

| Task | Screens |
|---|---|
| 4b19 | `members-all`, `members-needs-look`, `members-removed`, `members-menu-active`, `members-menu-stale`, `members-menu-removed`, `members-invite-sheet`, `members-invite-code`, `members-rotate-confirm`, `members-pause-resume` (argv: pause then resume) |
| 4b20 | `links-all`, `links-needs-look`, `links-expired`, `links-selected`, `links-no-match`, `links-bulk-remove-pending`, `links-bulk-copied`, `links-bulk-removed` (one `rm` with every id) |
| 4b21 | `loading`, `cli-missing`, `cli-old`, `first-run`; the join sheet from first run is `add-join` of settings A |
| 4b22 | `focus-third`, `menu-shift-f10` |
| 4b23 | `publish-failure`, `working-line` |

## Design parity (revision 8, headless Brave render beside the capture)

Sampled in sRGB (`parity/samples.tsv`): surface, primary ink, title ink, header rule, for light and dark. Largest delta 3 steps (primary ink on Members, light: `#1d1d1f` against `#1a1a1d`, the text weight of the capture). Search placeholder: both use the tertiary token. Separator: 9 percent ink in both.

Deliberate deviations:
- Data differs (the fixtures name An, Nam and Linh; the design names An, Bình and Chi); the layout, copy and states match.
- Link ages read `created today` and `created yesterday`: the CLI reports a day, the design shows minutes and hours.
- The search field of All links shows a focus ring on open (the spec asks for focus on open; the design draws none). The ring is the `focus` token.
- The Members window keeps a 440 pt minimum height so the row menu of a last row fits.
- `focus-third` takes three Down presses from the search field (the first enters row 1). The AC wording matches focus that starts on row 1.

## Mobbin comparison

| Screen | References | Read |
|---|---|---|
| Members tab | Base44 "Members and groups" (counted tabs above a bordered table, status chip, row "..." menu); Sprig "Members" (name, role, row menu, toast); Plane "Members" (search beside the primary button) | Same pattern: a bordered table, a search beside one primary action, a quiet row menu. Share Bar keeps the status chip and presence word inside the row, as Base44 does with Pending. |
| Members row menu | Base44 and Sprig row "..." menu | Menu lists only allowed verbs, destructive last; the references hide the rest as well. |
| All links window | Stripe "Lists" (table, counted tabs); Snowflake "Legacy Notebooks" (tabs, checkboxes, action bar that enables on selection); Canva "Manage links" (name and link columns, row menu) | Share Bar matches the tabs, checkboxes and selection bar of Snowflake; it adds Copy per row. |
| First run, CLI states | settings-a notes | Panel with one prominent action, as in the design. |
