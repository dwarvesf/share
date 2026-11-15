# Proof: Share Bar foundations

Scope: state groundwork G11a, G11b and G11c, and the multi-member tasks 4b1 to 4b5 (decoders, derivation, popover reducer, harness, tokens). `mac/` only; `bin/share` is unchanged. The notes are `docs/implementation-notes/share-bar.md` (decisions D1 to D18 and the AC map).

## Recorded run

All runs on the Mac mini, from the SG-06 worktree, after the last code change.

| Command | Exit | Verdict |
|---|---|---|
| `swift build --package-path mac` | 0 | pass |
| `swift test --package-path mac` | 0 | pass: 258 tests, 0 failures |
| `bash mac/build.sh 0.0.0` | 0 | pass: builds, signs ad hoc, zips `Share-Bar-0.0.0.zip` |
| `bash mac/compat-check.sh v0.9.0` | 0 | pass: 10 fixtures read clean by the v0.9.0 decoder (8 fixtures, the checked-out CLI's live `profiles --json` and `state`) |
| `bash mac/compat-check.sh v0.9.0 <fixture with state schema 2>` | 1 | negative control: `FAIL ... newer: Update Share Bar` |
| `bash mac/shots.sh calm open-popover` | 0 | pass: light and dark image written, reached by a real click on the status item |
| `bash mac/shots.sh calm missing-control` | 1 | negative control: `missing control: No Such Control`, no image written |
| `bash mac/shots.sh calm remove-link` | 0 | pass: `argv.log` holds `--profile default rm 4f9ff2` |
| `bash mac/shots.sh all` | 0 | pass: the negative file must fail and leave no image; the other two files pass |
| `/bin/bash -n` on `mac/shots.sh`, `mac/compat-check.sh`, `mac/Tests/fixtures/bin/share` | 0 | pass: parse under macOS bash 3.2.57 |
| `/bin/bash mac/compat-check.sh v0.9.0`, `/bin/bash mac/shots.sh calm open-popover` | 0 | pass under bash 3.2.57 |
| `shellcheck mac/shots.sh mac/compat-check.sh mac/Tests/fixtures/bin/share` | 0 | pass |

## Done line

- Journal `rerun_argv` and `rollback_argv`: `JournalRunTests` (15 rows) covers the verb and profile checks, the per-verb flag shapes, a hostile argument reaching a stand-in CLI as one literal argument with no shell, and an op of unknown liveness never running.
- `member ls --json` and the progress line decode from fixtures built to the spec's shapes: `NewKeyDecodeTests` with `member-ls.json` and `state-full.json`.
- Each AC row maps to a test or a run in the AC map of the notes.

## Screenshots

Taken by `bash mac/shots.sh`, every control reached by a real mouse click through the Accessibility API; nothing sets state in the app.

- `docs/verification/share-bar/4b4-open-popover-light.png`, `4b4-open-popover-dark.png`: the menu a click on the status item opens.
- `docs/verification/share-bar/4b4-row-menu-light.png`, `4b4-row-menu-dark.png`: the row menu.
- `docs/verification/share-bar/4b4-remove-confirm-light.png`, `4b4-remove-confirm-dark.png`: the remove confirm.

The light images read grey because `screencapture -l` takes the translucent menu window alone, with no backdrop to blur (notes D8).

## UAT

Ran `mac/shots.sh` and `mac/compat-check.sh` on the Mac mini against the fake CLI and a throwaway HOME. Accepted. A collapsed Hidden Bar hides every third-party status item on this machine; `shots.sh` expands it once when the item is missing (notes D10).

## Not attempted

- The "drag from Finder" step and the screenshots index `docs/verification/multi-member.md` (notes D17).
- A caller of `JournalRun` in the menu (notes D16).
