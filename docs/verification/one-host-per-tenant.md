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

# Batch 4

Batch 4 is TASK-7b (`migrate`, rows 19, 20, 21, 31), committed at f0dc1ac. No dry seam exists for `migrate` (it refuses an R2-on tenant), so its local coverage is a `curl`/`security` shim pair plus `SHARE_MIGRATE_SSH` pointing at a wrapper that joins its own argv with spaces and replays it through `fish -c` (or `sh -c`) on the same machine, exactly mirroring what a real ssh round trip does to the command line; nothing was created on a Cloudflare account.

## Green run

```
Command: SHARE_TEST_PORT_BASE=30787 gtimeout 900 bash tests/share.sh
Exit:    1 (one pre-existing, unrelated flake; see below)
Checks:  1360 ok, 1 FAIL
Section: === migrate: moving a tenant's origin (rows 19, 20, 21, 31) ===, 20 checks, all ok
Tail:    ok    no real launchd or systemd share job appeared during the run
         ok    no real Keychain share item changed during the run
```

```
Command: node tests/worker.mjs
Exit:    0
Verdict: PASS
```

`shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh tests/e2e-tenant.sh demo/render.sh mac/*.sh` and `/bin/bash -n bin/share` are clean on the same tree (`tests/e2e-migrate.sh` does not exist yet; it is TASK-9b's deliverable).

The one failing line, `profiles --json wrote nothing under HOME` (a `find -newer` marker check, pre-existing code untouched by this batch), is unrelated to migrate: it passed on a first full run of the same tree and failed on a second run of the identical code, the same intermittent-under-load pattern the TASK-3 and TASK-6 batches above already recorded for other lines. A rerun confined to the migrate section alone (the 20 checks above) is green every time.

## Negative controls

Each guarantee's patch ran as a one-off (a `sed`-patched copy of `bin/share`, the relevant migrate scenario run standalone against it, the stock file confirmed green immediately after). No patch was committed.

| Guarantee | Patch | Red | Green (unpatched) |
|---|---|---|---|
| ids preserved | the remote `import` call for one id is rewritten to a different id before `bin/share` runs it | B's index never gains the original id (the renamed one lands instead) | row 19: B's index holds exactly A's own ids |
| source never deleted | `migrate_retire`'s `mv "$pub/$id" "$root/migrated/$id"` replaced with `rm -rf "$pub/$id"` | `migrated/<id>` never exists after a run that otherwise completes | row 19: every moved id's tree lands in `migrated/`, byte for byte equal to B's copy |
| retire runs only after verify passes | the gated-link `access_probe_round ... || die` turned into `access_probe_round ...; true \|\| die` (the die never fires) | with a wrong Access `kid` forced on the gate check, `index.migrated` still gets written: retire ran past a verify that should have stopped it | row 20: the same wrong-`kid` scenario, unpatched, stops before retire and names the gated id |

Dry trace for the first control: `cmd_import`'s own id argument comes from the sender's positional argv, so a wrapper script that rewrites `$2` before `exec`ing the real binary is enough to desync the id client-side of any base64 or checksum check; the manifest digest still matches (it is a digest of the tar's own bytes, not the id), so nothing else catches it except the id itself showing up wrong in B's index, which is exactly what the "ids preserved" guarantee asserts directly.

## Rollback

Batch 4 changes only `bin/share`, `tests/share.sh`, and docs on the PR branch; no release, tap bump, or Cloudflare object exists for it. Rolling it back is reverting commit f0dc1ac on the branch.

# Batch 5

Batch 5 is the `kit:battery` review fix pass on this PR (five findings plus two items raised from the live rehearsal), commits a045013..2a0fb65. Each finding carries its own commit with a failing test shown red before the fix, then green after; the fast per-finding reruns below are scratch slices of the real `tests/share.sh` (same fixtures and helper functions, the unrelated middle of the file cut out) used purely to get a faster red/green loop during the fix; no scratch file was committed.

## Findings and their red/green

| # | Finding | Fix | Red (before) | Green (after) |
|---|---|---|---|---|
| 1 | migrate handed the target no `--tunnel-name`; a source on the default name collided, the target reused the source's own tunnel, and `migrate_retire` then deleted it out from under the new origin | always pass a deterministic `--tunnel-name` distinct from the source's own (`-m` suffix); `migrate_retire` also refuses the tunnel/DNS deletes if the target's own tunnel id is ever reported equal to this machine's | row 19m: target's tunnel_id equals the source's | row 19m: target's tunnel_id never equals the source's; rows 19/20/21/31 unaffected |
| 2 | `tests/share.sh` printed the same "PASS"/"N FAILED" summary whether the run finished or crashed partway | a `reached_end` flag set only at the true end; the EXIT trap reports ABORTED and exits 2 when it is missing; the summary prints the total check count | isolated trap test: a truncated run exits 0 with no ABORTED text | isolated trap test, then the embedded self-test: a truncated run exits 2 and prints ABORTED |
| 3 | `cmd_setup`'s old_host guard only fires when old_host is set; import into a not_setup profile then `setup <other-host>` served its gated rows ungated | refuse when old_host is empty and the profile holds an `access=` row; migrate's own switch (`--token-stdin`) is exempt, since it never renames the hostname | setup on a not_setup profile with a gated row: no refusal, dies on the live Cloudflare call instead (with the nocurl stub, before any call assertion fails) | refused before any Cloudflare call, naming the gated row |
| 4 | the Worker's `pass()` treated any 502 as the whole machine offline, same as Cloudflare's 520-527 edge codes | drop the explicit 502 check; only 530, 520-527, and a 503 with no `cf-cache-status` mean offline | `node tests/worker.mjs`: a dead-port 502 rewritten to the 503 offline page | the 502 passes through unchanged, with or without `cf-cache-status` |
| 5 | implementation notes claimed the migrate preflight reads `tunnel_name` from the API by `tunnel_id` when the config key is missing; the code never did | `cmd_migrate` now reads it back from the API when the local key is absent, and dies naming the manual fix if neither is known; note corrected to say where this runs | row 31b: rollback line printed `--tunnel-name  --force` (empty) | row 31b: names the tunnel read back by id, never empty |
| 6 | `alias_dests drop` answered HTTP 400 live (3/3 rehearsals), the same PUT shape that worked for `add` two calls earlier | the PUT body drops the legacy `self_hosted_domains`/`domain` mirror fields so the API recomputes them from the new `destinations`, instead of echoing back a stale value that no longer names a surviving destination once drop removes it | row 14 ("the fold exits 0") against a genuinely reverted `alias_dests`, cf_dry extended to reject the same self_hosted_domains/destinations inconsistency a real PUT does, fixture carrying a realistic `self_hosted_domains`: fold dies, destinations keep the alias's own entries. Confirmed again with an isolated jq trace of the exact body construction (same expressions, no harness): pre-fix body retains `self_hosted_domains` naming a URI absent from the new `destinations` | row 14/30 (40+ checks) all pass end to end; the same isolated jq trace shows the stripped body consistent |
| 7 | `tests/e2e-tenant.sh` had five script bugs found across three live rehearsals (a cold R2 token, a split TCP read in the echo origin, a missing-file check, two Access-app lookups assuming a folded app renames to the tenant), plus L8's `etag_before` reading through A's own profile right after `--no-r2` removed its `bucket=` | applied the run1→run3 fix patch; L8 now reads the pointer's ETag by a direct S3 HEAD on the bucket name, independent of A's profile config | (live-only; no dry seam exercises the R2/Access live path) | `bash -n tests/e2e-tenant.sh` and shellcheck clean; the lead reruns R1/L8 live |

## Green run

```
Command: SHARE_TEST_PORT_BASE=32787 gtimeout 900 bash tests/share.sh
Exit:    0
Checks:  1238 checks, PASS
Tail:    ok    a run truncated before the end exits 2
         ok    a run truncated before the end reports ABORTED
         ok    no real launchd or systemd share job appeared during the run
         ok    no real Keychain share item changed during the run
```

A first run of the same tree, same command, showed one failing line unrelated to any of the seven items above (`row 6: pub/<id> absent while a PROBE fail was logged`, a `sleep 0.05` filesystem-polling race against a background watcher, pre-existing and untouched by this batch): the same intermittent-under-load pattern Batch 4 already recorded for a different line. The rerun above is clean.

```
Command: node tests/worker.mjs
Exit:    0
Verdict: PASS
```

```
Command: swift test --package-path mac
Exit:    0
Verdict: Executed 176 tests, with 0 failures (0 unexpected)
```

`shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh tests/e2e-tenant.sh demo/render.sh mac/*.sh` and `/bin/bash -n bin/share tests/share.sh tests/e2e-tenant.sh` are clean on the same tree.

## Rollback

Batch 5 changes `bin/share`, `tests/share.sh`, `tests/worker.mjs`, `tests/e2e-tenant.sh`, and `docs/implementation-notes/one-host-per-tenant.md` on the PR branch; no release, tap bump, or Cloudflare object exists for it. Rolling it back is reverting commits a045013..2a0fb65 on the branch.

# Batch 6

Batch 6 is the live rerun of `tests/e2e-tenant.sh` on the fix-pass head (1440259), the fixes that rerun forced, the TASK-10 docs, and the negative controls the earlier batches had not covered. Final live result: 73/73, run log `docs/verification/e2e-tenant-20261005T042854Z.log`. TASK-9b (`tests/e2e-migrate.sh`, rehearsal R2) is not run here: it needs one command from Han on the Air.

## Live e2e: five runs, one green

Every run used the PR worktree's `bin/share` (`SHARE_BIN`), zone `d.foundation`, an admin token from `op://Toolkit/cf-api-token/credential`, run-scoped 2h publisher tokens minted through `op://Toolkit/cf-tokens-admin/credential`, and `SHARE_E2E_ACCESS_RULE=group:dwarves-ops`. Hostnames were `share-e2e-<6 hex>` pairs chosen per run. The earlier logs are not committed (two of them print the account and zone ids in a rollback line).

| Run | Head | Result | What failed | Cause and action |
|---|---|---|---|---|
| 1 | 1440259 | 69/73 | L3 WebSocket echo; R1 rollback x2; R1 "alias bucket gone" | R1's fold passed for the first time (alias 301, folded gated link 302 with `kid == aud`, second fold), so the live 400 is fixed. The rest: the WebSocket client used the local resolver, which answered "No route to host" for a name made seconds earlier (script bug, now DoH). `setup --no-r2` exited 1 with no output (a real bug in `alias_rollback`, below). The cleanup deleted the alias bucket with an admin env token on a profile with no stored publisher token (script bug) |
| 2 | f6a6f41 | 71/73 | R1 rollback x2 | the script parsed `r2-call`'s `code=<n> etag=<etag>` line as `etag=` alone, so the marker host restore went out with an empty `If-Match` and the marker kept its `aliases` (script bug) |
| 3 | dac8541 | 70/72 | R1 standalone origin and gated link | Cloudflare answered HTTP 500 adding the Worker custom domain for the alias host; the gated R1 legs did not run. Transient; the die names the call |
| 4 | dac8541 | 72/73 | L1 "gated local link 302s to Access with kid == aud": got 200 | the first fetch after `add` returned reached an edge that did not yet enforce the app. Not reproduced in run 5; see the note below |
| 5 | dac8541 | 73/73 PASS | none | R1 (fold, rollback, second fold, cleanup) green end to end |

R1 passes: the fold exits 0; `https://<alias>/healthz` answers 301 to the tenant; the folded gated link 302s on the tenant with `kid == aud`; the rollback list runs in its printed order and `--no-r2` leaves a plain tunnel (no route); the second fold converges and the alias 301s again; the cleanup deletes the bucket, the Worker, and the tenant DNS.

Gate note from run 4: share's own check passed three rounds of `kid == aud` before the link was published, and a fetch through DoH one second later still answered 200 once. Access enforcement is per edge and eventual (ADR-0006 measured seconds to minutes). The e2e keeps the strict check, because "no ungated window after `add` returns" is the guarantee the leg tests. A lead decision, outside SPEC-008: whether `add --access` should probe through a second resolver before it publishes.

## Cleanup proof, from outside the run

A snapshot script listed every resource class the e2e touches, before and after each run, from the Cloudflare API and `launchctl`. Names and truncated ids only. The baseline and every later snapshot were identical (`diff` empty) after runs 1, 2, 3, 4, and 5.

| Class | Baseline (and after every run) |
|---|---|
| Workers named `share-*` | `share-f-d-foundation` |
| Worker custom domains, routes, DNS records matching `share-e2e*` | none |
| Tunnels named `share-*` (not deleted) | `share-s-d-foundation` |
| R2 buckets named `share-*` | `share-dfoundation` |
| Access apps named `share ...` | `s.d.foundation`, `f.d.foundation` (the two live Dwarves apps) |
| Minted user tokens (`a-origin`, `b-member`, `d-fresh`, `c-admin`) | none |
| launchd labels and LaunchAgents plists matching `share` | `foundation.d.share.dfoundation`, the Share Bar app job |

The script's own `leftovers` sweep printed `cleanup: nothing left for this run's names` on all five runs. No process named `echo.py` or `share-e2e` remained. Nothing the run did not create was touched: the two live Access apps, `share-f-d-foundation`, `share-s-d-foundation`, and `share-dfoundation` are in the baseline and in every later snapshot.

## Findings the rerun forced

| # | Finding | Fix | Red | Green |
|---|---|---|---|---|
| 1 | `alias_rollback` assigned `ptrs` from a pipeline ending in `grep`; with no local rows and no machine records the grep matches nothing, and under `set -e` the run died with exit 1 and no output, so `--no-r2` and every `tenant_die` printed nothing for a tenant with an alias and no local rows (e6b2a13) | `{ grep ... \|\| true; }` in the pipeline | the new row 30 check, run against the unfixed `bin/share` in a clone: `row 30: with no local rows and no pointers, --no-r2 still refuses and prints the list: expected '1 1 1 1', got '1 0 0 0'`, 1 FAIL of 1243 | the same check on the fixed tree: 1243 checks, PASS |
| 2 | five `tests/e2e-tenant.sh` script bugs (743b229, dac8541): DoH for the WebSocket client; the R1 rollback removes `aliases=` from the profile config (step 4 of the printed list); the marker ETag parsed from `code=<n> etag=<etag>`; the alias liveness check reads `/healthz` (a standalone r2 Worker answers 404 at the site root by design); the cleanup's delete-prefix uses the `SHARE_R2_TOKEN` seam | script edits | runs 1 and 2 | run 5, 73/73 |

## Negative controls

The spec lists 20. Batches 1 to 5 recorded a red run for 14 of them (the expired-record, `PASS`-empty, pointer-order, pointer-failure, route-order, alias-destination, symlink, `api_token_cmd`, `rows()`-merge, SPEC-007 `--force`, sweep, member-`rm`, healthz-status, and `--no-r2`-rollback controls). Batch 6 adds 5 and records one whose spec form is not reachable, with a substitute. Each patch went into a `git clone --local` of dac8541 in a scratch directory and the suite (or `node tests/worker.mjs` for a Worker patch) ran there, one run at a time with its own `SHARE_TEST_PORT_BASE`. The green run for every row is the unpatched clone of the same commit.

| Green (unpatched dac8541) | Result |
|---|---|
| `SHARE_TEST_PORT_BASE=41100 gtimeout 900 bash tests/share.sh` | exit 0, 1243 checks, PASS |
| `node tests/worker.mjs` | exit 0, PASS |

| Spec control | Patch | Runner | Red |
|---|---|---|---|
| the Worker serves R2 for a `storage:"machine"` record (row 7), tested in the inverse form | the machine-pointer branch in `worker_js` made unreachable (`&& false`), so a pointer no longer passes through | `node tests/worker.mjs` | `r7 a machine record passes through` (got 404, no fetch) and the r8 pass-through rows (13 FAIL, plus `WORKER_SHA` drift, which any Worker edit trips) |
| drop the encoded-separator check before the pass-through (SPEC-007 row 18 on the v3 source) | the `%2f \|%5c \|%2e \|low escape \|//` test replaced with `if (false)` | `node tests/worker.mjs` | `r18` for `..%2F`, `%2f`, `..%5C`, `%2E`, `//`, and a low escape (all 404, expected 400), and `r7 /x/..%2Fb1c2d3/f.txt is 400 in front of the tunnel` (12 FAIL plus `WORKER_SHA`) |
| take a member's `add --local` as cloud (row 3) | the member `--local` die replaced with `storage=cloud` | suite | `row 3: member add --local f is refused` (got `0 0`), 1 FAIL |
| run the full teardown (with Access deletes) on the old origin before moving rows aside (row 19) | `cmd_rm` of every moved id at the top of `migrate_retire` | suite | `row 19` migrate exits 0, B's trees equal A's, the rows move to `index.migrated`, the live row stays, migrate still exits 0; `row 21` rerun skips the moved id (9 FAIL, one of them the harness's idler check after the abort) |
| omit `--tunnel-name` from the printed migrate rollback (row 31) | `--tunnel-name $old_tunnel_name` dropped from the switch-failure rollback line | suite | `row 20: a remote-setup failure ... printing the rollback with A's own tunnel-name` and `row 31b` (3 FAIL, one the idler check) |
| write `bucket=` into a plain tunnel config at setup (row 1) | `echo "bucket=leak"` added to `write_config` | suite | no red: 1243 checks, PASS. Not reachable: row 1's compat run does a quick setup only, and no suite row runs a named tunnel `setup` through `write_config`. The live e2e covers it (L1 setup, L7 `--no-r2`) |
| replacement for the row above: `--no-r2` keeps `bucket=` (row 13) | `tenant_config` stops dropping `bucket=` | suite | `rerun: the config is the same`, `row 13: the config is the one before setup --r2`, `row 13: the next add writes no pointer` (3 FAIL) |

One gap is open: the `write_config` row-1 control above. Closing it needs a named-setup fixture with a Cloudflare stub, which no suite row has; it is the one place where only the live e2e proves "a tenant with R2 off writes no `bucket=`".

## Docs check (TASK-10)

`tests/share.sh` now checks that every verb, flag, config key, and state key the tenant docs name is in `docs/how-it-works.md` and in `bin/share` (the four generic state keys are checked in the doc only, since `storage`, `type`, `by`, and `r2` are too common to grep in the source; rows 15 and 1 pin them in `state` output). It has three negative controls inside the suite: a doc missing `--storage-default`, a `bin/share` missing `--remote-bin`, and a doc missing the `storage` state key each fail the check. All pass in the green run above.

## Rollback

Batch 6 changes `bin/share` (one line in `alias_rollback`), `tests/share.sh`, `tests/e2e-tenant.sh`, README, `docs/how-it-works.md`, `docs/setup.md`, ADR-0008, the spec (DEC-013, the 502 rows, Worker version 4), the implementation notes, and this record, on the PR branch. No release, tap bump, or standing Cloudflare object exists for it. Rolling it back is reverting commits e6b2a13..dac8541 and the docs commit that follows.

# Batch 7

Batch 7 is the lead's three safety decisions and the CI fix, on top of Batch 6.

| # | Change | Red (unfixed 476f4f8, new tests) | Green |
|---|---|---|---|
| 1 | `migrate_retire` refuses the DNS and tunnel delete when `migrate-tunnel-id` returns nothing, and names `teardown --yes` for later | row 19e: `no DNS record or tunnel is deleted` got `0 2`; the refusal text absent | row 19e passes: migrate exits 0, rows moved aside, no DELETE of a DNS record or tunnel |
| 2 | the custom-domain add (standalone r2 setup and the alias bind) retries a Cloudflare 5xx, three tries with doubling backoff, and dies loud after (`after up to 3 tries`); the dry seam gains `SHARE_R2_DRY_FAIL_TIMES` | four checks: two 500s then success got `1 1`, a persistent 500 got one PUT, not three | both paths succeed after two stubbed 500s (three PUTs) and die after three on a persistent 500; the alias die still prints the rollback list |
| 3 | `add --access` polls the published link until it answers 302 or 403 (`SHARE_ACCESS_POST_WAIT`, 30 s) before printing it; a link still answering anything else exits 1 with the status, the edge risk, and `share rm <id>`; the link stays published | four checks: the link printed with no probes, a 200 never failed the add | `200,200,302` prints after three probes; `403` counts; a persistent `200` exits 1 with no link on stdout, and the warning names the rm command |

Red run: `1256` checks, 11 FAIL (the 10 above plus one cascade from leftover gated rows, fixed in the test). Green runs on the final tree: `1256 checks, PASS`, one earlier run showed a single row 29 timing failure (`SHARE_R2_WAIT=1` join under load) that did not repeat. `node tests/worker.mjs`: PASS. Live: `tests/e2e-tenant.sh` on 1a76f2e (the first commit with the real link check against Cloudflare), 73/73, log `docs/verification/e2e-tenant-20261005T062235Z.log`; the before and after snapshots of every resource class are identical.

## CI

The CI lint job failed on every push since the tenant work began, and the test jobs have failed since the migrate rows landed. Three causes, all fixed:

| Job | Cause | Fix |
|---|---|---|
| lint | CI's shellcheck reports SC2015 twice in `bin/share` and SC2002 once in `tests/share.sh`; the local shellcheck 0.11 is quieter | restructured the three lines, same behavior; a later SC2001 in a new debug line fixed too |
| test (ubuntu, macos) | the migrate rows run `setup` on the target, which dies with `missing: caddy cloudflared` on a runner with no cloudflared; every dev machine has one | the suite appends stand-in `caddy` and `cloudflared` last on PATH, so a real binary still wins. Reproduced locally with a PATH that hides cloudflared and fish: red before, `1256 checks, PASS` after |

The macOS runner also showed one `tty: the prompt appeared and the token did not echo` failure on 1440259 that did not recur; it is the known flaky row.

# Batch 8

Batch 8 is TASK-9b: `tests/e2e-migrate.sh` and the live rehearsal R2 of the personal move, on throwaway names. Final result: 38/38, run log `docs/verification/e2e-migrate-20261005T093825Z.log`. The second machine was the real Air, driven from the Mini with `mini-run --host air`, migrating over real ssh to the Mini.

| Leg | What it ran | Result |
|---|---|---|
| M0 | origin A (a snapshot, a folder, a gated snapshot, a live server), `migrate` to B on the same machine with a remote `setup` that does the real switch and then reports failure; the printed rollback run on A | exit 1 with the rollback line naming A's own tunnel; the DNS record moved to B's tunnel; the printed rollback exits 0 and the record points at A's own tunnel again; every link answers, the gated one with `kid == aud` |
| M1 | the same name migrated again, B already holding the copies | exit 0; the copies are skipped; the live link is reported as not moved; every snapshot link answers at the same URL, the gated one keeps its 302 and AUD; the DNS record points at B's tunnel; A's tunnel is deleted; A's rows are in `index.migrated` and its trees under `migrated/` |
| M2 | a second throwaway name set up on the Air, five links published, `migrate --to` the Mini over ssh | the same assertions as M1, from the real Air to the Mini |

Measured gap: probes every 0.5 s through DoH on a snapshot link logged no non-200 answer across the switch on either run (37 probes in M1; the M2 gap logger likewise). The spec expected up to about a minute of 530; the DNS record flips and the new tunnel connects inside a probe interval at this scale, so the number to plan with is "under a few seconds", not a minute.

## Findings the rehearsal forced

| # | Finding | Fix | Red | Green |
|---|---|---|---|---|
| 1 | `migrate` archived only `<name>`, but a bare-file snapshot keeps its generated `index.html` beside the file at the id root. The receiver counted one file where the sender's manifest counted two and refused the share as a truncated copy: every single-file link would have failed the personal move (9ae6350) | the archive is the whole `pub/<id>` tree; `import` checks that `<name>` is in it | the suite fixture gains the generated `index.html` it lacked: 17 FAIL in rows 19 to 31 | 1256 checks, PASS |
| 2 | after a failed switch the target profile is serving this hostname, so the rerun's preflight died with `port for this profile is already in use`; the printed rollback led to a dead end (f37e816) | the preflight accepts a target already serving the same hostname | new row 19s: got `1 1` | 1257 checks, PASS |
| 3 | script bugs in `tests/e2e-migrate.sh` itself: profile names must be lowercase; the Air-side run needs the real `HOME` for ssh while share keeps a throwaway one; a new name needs a moment to resolve | script edits | runs 1 to 5 | run 6, 38/38 |

Both product bugs live only on the real-account path: no fixture in the suite had a generated index beside a bare file or a target that was already serving.

## Cleanup proof

Snapshots of every Cloudflare resource class (Workers, domains, routes, DNS, tunnels, buckets, Access apps, minted tokens) and of `launchctl` and LaunchAgents on the Mini were identical before and after the runs. On the Air, the count of `foundation.d.share` launchd jobs and the LaunchAgents listing were the same before and after (its real `s.han.ws` service was never touched: the legs used profiles `mga` and `mgb` under throwaway HOMEs). The script's own sweep printed `cleanup: nothing left for this run's names` on every run. One leftover surfaced: the M2 target's data root under the real HOME (`~/share/profiles/mgb`), because the script's cleanup only looked for the profile config. The script now moves that root aside too.

## Rollback

Batch 8 adds `tests/e2e-migrate.sh` and changes `bin/share` (`migrate_tar`, the import root check, the migrate preflight) and `tests/share.sh`. No release, tap bump, or standing Cloudflare object exists for it.


## Batch 9: live go-live, Dwarves tenant (2026-10-06)

Han typed the go in the operator session. Snapshots: `tests/prod-snapshot.sh` before D1 and before D3, kept outside git. The pre-D1 and pre-D3 snapshots differ only in `share 0.8.0` vs `share 0.9.0`.

| Step | Action | Check | Result |
|---|---|---|---|
| D1 | merge #45 (a625255), `bin/release --yes` v0.9.0, notarized Share Bar 0.9.0, tap PRs homebrew-tools #28 and #29 merged, `brew upgrade share` on the Mini | `brew list --versions share`; status and live links unchanged | `share 0.9.0`; healthz 200 on both hosts; a68960 and ba6377 302 |
| D3 | `setup s.d.foundation --r2 --bucket share-dfoundation --alias f.d.foundation` (rc 0) | f.d.foundation/ba6377 301 to s.d.foundation, which 302s to Access with the snapshot AUD; a68960 302; `ls` lists a68960 machine and ba6377 cloud | pass |
| D2 | minted the origin publisher token (180 days, expires 2027-04-04), stored in the Keychain from the Orca GUI session; removed the profile's `api_token_cmd` line that pointed at the admin token (config backed up first) | `api-token --check` | token found in the keychain, all lines ok, rc 0 |
| D4 | `share --profile files teardown --yes` | `share profiles` | default and dfoundation only |
| D5 | the user-probe roster line for f.d.foundation/healthz now probes s.d.foundation/healthz (host config, backed up) | roster lines | both lines on s.d.foundation |
| post | ungated local and cloud add; gated local and cloud add with group:dwarves-ops; rm all | 200 no-store; 302 to Access with per-app kid; 404 after rm | pass |
| post | `stop` then `start` with one machine and one cloud link | while stopped: machine 503, cloud 200; after start: machine 200, a68960 302, healthz 200 | pass |
| P1/P2 | not run | `mini-run --host air` | ssh to the Air timed out twice (tailnet shows the Air active via relay, port 22 unreachable) |

Finding: `setup --alias` prints "nothing was published; the Access app of ba6377 waits in access-pending" at exit after a successful fold. `access_gate` sets `held_access_id` and the fold path never clears it, so the EXIT trap prints a false notice. `access-pending` stayed empty, so nothing is at risk. Not yet fixed.

Open: P1 and P2 (the Air must be reachable), the Share Bar After-state box (GUI, not checked), and D6 (delete Worker share-f-d-foundation after seven days, a second go). The old `files` publisher token is revoked at D6.
