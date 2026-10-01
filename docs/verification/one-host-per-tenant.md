# Proof of done: one host per tenant, batch 1

Date: 2026-10-01
Branch: docs/one-host-per-tenant
Spec: docs/specs/SPEC-008-one-host-per-tenant.md

Batch 1 is TASK-1a and TASK-1b (live spikes; commands and answers in `docs/implementation-notes/one-host-per-tenant.md`) and TASK-2a (per-link storage on the origin, rows 2, 4, 5).

## Green run

```
Command: SHARE_TEST_PORT_BASE=28787 gtimeout 900 bash tests/share.sh
Exit:    0
Checks:  1112 ok, 0 FAIL, 0 SKIP (PASS), at 3ea7dfe
Section: === tenant: per-link storage on the origin (rows 2, 4, 5) ===, 35 checks
Tail:    ok    no real Keychain share item changed during the run
         PASS
Verdict: PASS
```

```
Command: node tests/worker.mjs
Exit:    0
Tail:    ok    r28 malformed record aud
         PASS
Verdict: PASS
```

`shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh demo/render.sh mac/*.sh` and `/bin/bash -n bin/share` are clean on the same tree.

## Negative controls

Each patch was applied to `bin/share` in the worktree, the tenant section was run on its own (the section's lines from `tests/share.sh` under a minimal `check` harness), then `git checkout -- bin/share` restored the file and the same run went green (35 ok, 0 FAIL).

| Patch | Run | Red rows |
|---|---|---|
| write the pointer after `stage_publish` (the pointer line moved below the publish line in `cmd_add`) | exit with `fails=4` | row 4 "held at the pointer PUT, pub/<id> does not exist yet" (expected `1 0`, got `1 1`); row 5 "no pub/<id>" (got `1 0 0 0`, twice) |
| let a pointer PUT failure warn instead of die (`r2_pointer_put`'s catch-all prints and returns 0) | exit with `fails=4` | row 5 "exits 1 naming R2" (got `0 0`, ungated and gated); row 5 "no pub/<id>, no row, no app" (got `1 1 0 0`, and `1 1 1 0` gated: the app was created) |
| restore (`git checkout -- bin/share`) | `fails=0` | none |

Dry trace for the first control: the row 4 run holds the add at `PUT m/c00001` through `SHARE_R2_DRY_PAUSE`, whose `.paused` marker tells the test it is inside the held call; with the patch, `stage_publish` has already moved the stage to `pub/c00001`, so the check reads `1` where it wants `0`.

## Live spikes

TASK-1a and TASK-1b ran against throwaway Cloudflare objects only (names `share-e2e-spk584462` and `share-e2e-spk13b60d`). Every object was deleted and checked from outside: the API listed none of them on either account afterwards, the minted token's id answered 404, and each zone's authoritative server answered NXDOMAIN for both names.

# Batch 2

Batch 2 is TASK-2b, TASK-3, and TASK-4, each committed and checked on its own.

## TASK-2b: dispatch, reconcile, sweep (rows 3, 6, 26, 27)

```
Command: SHARE_TEST_PORT_BASE=28787 gtimeout 900 bash tests/share.sh
Exit:    0
Checks:  1151 ok, 0 FAIL, 0 SKIP (PASS), at 6df0318
Section: === tenant: storage dispatch, member refusals, reconcile, sweep (rows 3, 6, 26, 27) ===, 39 checks
Verdict: PASS
```

`node tests/worker.mjs` PASS, and `shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh demo/render.sh mac/*.sh` clean, on the same tree.

Negative controls: each patch went into a copy of tree `25dd9e9` (commit 6df0318), the tenant sections ran alone, then the unpatched copy ran green (0 FAIL).

| Patch | Red rows |
|---|---|
| let a member `rm` a machine row (the refusal in `cmd_rm_r2` becomes a `DELETE m/<id>`) | row 3 "member rm of a machine row is refused" (got `0 0`), "no DELETE m/<id>, the pointer stays" (got `1`), "member refresh ... refused" (got `1 0 0`: the pointer was gone, so the message changed), row 27's machine rm (no pointer left to delete); `fails=4` |
| let the sweep count a machine pointer as unreadable (`r2_record_raw`'s machine branch raises) | row 26 origin and member sweeps (got `0 0 1`: skipped, warning printed), the not-JSON leg (got `0 0 0`: the warning named the pointer instead); `fails=3` |

Dry trace for the first control: the member's `rm e10001` reads the snapshot, finds `e10001` in `r2_machine`, and with the patch logs `DELETE m/e10001`; the check reads one DELETE line in the member's `r2-calls.log` where it wants none.

## TASK-3: Worker v3 and r2_healthz (rows 7 to 10, 29)

```
Command: SHARE_TEST_PORT_BASE=28787 gtimeout 900 bash tests/share.sh
Exit:    0
Checks:  1211 ok, 0 FAIL, 0 SKIP (PASS), at 2fcbdb1
Section: === tenant: the Worker is up while the origin is off (row 29) ===, 6 checks
Verdict: PASS
```

```
Command: node tests/worker.mjs
Exit:    0
Checks:  134 ok, 0 FAIL (PASS), at 2fcbdb1; the tenant rows 7 to 10 add 58
Verdict: PASS
```

`shellcheck` and `/bin/bash -n bin/share` clean on the same tree. One earlier full run on this tree failed `500-row index answers under 3s` once while the machine was busy; the rerun took 0.84 s and passed.

Negative controls on a copy of tree `a6ff281` (commit 2fcbdb1):

| Patch | Runner | Red | Green (unpatched) |
|---|---|---|---|
| the Worker passes an expired cloud record through instead of 404 | `node tests/worker.mjs` | `r7 an expired cloud record is 404, never passed through` (got `200 1`), plus the WORKER_SHA self-check | PASS |
| the Worker passes a miss through with `PASS` empty | `node tests/worker.mjs` | `r9 PASS empty: a miss is 404 with no fetch call` (got `101 1`: the stub's last answer came back) and the machine-pointer leg (got `404 1`), plus the WORKER_SHA self-check | PASS |
| read the healthz status alone in `r2_healthz` (the header branch never fires) | full suite | row 29 tunnel-down: `state` (got `0 false`), the gated add (got `1`), the join (got `1 0`) | row 29 green; the copy has no `.git`, so the two `v0.5.1 CLI` checks that run `git show` fail in both runs (and `profiles --json wrote nothing under HOME` once in the red run, a flake); the worktree run above is 0 FAIL |

Dry trace for the third control: the dry Worker writes `HTTP/2 503` with the pair and `x-share-tunnel: 0`; with the patch `hz_code` stays 503, so `state` reports `ready: false`, the gated add dies at its healthz check, and the join's three-in-a-row wait times out.
