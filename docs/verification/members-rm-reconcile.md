# Proof of done: member rm, revoke, reconcile and leave, Phase 2 (SPEC-009)

Date: 2026-11-15
Branch: feat/members-rm-reconcile
Spec: docs/specs/SPEC-009-multi-member.md, tasks TASK-2a, 2b, 2c, 2d, 2e
Notes: docs/implementation-notes/multi-member.md, section "Phase 2 build" (deltas P30 to P40, the AC to test map, open questions Q3 and Q4)

Every check ran on the Mac Mini in the branch worktree. The Phase 2 rows are the `=== members: revoke and reconcile ===`, `=== members: member rm and member purge ===` and `=== members: leave and the member's status ===` sections of `tests/members.sh`, sourced by `tests/share.sh`. No Cloudflare account was touched: every Cloudflare call went to the dry account (`SHARE_R2_DRY=1`), every bucket call to the dry bucket, and every Worker request to the real Worker source through `node tests/worker.mjs --dir <bucket>`. The member's serve started a real Caddy on a suite port; FG-03, FG-11, LK-11 and OT-12 fetch through the Worker's binding to it.

## Recorded run

```
Command: /bin/bash -n bin/share && shellcheck bin/share tests/share.sh tests/members.sh
Exit:    0
Verdict: PASS (bash 3.2 parse, no shellcheck finding)
```

```
Command: node tests/worker.mjs
Exit:    0
Verdict: PASS (every v5 row, including V3_EXPIRED for LK-12)
```

```
Command: SHARE_TEST_PORT_BASE=28500 <scratch>/mxrun.sh with MX_ONLY=revoke, "member rm", "leave and status", "the registry"   (the suite header, then tests/members.sh)
Exit:    0
Excerpt: revoke and reconcile 41 checks, member rm 22, leave and status 13, the registry 16; 0 FAIL
Verdict: PASS (on commit 8891438)
```

```
Command: env PATH="<scratch>/shim:$PATH" SHARE_TEST_PORT_BASE=28500 bash tests/share.sh   (shim/bash -> /bin/bash, so every bash is macOS 3.2.57)
Exit:    1
Excerpt: 2/1826 FAILED: "no hint names a bare share <verb>" (three hints in the new code named share <verb> instead of $me), "mm MB-24: rm proceeds past member_can (its build is later)" (it expected the rm stub)
Verdict: FAIL (on commit 026d84d), both fixed in 8891438
```

```
Command: env PATH="<scratch>/shim:$PATH" SHARE_TEST_PORT_BASE=28500 bash tests/share.sh   (the second, last full run)
Exit:    0
Excerpt: 1826 checks, PASS, 0 FAIL, in 1364 s; every `=== members: ... ===` section green, node tests/worker.mjs green (bin/share run by macOS /bin/bash 3.2.57)
Verdict: PASS (the full suite and the bash 3.2 run, on commit 8891438)
```

## Negative controls

Each ran red against a mutant of `bin/share` (`MX_SH` and `MXM_SH` point the runners at it; the serve loop runs `bash "$0"`, so the mutant too), on port base 28500, on commit 026d84d's code, then green in the runs above.

