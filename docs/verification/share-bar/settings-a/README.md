# Share Bar settings A: screens, parity and references

SPEC-009 TASK-4b14 to TASK-4b18. Every capture is taken by `mac/Tests/fixtures/settings/run-shots.sh`: the built debug app runs against the fake CLI (`Tests/fixtures/settings/bin/share`, which wraps the frozen base) and reaches each state through the in-app hook `-ShareBarShotsScreen` (DEC-81). No pointer, key or drag input reached the desktop. Each capture is `4b-<label>-<light|dark>.png` in this folder; `argv/` holds the CLI calls of each run. The window is fixed at 620 pt, the narrowest and only width the spec allows (`### Responsive behavior`), so there is no narrower capture.

## Parity with revision 8 (objective)

The design page is rendered headless (Brave `--headless`, 2x, sRGB) once per screen and appearance by `parity/render-reference.sh` from `parity/screens.tsv`; `parity/compare.sh` puts each render beside its capture (`parity/<label>-<appearance>.jpg`, reference left) and samples sRGB with `parity/sample.swift`. Largest gap per metric over 25 screens, in channel steps (`parity/samples.tsv` has every row):

| Metric | Light | Dark | Verdict |
|---|---|---|---|
| Window surface (`primitive.window`) | 2 | 1 | within a few steps |
| Header title ink (secondary) | 2 | 1 | within a few steps |
| Header rule (separator) | 1 | 2 | within a few steps |
| Primary ink | 14 | 10 | see deviation 1 |
| Search placeholder | 10 | 28 | see deviation 2 |

The goal quotes `#eff0f3` and `#2b2c31` for the window. The design's own `.win` renders `#f5f5f7` and `#26262a`, the value of `primitive.window` (`Tokens.swift:89`), so the window paints that token and the samples above are against the render, not the quote (implementation notes D5).

Deliberate deviations:

1. Primary ink. On a screen with a sheet the design render dims the whole window with its scrim, so its darkest pixel is a scrimmed label (`#101011`); the capture's darkest pixel is the sheet's own `#1d1d1f` label. On the other screens both read `#1d1d1f` or `#ffffff`. The dark General and member capture reads `#f5f5f7` where the design has a pure white check mark inside a native checkbox: the native control draws it.
2. Search placeholder. The design's field has no placeholder style, so the browser's `#757575` shows. The capture uses the deliberately darker tertiary token (`#6b6b70` light, `#919196` dark) that passes 4.5:1, as SG-20 keeps for the popover.
3. Native controls. Pop-up buttons, checkboxes and radios are AppKit controls, so their chevrons and edges differ from the HTML ones. Colors of text, surface and separators are tokens.
4. The source list row's second line is left-aligned; the design's is right-aligned, which reads as an accident (host and role would not share an edge). Screens: the Tenants set.
5. Progress step order follows the journal (`redeem`, `keys`, `record`, ...), the design lists "Tell the team" before "Save your keys". Screen: `progress-step-4-of-6`.
6. Screens with no design twin: `ask-admin-key` (the design has no ask sheet), `advanced-minter-1password`, `advanced-test-failed`, `tenant-owner-stopped` is the design's failed owner, `tenant-member-removed` and `tenant-key-expired` (the design shows no removed or expired banner). They are checked against the design's neighbouring sheet and Advanced layout, not sampled.

## Screens

