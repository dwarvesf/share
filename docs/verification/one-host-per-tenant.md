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

## TASK-4: setup --r2 and --no-r2, no alias (rows 11, 12, 13, 32)

```
Command: SHARE_TEST_PORT_BASE=28787 gtimeout 900 bash tests/share.sh
Exit:    0
Checks:  1243 ok, 0 FAIL, 0 SKIP (PASS), at 19926b1
Section: === tenant: setup --r2 and --no-r2 on the origin (rows 11, 12, 13, 32) ===, 32 checks
Verdict: PASS
```

`node tests/worker.mjs` PASS, `shellcheck` and `/bin/bash -n bin/share` clean on the same tree. Every call ran against the dry seam (`SHARE_R2_DRY=1`, a `.test` hostname); nothing was created on a Cloudflare account.

Negative controls on copies of tree `a2cd324` (commit 19926b1), the full suite each:

| Patch | Red | Green (unpatched copy) |
|---|---|---|
| attach the route before the pointer backfill (a route POST above step 9) | row 11 call order (stops at `^API POST /zones/zone-dry/workers/routes$`), the rerun (a second route POST), row 13 (a route left after `--no-r2`), the fresh-bucket order; `fails=7` with the copy's two `git show` checks and one load flake | every tenant row green; the two `git show` checks and one load flake (`cleanup: nocred1 row gone`, an unrelated SPEC-004 row; both copies ran at once) |
| let SPEC-007's r2 setup take a tenant host with `--force` (the `PASS` refusal skipped when `--force` is set) | row 32 "a tenant Worker (PASS) is refused with --force, before any write" (got `0 0 1`: the setup ran on and wrote); `fails=3` with the two `git show` checks | row 32 green; only the two `git show` checks |

The copies carry no `.git`, so the two `v0.5.1 CLI` checks that run `git show` fail in every copy run; the worktree run above is 0 FAIL.

Dry trace for the first control: the patched setup logs `API POST /zones/zone-dry/workers/routes` before the first `PUT m/0a000`, so the order check finds the route POST's first line above the pointer PUTs and stops at that pattern; the rerun POSTs a second route because the patched line runs on every setup.

# Batch 3

Batch 3 is the member `hits` wording (DEC-012), TASK-5, TASK-6, and TASK-7a, each committed and checked on its own. Every call ran against the dry seams (`SHARE_R2_DRY=1`, `SHARE_ACCESS_DRY=1`, `.test` hostnames); nothing was created on a Cloudflare account.

## Green runs

Each run: `SHARE_TEST_PORT_BASE=28787 gtimeout 900 bash tests/share.sh` in the worktree, then `node tests/worker.mjs`, `shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh demo/render.sh mac/*.sh`, and `/bin/bash -n bin/share`.

| Task | Commit | `tests/share.sh` | Exit | `tests/worker.mjs` | shellcheck |
|---|---|---|---|---|---|
| member `hits` wording | fcd24bd | 1246 ok, 0 FAIL, PASS | 0 | PASS | clean |
| TASK-5 (rows 14, 30) | d246452 | 1281 ok, 0 FAIL, PASS | 0 | PASS | clean |
| TASK-6 (rows 1, 15, 16, 17, 28) | 1f9fb4b | 1312 ok, 0 FAIL, PASS | 0 | PASS | clean |
| TASK-7a (row 18, `--token-stdin`) | 32a502e | 1340 ok, 0 FAIL, PASS | 0 | PASS | clean |

## Negative controls

Each patch went into a `git clone --local` of the named commit in a mktemp directory (so the `git show` rows run as in the worktree), and the full suite ran there with `SHARE_TEST_PORT_BASE=40000`, one run at a time. An unpatched clone of the same commit ran green (`EXIT=0`) for d246452, 1f9fb4b, and 32a502e.

| Patch | Commit | Red rows | Failed |
|---|---|---|---|
| member `hits` prints the bare count again (the note line becomes `:`) | fcd24bd | row 13 "no visits on an id another publisher added" and row 3 "member hits of a machine id never prints a bare 0" (both got `0 hits, 0 visitors` alone) | 2 |
| keep the alias destinations on the app after step 14 (`alias_dests drop` skipped) | d246452 | row 14 "dropped last, after the 301", row 14 end state, the rerun, and every row 30 convergence (each app still lists `f.example.test/<id>{,/*}`) | 7 |
| print `--no-r2` as the step-15 rollback with an alias (`tenant_die` ignores the alias) | d246452 | row 30 at each of steps 12, 13, 14, 15 (got `1 0 0 0 1`: no list, `roll back with: share ...` printed) | 4 |
| read the bucket in `state` through `api_token_cmd` (the stored-token check skipped) | 1f9fb4b | row 17 "an api_token_cmd source" (got `0 1 6 0`: the sentinel command ran, the bucket rows listed, no `cloud_error`) | 3 |
| merge bucket rows through `rows()` (the origin's bucket read rebinds `index`, outside the prune's subshell) | 1f9fb4b | row 28 "the Caddyfile and index.tsv hold exactly the local rows" (the expired local row stayed, a bucket row counted in the index), plus rows 6, 11, 13, 14, 15, 30 | 45 |
| let `import` accept a symlink (the pre-scan takes an `l` mode and a `->` line, the post-scan a link) | 32a502e | row 18 "a symlink is refused" (got `0 1 1`: published, a row written) | 1 |

Two unrelated lines failed in the red runs and are not counted as caught: row 29 "a member joins" in the `api_token_cmd` run (the healthz wait under load; green in every other run), and the real-launchd guard in both TASK-6 red runs. That guard saw a real `foundation.d.share` job appear on this machine during the first run and leave during the second. The suite stubs `launchctl` and labels its own jobs `share-selftest-<pid>`, so the job came from outside the suite; the worktree runs and the green clone saw no change.

An earlier attempt ran two clones at once; the green one failed `prune still removes the payload` and a row 27 `rm` with exit 5 while the twin run trashed same-named files. Every control above ran alone.

Dry trace for the TASK-5 rollback control: with the patch, the step-15 die at `ALIAS-301` calls `die "...; roll back with: share --profile ten setup ten.example.test --no-r2"`, so the output holds no `alias rollback for f.example.test` line and no `  6. ...` step, and row 30's count reads `0` where it wants `1`.

## Tar measurement

TASK-7a's first step ran on bsdtar 3.5.3 and GNU tar 1.35; the table and the flags it fixed are in `docs/implementation-notes/one-host-per-tenant.md`. Nothing was extracted outside the scratch directories: both tars stripped the absolute member into the target and refused the `..` member, and the probe paths outside it did not exist afterwards.

## Rollback

Batch 3 changes only `bin/share`, its tests, and docs on the PR branch; no release, tap bump, or Cloudflare object exists for it. Rolling it back is reverting commits fcd24bd, d246452, 1f9fb4b, and 32a502e on the branch.
