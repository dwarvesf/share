# Verification: Caddy listed rows and Worker v5 (SPEC-009 Phase 0)

Scope: SPEC-009 TASK-0a to 0f on branch `feat/worker-v5-listed-rows`, built on main at f28cb13. Nothing was deployed live: Worker v5 is inert for T0 and T1 tenants, and this sub-goal touched no real tenant.

## Recorded run

Run 2026-11-15 on the Mac Mini, Caddy from Homebrew, node 24.

| Check | Command | Exit | Verdict |
|---|---|---|---|
| bash 3.2 parse | `/bin/bash -n bin/share && /bin/bash -n tests/share.sh` | 0 | pass |
| lint | `shellcheck bin/share bin/release tests/share.sh` | 0 | pass |
| Worker rows | `node tests/worker.mjs` | 0 | pass: 287 ok, 153 of them `v5` rows, `PASS` |
| full suite, `bin/share` under macOS `/bin/bash` 3.2 | `PATH="<shim dir with bash -> /bin/bash>:$PATH" SHARE_TEST_PORT_BASE=22500 /bin/bash tests/share.sh` | 1 | 1455 of 1456 pass; the one failure is environmental, see below |
| that failure, after its cause was removed | `ps -eo ppid,command \| awk '$1==1 && $2=="sleep" && $3=="3600"' \| grep -c .` | 0 | pass: 0 |

Command: `PATH="<shim>:$PATH" SHARE_TEST_PORT_BASE=22500 /bin/bash tests/share.sh`
Exit: 1
Verdict: pass for this change. The only failing check, `no orphaned prune sleeps`, counts every orphaned `sleep 3600` on the machine. It found one started at 02:23:24, before this run, by a scratch Caddy probe of the builder's (a serve whose parent the builder killed). That process was removed and the same check expression then counted 0. Every `mm` row, both SPEC-008 compat row 1 checks, and every other section passed.

Command: `node tests/worker.mjs`
Exit: 0
Verdict: pass (SV-10 to SV-24, SV-26 to SV-28, FG-12, OC-05, OT-07, OT-13, OT-18, the redeem rows, and SV-26's sweep: every one of 185+ answers carries a named row, every Worker 404 has the one body, no header names a row).

Command: `bash tests/share.sh` section `=== members: phase 0 ... ===`
Exit: (inside the full run above)
Verdict: pass: OT-19, SV-01 to SV-05, FG-16, SV-06 to SV-09, OC-01, DY-01 to DY-05, TN-10, and the probe-file and 404-body rows.

Run history, for honesty: run 1 (normal PATH) was stopped early. A dry-seam bug (`gate` read before it was set in the fake `/healthz`) failed 48 checks in sections that deploy, and the compat-row edit had not been applied. Run 2 (bash 3.2) ended with 7 failures, all test fixture or ordering mistakes. The advisor critique landed between runs 2 and 3; its folds are in the implementation notes (B9 to B15). Run 3 is the one recorded above. That is three runs, one more than the sub-goal's budget of two.

Not run: `swift test --package-path mac` and `bash mac/build.sh 0.0.0` (no `mac/` change in this sub-goal); live legs (SG-11).

## Negative controls

Each mutation is applied to a copy of `bin/share`. The named row goes red on the copy and green on HEAD.

| NC | Mutation | Row | Mutated | HEAD |
|---|---|---|---|---|
| NC-2 | restore the whole-tree catch-all `root * "$pub"; file_server` | `mm SV-01` unlisted bytes | 200 | 404 |
| NC-3 | drop the v:2 `expires` check in the Worker | `v5 SV-10` | `503 1` (passed to origin) | `404 0` |
| NC-4 | forward every request header to the binding | `v5 SV-21` | authorization, cookie and cf-access-* reach it | only accept*, if-none-match, range, user-agent |
| NC-5 | answer the envelope with no claim and no delete | `v5 SV-15` | second redeem 200 | 404 |
| NC-6 | `r2_deploy_meta` ignores the carried bindings | `mm DY-01` | `''` (binding and PAUSED lost) | `M_aaaaaaa1,PAUSED` |
| NC-12 | `r2_record_raw` reads only v:2 as a pointer | `mm SV-06` | sweep skipped (0) | upload swept (1) |
| NC-13 | the Worker ignores `PAUSED` | `v5 SV-12` | `200 member bytes 1` | `503 ... 0` |
| NC-15 | serve a binding answer without `X-Share-Served` | `v5 SV-22` | `200 python says hi` | `503` offline page |
| NC-16 | `rand_id` skips the `t/` check | `mm SV-09` | lands on `ad0001` | `ad0002` |

Commands: `SHARE_WORKER_SRC=<mutated copy> node tests/worker.mjs` for the Worker rows. For the bash rows, a scratch harness rebuilt each row's fixture from the suite's own helpers (a tenant origin over a dry bucket; a Caddy profile on its own port) and ran it against both copies. NC-7 to NC-11 and NC-14 belong to Phase 1 and 2 tasks.

## Rollback

- Worker: a deployed v5 rolls back to v4 with an older CLI's `share setup <host> --r2 --bucket <name> --force`, only while no `vpc_service` binding exists. This CLI refuses such a downgrade while a member binding, `MEMBERS`, a non-empty `PAUSED`, or `members: true` is present (DY-03). Before Phase 1 no tenant has any of these, so the rollback is open.
- CLI: reinstall the previous release (`brew reinstall share` at v0.9.0). The Caddyfile is re-rendered from `index.tsv` on the next `start`, `add`, `rm`, `refresh` or `prune`, so the old whole-tree handle comes back with the old CLI.
- Persistent state: none written by this change beyond today's shapes. `index.tsv` rows may gain `revoked` only from Phase 2 code. The deploy adds a `DEPLOY` plain-text binding, which an older CLI's next deploy drops.

## UAT

None live. Worker v5 was exercised only in `tests/worker.mjs` and the dry deploy seam. The first live leg is SG-11 (`tests/e2e-members.sh`), after the owner turns R2 on for Console Labs.