| Task | Screen | Captures | Parity sheet | Mobbin reference and finding |
|---|---|---|---|---|
| 4b14 | General tab | `4b-general-tab-*` | `parity/general-tab-*` | Quo and Base44 settings (form rows, label left, controls right): same label column and grouped rules |
| 4b14 | Settings for a member without the Members tab | `4b-settings-member-*` | `parity/settings-member-*` | same; tab row shows three tabs |
| 4b15 | Advanced, 1Password item picked | `4b-advanced-1password-admin-*` | `parity/advanced-1password-admin-*` | Base44 data hosting rows: picked item as a bordered row with Choose |
| 4b15 | Minter key from 1Password | `4b-advanced-minter-1password-*` | none | same pattern as the admin row |
| 4b15 | With a command | `4b-advanced-command-*` | `parity/advanced-command-*` | mono field under the source pop-up |
| 4b15 | With Ask me each time | `4b-advanced-ask-*` | `parity/advanced-ask-*` | one sentence under the pop-up |
| 4b15 | Test passed | `4b-advanced-test-passed-*` | `parity/advanced-test-passed-*` | check mark and one summary sentence |
| 4b15 | Test failed with the CLI sentence | `4b-advanced-test-failed-*` | none | red cross and the CLI sentence |
| 4b16 | Stop serving confirm with counts (4 and 9) | `4b-stop-serving-confirm-*` | `parity/stop-serving-confirm-*` | Subframe and Upwork modals: title, one bordered list, two buttons |
| 4b16 | Pause confirm | `4b-pause-confirm-*` | `parity/pause-confirm-*` | same |
| 4b16 | Remove member with the cloud-links choice | `4b-remove-member-choice-*` | `parity/remove-member-choice-*` | pop-up now full width, as the design |
| 4b16 | Invite sheet | `4b-invite-sheet-*` | `parity/invite-sheet-*` | Stripe card options: selected option outlined in the accent |
| 4b16 | Code sheet | `4b-code-sheet-*` | `parity/code-sheet-*` | Subframe command rows: the value in a mono box |
| 4b16 | Ask for the admin key | `4b-ask-admin-key-*` | none | secure field, one command, nothing saved |
| 4b17 | Admin tenant serving | `4b-tenant-admin-serving-*` | `parity/tenant-admin-serving-*` | Base44, Plane, Quo: source list left, detail right |
| 4b17 | Owner tenant stopped with its reason | `4b-tenant-owner-stopped-*` | `parity/tenant-owner-stopped-*` | status word with a dot |
| 4b17 | Starting | `4b-tenant-starting-*` | `parity/tenant-starting-*` | spinner beside the word |
| 4b17 | Refused removal of a T2 tenant | `4b-tenant-refused-removal-*` | `parity/tenant-refused-removal-*` | sentence plus Open Members |
| 4b17 | Owner removal sheet | `4b-tenant-owner-removal-*` | `parity/tenant-owner-removal-*` | destructive action in the filled red |
| 4b17 | Member: You were removed | `4b-tenant-member-removed-*` | `parity/tenant-member-removed-*` | callout with Clean up |
| 4b17 | Key expired (extra) | `4b-tenant-key-expired-*` | `parity/tenant-key-expired-*` | callout with Copy request, no Clean up |
| 4b18 | Add sheet, join | `4b-add-sheet-join-*` | `parity/add-sheet-join-*` | segmented choice, two fields |
| 4b18 | Add sheet, set up (and empty, for the placeholder) | `4b-add-sheet-setup-*`, `4b-add-sheet-empty-*` | `parity/add-sheet-setup-*` | Stripe segmented card: same shape |
| 4b18 | Progress at step 4 of 6 | `4b-progress-step-4-of-6-*` | `parity/progress-step-4-of-6-*` | Upwork profile checklist: done, now, pending marks |
| 4b18 | Interrupted callout | `4b-interrupted-callout-*` | `parity/interrupted-callout-*` | callout with Roll back and Resume |
| 4b18 | Resume after a stop | `4b-resume-join-*` | none | argv `join <host> <code>` then `join` |
| 4b18 | Cloud storage progress | `4b-cloud-storage-progress-*` | `parity/cloud-storage-progress-*` | same sheet, 16-step list |
| 4b18 | Members progress | `4b-members-progress-*` | `parity/members-progress-*` | same sheet, 5-step list |

References (Mobbin): [Base44 workspace settings](https://mobbin.com/screens/7bef2981-afee-411f-86d7-3795e9428cb9), [Plane workspace settings](https://mobbin.com/screens/0dd3f591-12b4-48f4-96ff-a198b8cfc45d), [Quo settings](https://mobbin.com/screens/001faa09-e914-40e6-8a9b-a788655b506d), [Upwork checklist modal](https://mobbin.com/screens/31e5df99-6648-4833-b1da-f99ca9e330c4), [Subframe setup modal](https://mobbin.com/screens/75dcec3e-27e2-4df1-829b-fabdfe1408f1), [Stripe setup card](https://mobbin.com/screens/73e15164-db21-4b3a-83f9-60b8413a62e5). The Mobbin screens are web apps, so they confirm the pattern (a left source list with a detail, a modal with a state checklist, a confirm listing effects), not pixel values; the pixel check is the design render above.

## Gaps found and fixed in the scoring pass

- The title sat 40 pt too low, under the title bar; the root now ignores the top safe area, so the title shares the traffic lights' row as in the design.
- The sheet's drop shadow fell on every child of the card; it now sits on the card background only.
- The separator was the label color at 9%; it is black or white at 9% as the design has it (header rule 4 steps off before, 1 to 2 after).
- A tenant of role `tenant_origin` read "Owner" at T1; the design words it "Admin" at every tier.
- The sheet pop-ups did not fill the sheet width; they do now.

## Recorded run

See `docs/verification/sharebar-settings.md`.
