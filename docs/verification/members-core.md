# Proof of done: members core, Phase 1 (SPEC-009)

Date: 2026-11-15
Branch: feat/members-core
Spec: docs/specs/SPEC-009-multi-member.md, tasks TASK-1b, 1c1, 1c2, 1d, 1e, 1f1, 1f2, 1f3, 1g, 1h, 1i
Notes: docs/implementation-notes/multi-member.md, section "Phase 1 build" (deltas P1 to P29, the AC to test map, open questions)

Every check ran on the Mac Mini in the branch worktree. The Phase 1 rows are `=== members: ... ===` in `tests/members.sh`, sourced by `tests/share.sh`. No Cloudflare account was touched: every Cloudflare call went to the dry account (`SHARE_R2_DRY=1`, state files under `<bucket>/.cf`), every bucket call to the dry bucket, and every Worker request (redeem, the join probe) to the real Worker source through `node tests/worker.mjs --dir <bucket>`. A machine member's join started a real Caddy on a suite port, and its probe went through the Worker's `vpc_service` binding (`--bind`) to that Caddy.

## Recorded run

```
Command: /bin/bash -n bin/share && shellcheck bin/share tests/share.sh tests/members.sh
Exit:    0
Verdict: PASS (bash 3.2 parse, no shellcheck finding)
```

```
Command: node tests/worker.mjs
Exit:    0
Verdict: PASS (every v5 row; CC-11 is "v5 SV-15: two concurrent redeems of one object: exactly one 200")
```

```
Command: env PATH="<scratch>/shim:$PATH" SHARE_TEST_PORT_BASE=25500 /bin/bash tests/share.sh   (shim/bash -> /bin/bash, so every `bash` is macOS 3.2.57)
Exit:    0
Excerpt: 1749 checks, PASS, 0 FAIL; every `=== members: ... ===` section green (bin/share run by macOS /bin/bash 3.2.57)
Verdict: PASS (the full suite and the bash 3.2 run, at commit 75fb08e)
```

```
Command: SHARE_TEST_PORT_BASE=25500 <scratch>/run.sh   (the suite header, then tests/members.sh alone, every section)
Exit:    1, then 0 after the fix
Excerpt: 178 checks, 1 FAIL (TN-07 expected the older uncoded migrate refusal; the test now reads members_present), then the tenant section 23 checks, PASS
Verdict: PASS
```

The first full-suite run (before the review folds) hung in the TN-09 die-point loop: `mx_kill_at` ran a bare `wait`, which also waits for the suite's live-port backend. It now waits for its own subshell only. That run had reported 4 failures before the hang, each fixed: two code-table checks (`tenant_not_t2` held a digit the check's `[a-z_]+` splits, now `members_off`; a comment matched the bare-verb check), SG-03's TN-10 fixture (`role=member` in an origin config, now refused by TASK-1g's `setup` guard), and TN-04/05 record fixtures whose `added: "x"` the new date check rejects.

## Negative controls

Each ran red against a mutant of `bin/share` (`MX_SH`/`MXM_SH` point the test runners at it), on port base 26500, then green in the suite run above.

| Control | The mutant | Command | Exit | What went red |
|---|---|---|---|---|
| NC-7 | `lease_take` returns 0 before its PUT | `MX_SH=<mutant> MX_ONLY="member add" run.sh` | 1 | `mm CC-01: add bo while add an holds the lease ... refuses naming the holder` (bo ran through), plus MB-01's order and the DP-add lease lines |
| NC-9 | `mb_deploy` sets `PAUSED` from the records (`[]`) | `MX_SH=<mutant> MX_ONLY="member ls" run.sh` | 1 | `mm FG-05, FG-06 (NC-9): a later deploying verb never unpauses ...` (PAUSED lost `aaaaaaa1`), and MB-23 |
| NC-11 | join starts the service before its record write | `MXM_SH=<mutant> MX_ONLY="member machine" run.sh` | 1 | `mm DP-join-3 (NC-11): a record write that fails starts no service before it`, and DP-join-3's 412 row (a serve.pid appeared) |

The other negative controls of the spec belong to tasks outside this sub-goal (NC-1, NC-8, NC-14 reconcile, NC-10 rm: SG-07) or already ran (NC-2, NC-6, NC-12, NC-16 in SG-03; NC-3 to NC-5, NC-13, NC-15 in tests/worker.mjs).

## Done line

- TASK-1b to 1i pass their AC rows: the map is in the notes; every row named there is a passing `mm` check in the run above.
- `member_can`: `mm member_can: every (status, verb, actor, mode) tuple matches the doc table` reads the expectation from the spec's own table (12 rows) and compares all 672 tuples.
- DP-add and DP-join converge with no orphan: each DP-add rerun ends with exactly one tunnel, one VPC Service, one token and one `i/` for the member, its binding, no lease and an empty `ops/`; each DP-join rerun ends `active`.
- Q-SEC-6: `mm Q-SEC-6: ...` shims `jq`, `openssl`, `security`, `curl` and `cloudflared`, logs every argv, and searches the argv log, both `r2-calls.log` files, every file under both HOMEs and every output for the code, the minted token, the connector token, the admin and minter tokens, and the key-derivation prefixes. None is found; the code prints once, on the `share join` line.
- Tokens are found by name only (`ob_token_find`, `GET /user/tokens?per_page=50&page=<n>`); the minter comes from `SHARE_MINTER_TOKEN` or `minter_token_cmd`, resolved only on minter paths (`mm CC-13`, `mm TASK-1c1: member renew runs minter_token_cmd once`).
- TASK-1a shapes folded: `service_id`, 5101/5104, a paged list with no `result_info`, the whole-body PUT, `Cloudflare Tunnel Write` as the scope name, connectors from `/connections`, the 50-token limit (`token_limit`), the carry-forward drop of a gone service, the Connectivity scope on every T2 deploy path.

## UAT

None in this sub-goal: its scope is dry seams only (no live Cloudflare call). The live legs are SG-11 (`tests/e2e-members.sh`) and SG-12.

## Rollback

- A tenant turned to T2 goes back with `share setup <host> --r2 --bucket <name> --no-members` once every member is removed (it drops `MEMBERS`, `PAUSED`, the marker keys and `members=on`).
- The code: revert the squash commit. A T1 tenant holds no member object, so nothing persists; a v0.9 CLI on a T2 tenant fails closed on member records (OC-01 to OC-06).
- Nothing was deployed by this sub-goal.
