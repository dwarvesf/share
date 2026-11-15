# Proof of done: fast test loop (SHARE_TEST_ONLY, section timing, idle waits)

Date: 2026-11-15
Branch: test/fast-test-loop
Contract: the sub-goal file (Design: obvious; no spec text)
Notes: docs/implementation-notes/fast-test-loop.md

Every check ran on the Mac Mini in the branch worktree or in a clone of it (a filtered run in a clone so two suites never share one `bin/share` path: the process-leak checks count by that path).

## Recorded run

```
Command: /bin/bash -n tests/share.sh && /bin/bash -n tests/members.sh && shellcheck bin/share tests/share.sh tests/members.sh
Exit:    0
Verdict: PASS (bash 3.2 parse of both files, no shellcheck finding)
```

```
Command: SHARE_TEST_PORT_BASE=36000 bash tests/share.sh   (before: a copy of the worktree at main 7b39971, git history present)
Exit:    0
Verdict: PASS, "1826 checks, PASS"
```

```
Command: SHARE_TEST_PORT_BASE=36000 bash tests/share.sh   (after, the branch worktree, unfiltered, the third run, after the review folds)
Exit:    0
Verdict: PASS, "1826 checks, PASS", the same count as before; total 1294 s
```

Two earlier unfiltered runs (before the review folds) of the branch also totalled 1826 checks and each failed one check. The first failed `no suite serve still running`: 24 serve processes left by sweep runs I had killed (my debris; killed). The second failed `mm CC-14 (add-first)`, the load flake the lead already logged (a lease read racing a release); that section alone passes: `SHARE_TEST_ONLY='^members: member add$'` gave "34 checks, PASS".

```
Command: SHARE_TEST_ONLY='^members: member add$' SHARE_TEST_PORT_BASE=30000 bash tests/share.sh
Exit:    0
Verdict: PASS, "34 checks, PASS"; 81 `skip <section>` lines, one per skipped section; the shared fixtures and the tail sections ran.
```

```
Command: SHARE_TEST_ONLY='^members: the invite seal$' SHARE_TEST_PORT_BASE=31500 /bin/bash tests/share.sh   (macOS /bin/bash 3.2.57)
Exit:    0
Verdict: PASS, "18 checks, PASS (filtered by SHARE_TEST_ONLY: 1 sections ran, the rest skipped)"; 81 skip lines. Group resolution ran under 3.2 too: a `groundwork` filter printed the `core` sections first.
```

```
Command: SHARE_TEST_ONLY='^state groundwork: G5$' SHARE_TEST_PORT_BASE=30800 bash tests/share.sh
Exit:    0
Verdict: PASS, "845 checks, PASS" in 563 s: the group pulled `core`, every `state groundwork: G*` and `migrate: moving`; 41 sections skipped.
```

```
Command: SHARE_TEST_ONLY='(' bash tests/share.sh ; SHARE_TEST_ONLY='^NOMATCHX$' bash tests/share.sh
Exit:    2 for both
Verdict: PASS (an invalid regex and a filter that names no section both stop before any test)
```

```
Command: node tests/worker.mjs   (run inside the suite)
Exit:    0
Verdict: PASS ("worker.mjs exits 0")
```

## Section filter (Done = a)

- `SHARE_TEST_ONLY` is an extended regex matched against the `=== name ===` text of every section in `tests/share.sh` and `tests/members.sh`. `MX_ONLY` is gone (it was members-only and matched a substring).
- Each section is `if section "<name>"; then ... fi`. `section_always` marks setup: the two shared-fixture sections, `stop`, the host-guard control, the abort self-test, the process-leak checks and the final pidfile check. A skipped section prints one `skip <name>` line.
- Groups sit in a comment block at the top of `tests/share.sh` (`# group <name> = <ERE>`, `# pull A -> B`). Naming any member runs the whole group. Groups: `core` (the old single-host sections through `skill`), `r2` (r2 backend, tenant, import and migrate, which pulls `core`), `groundwork` (every `state groundwork: G*`, which pulls `migrate: moving` and `core`), `late` (`members: phase 0`, which pulls `core`, `r2` and `groundwork`). The `members:` sections after their shared fixtures need no group: each ran alone and passed.
- Validation sweep (sections run alone in clones, five at a time): every `members:` section and the worker section passed alone. A `core` run, an `r2` run (which runs `core` first) and a `late` run (the whole old suite) passed, apart from three artifacts of running suites side by side: a `sleep 3600` orphaned by another suite's exit (the leak check counts it), one `email: the gated file answers locally` 404 under load in the `core` run that passed in every unfiltered run, and port clashes when I reused a base for two sweeps. A `groundwork` run without `core` hung at `serve on a busy port` (it needs the suite's own server holding the port), which is why `groundwork` pulls `core`. `urldec` and `state_schema_ok` moved to the suite header because sections of two groups used them.
- The `stop` section is `section_always` now. Its `stop takes links down` check runs only when `md_url` is set (the add section sets it), so a full run keeps its check count and a filtered run no longer leaves a server running into the host-guard control.

## Timing table (Done = b)

Every run ends with `=== timing: seconds per section, slowest first ===` and a `total`, then `=== waits ===`: every stretch of 5 s or more before a check, with the check that ended it. Sample (unfiltered run, after):

```
    130s  access: a login gate per link (SHARE_ACCESS_DRY=1, every Cloudflare call answered from fixtures)
    106s  r2 backend: byte identity of existing installs (compat)
     97s  state groundwork: G2c
     95s  members: member rm and member purge (TASK-2d)
  total 1205s
```

## Idle waits (Done = c)

| Wait | Before | After | Action |
|---|---|---|---|
| `cf() with a sleeping curl still returns within 35s` | 30 s | 1 s | the fake curl records the `--max-time` it was handed and exits at once; the check still needs the verb to return and every call to carry 35 s or less |
| refresh racing rm | 60 s | 48 s (load) | not a test sleep: one `add` of a 300-file folder takes 14 s wall for 2 s CPU in `bin/share` |
| G2c, DP, MB die-point loops | 29 to 42 s each | same | each iteration is 3 to 6 s of real verbs; the pause seam already waits on the condition (`gw_wait_step`, `gw_gone`, 0.1 to 0.2 s polls) |
| CD-01 start whose serve never answers | 21 s | 31 s (load) | `wait_running 10` is fixed in `bin/share`, twice per check |

The measurements show the idle time of the die-point loops and the racing section sits in `bin/share`, outside this sub-goal's Touches. The follow-up is in the HANDOFF: a knob for `wait_running` and a look at why one `add` idles for 12 s.

The harness-only timing run I used for the "before" column was a copy without git history, so its byte-identity compat sections (106 s) did not run; the "after" run has them. Compare per row, not the totals (1225 s, then 1205 s).

The rewritten stall test no longer catches a retry loop whose total time passes 35 s (the fake curl returns after 1 s); it still fails on a missing or oversized `--max-time`. Today `cf()` makes one call, so nothing is lost.

The whole suite was not run under `/bin/bash` 3.2: only `tests/share.sh` and `tests/members.sh` changed, `bin/share` did not, and the two filtered runs above (a section, and a group resolving) ran under 3.2.57.

## Rollback

Revert the commit: the test files return to the unfiltered suite and `MX_ONLY`. No deploy, Worker, setup or persistent state is touched.