| Control | The mutant | Command | Exit | What went red |
|---|---|---|---|---|
| NC-1 | `rc_revoke` also trashes `pub/<id>` | `MX_SH=MXM_SH=<mutant> MX_ONLY=revoke mxrun.sh` | 1 | `mm RC-10, FG-02: ... the bytes kept`, `mm LK-11, Q-OPS-1: ... keeps the bytes`, `mm LK-11: ls ...`, `mm OC-02: ... the bytes stay` (4 of 41) |
| NC-8 | `r2_take` puts every v:3 on a member's reap list (no origin filter) | same | 1 | `mm RC-06: another origin's pointer with no row here: nothing` (the pointer was deleted), RC-12, RC-13 (3 of 41) |
| NC-10 | `member rm` skips the VPC Service delete | `MX_SH=<mutant> MX_ONLY="member rm" mxrun.sh` | 1 | `mm MB-13, Q-SEC-5 (NC-10): ... every object kind ... empty` (a service remained), and 10 more rm rows (11 of 22) |
| NC-14 | reconcile row 9 removed (no young-tombstone skip) | `MX_ONLY=revoke` | 1 | `mm CC-06: the m/ DELETE lands between the m/ list and the t/ read: ... no resurrection` (got `0/0 0/1/0`: the pointer came back), RC-09, RC-10 (3 of 41) |
| NC-loop | serve spawns the member loop without `env -u CLOUDFLARE_API_TOKEN` | `MX_ONLY=revoke` | 1 | `mm TASK-2c, Q-OPS-1: serve on a member runs prune --loop hourly under env -u CLOUDFLARE_API_TOKEN (NC-loop)` (got `LOOP env_token=1`) |

NC-loop is this sub-goal's own control (the spec's table numbers stop at NC-16 and none covers the loop's environment).

## Done line

- TASK-2a to 2e pass their AC rows: the map is in the notes; every row named there is a passing `mm` check. Not attempted: MB-30's last clause (publishing again after the admin's `renew`) needs `member renew` (SG-08); the Share Bar's "You were removed" screen is TASK-4b17.
- RC-01 to RC-15: one check per reconcile row on the member HOME, RC-14 on the origin, RC-15 with `prune --loop` (Phase 1 covers `ls` and `prune`). CC-06 runs three orders plus the DEC-64 write race and the read race the review found (pointer deleted between the `m/` list and its GET). CC-07 and CC-08 pass. FG-01 to FG-04, FG-11, FG-14, FG-16 (a tab, a space, a newline, a trailing newline) pass.
- DP-rm: a kill at each of the 10 steps; `member ls` (or `status` at step 1) names the step and the rerun; each rerun ends removed with no tunnel, service, token, invite, binding, PAUSED entry or v:3 pointer of the member, no lease and an empty `ops/`.
- Q-SEC-5: `rm_gone` lists every object kind of the dry account and bucket for the member after `member rm` (tunnels, services, tokens of every minter user, `i/`, the binding, `PAUSED`, `m/`), from every status; empty each time. With a minter of another user it names the token it could not reach with its expiry (MB-34).
- D4 / DEC-79: a 401 sets the token verdict `invalid` (or `expired` past the local `token_expires`) and never `state.member.status`; a 404 record is reported and never read as removal; only a record read as `removed` sets `removed` (MB-21, MB-30, MB-31, OT-03, the 404 row).
- The member serve loop runs under `env -u CLOUDFLARE_API_TOKEN`: the serve-spawned loop logs `LOOP env_token=0` with the admin token in serve's environment; the loop's bucket rows run with serve's `SHARE_API_TOKEN_OFF=1`.

## Review folds

`/kit:review` (opus) and `kit:advisor` critique (opus) ran on the frozen diff. Folded: a record forged to `removed` no longer blocks `member rm` (its objects are still removed); a decoy record of the same name never steers rm (the bound one wins, else refused naming both ids; rm and purge take a member id); row 13 re-reads the pointer and takes row 10 when it is gone; an unreadable tombstone is never read as absent; `leave` stops serving before it deletes pointers, and a rerun after its keys went finishes locally; the record notes a token delete before the delete; the record's invite hash is no longer trusted alone; a tombstone `by` ending in a newline reads unknown; `t2_refuse` refuses on an unreadable `u/` record; the loop's bucket rows run with `SHARE_API_TOKEN_OFF=1`; the `leave` message says cloud links stay. Each has a check (labels marked `(review)` or `(advisor)`, or the rows above).

Left open, named for SG-08: the spec rows LK-09 ("before any call", P31) and the Review's MEDIUM teardown finding (P39) need a spec amendment; the tombstone write is in two places (`member_revoke`, `member rm` step 8); `member_revoke` ends in `exit 0`; `renew` and `invite` must clear `token_unreachable_until` and accept `.token.id == ""`.
