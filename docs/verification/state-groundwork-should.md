# Proof of done: state groundwork, Phase 2 (SPEC-010)

Date: 2026-11-15
Branch: feat/state-groundwork-should
Spec: docs/specs/SPEC-010-state-groundwork.md, tasks G6, G7, G8, G9, G10, G14
Notes: docs/implementation-notes/state-groundwork.md (build delta C1 to C21, the Phase 2 AC to test map, the advisor round)

Every check below ran on the Mac Mini in the branch worktree. The new sections are `=== state groundwork: G6 ... G14 ===` in `tests/share.sh`. No Cloudflare account was touched: tunnel and DNS calls go to a stateful fake API, R2 and Access calls to the existing dry seams. For each serve-phase fixture, `jq '[.state,.ready]'` is compared with the output of HEAD's `bin/share` captured with `git show`.

## Recorded run

```
Command: /bin/bash -n bin/share && shellcheck bin/share tests/share.sh
Exit:    0
Verdict: PASS (bash 3.2 parse, no shellcheck finding)
```

```
Command: env PATH="<scratch>/shim:$PATH" SHARE_TEST_PORT_BASE=24000 bash tests/share.sh   (shim/bash -> /bin/bash, so every `bash` is macOS 3.2.57; tools keep their normal order)
Exit:    0
Excerpt: 1571 checks, PASS, 0 FAIL; every `=== state groundwork: ... ===` section green
Verdict: PASS (the full suite and the bash 3.2 run, at the final commit)
```

Negative controls (each ran red against a broken variant, then green against the real code, inside the suite above):

| Control | The broken variant | What goes red |
|---|---|---|
| NC-G7 | `link_apply` never says `expired` | the expired cloud row reads `live` |
| NC-G8 | `pending_state` never sees a live owner | a working add counts as pending |
| NC-G9 | `add_sweep` ignores the row | a finished add's copy goes to the Trash |
| NC-G10 | `token_state` touches `.health` | "state writes nothing" trips, with `.health` present |
| NC-G14 | `config` rewrites the file instead of `config_put` | the other keys are lost |

Other checks of the Done line, all in the same run:

- `.health` present and absent: the three `state writes nothing` checks stay green (SS-03, TK with the file present, TK with it absent).
- `.health` is one file, one top-level key per writer: "a second writer leaves the other keys alone" (the `worker` key survives a `token` write).
- TASK-0c's G7 fallback is gone: `revoked` and `revoked_by=` come from `link_state` (check "LS revoked").

Advisor critique (frozen diff): one major (a token verdict older than a week hid `expired` and `expiring`), folded with three new TK checks; minors recorded in the notes.

```
Command: bash ~/.claude/dwarves-kit/lib/goal/mega-merge.sh gate state-groundwork-should full
Exit:    see the PR body (run before the land)
Verdict: recorded in the gate ledger
```

## Not attempted

- Swift (G11a to G11c) is SG-06; G12 stays out (D7).
- `min_cli` has no writer here; the members work writes it.
- Live Cloudflare work: none in this spec.

## Rollback

All changes are in `bin/share` and its tests. `.health` is an advisory cache: deleting `$config_dir/.health` loses nothing, `state` then reads `unchecked`, `unknown` and `live`. An `add` journal left in `$root/ops/` by an older run is read and consumed by the next bare `prune`. To revert, revert the PR: no migration, no config key, and no Worker or deploy change is involved.
