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
