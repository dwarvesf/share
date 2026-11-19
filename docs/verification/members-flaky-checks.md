# Proof of done: members-flaky-checks

Date: 2026-11-20
Branch: fix/members-flaky-checks (fix at 118804d)

## Root cause

| Check | CI signature | Race |
|---|---|---|
| `mm CK-02, TASK-2b` (members-a, macOS) | expected `1 0`, got `0 0` | The step before starts a member serve (`SHARE_PRUNE_EVERY=1`) and stops it as soon as `LOOP` is logged, which is mid-pass. serve's EXIT trap `pkill -P $loop_pid` reaches the `prune --loop` bash but not its `( r2_prune loop; r2_reconcile )` subshell, so the pass ran on after `stop` returned. Its row 5 deleted the next step's own-origin tombstone `t/ee0020` (reproduced: the member's `r2-calls.log` held `GET t/ee0020`, `DELETE t/ee0020`). **Product bug**: a service-less `start` then `stop` leaves a bucket writer alive. |
| `mm CC-14 (add-first)` (members-a, Ubuntu) | expected `0 0 2 1 0`, got `0 1 2 1 0` | The dry bucket's PUT wrote objects in place (`cp src f`). The setup's 0.2 s lease poll read a torn `lock/admin`, judged the holder unreadable and so stale, and took it over with an If-Match on the etag of the finished write. The add's next `lease_renew` got 412: `lease_lost`. The CI log shows `lease: took over from (unreadable) (? ?, step 0)`. **Test seam only**: an R2 PUT is atomic. |

## Fix

- `cmd_serve`: the prune loop runs its sleep and its prune as jobs and waits on them under a TERM trap that kills and reaps the current one.
- `prune_loop_member`: the bucket pass runs as a job, waited on under a TERM/INT trap that kills and reaps it. `stop` now returns only after the pass is gone.
- `r2_dry` PUT: writes a dot-named temp beside the key, then renames it. LIST already skips dot names.
- `CLAUDE.md`: the lifecycle-trap note gains the third-level subshell case.

## Green run

```
Command: SHARE_TEST_PORT_BASE=44000 SHARE_TEST_ONLY='members: (tenant T1 to T2|revoke and reconcile)' bash tests/share.sh
         x10, each under 4 `yes >/dev/null` load processes (14-core Mac), no other suite running
Exit:    0 on all 10 runs
Output:  run 1..10: 78 checks, PASS (filtered by SHARE_TEST_ONLY: 2 sections ran, the rest skipped)
         every run: ok  mm CC-14 (setup-first) ... ok  mm CC-14 (add-first) ... ok  mm CK-02, TASK-2b ...
         CC-14 add-first 10/10 ok, CK-02 10/10 ok, 0 FAIL in any run
Verdict: PASS
```

Before the fix, the same CK-02 section went red 1 of 6 runs under the same load (`expected '1 0', got '0 0'`, with the member log showing `DELETE t/ee0020`).

Also clean on the fixed tree: `/bin/bash -n bin/handout`, `shellcheck bin/handout install.sh tests/members.sh`, and a wider filtered run (57 sections, serve, r2 and members included): `1407 checks, PASS`.

## Negative control

The natural races are rare, so both are widened on purpose by a temporary test edit (not committed):

- CK-02: the TASK-2c serve starts with `SHARE_R2_DRY_PAUSE="LIST t/"`, so its pass is held at its t/ list. After the tombstones are built, `.resume` releases any pass that outlived `stop`.
- CC-14 add-first: the add runs with a `cp` stub that writes a `*/lock/*` destination in two halves 0.6 s apart, so a lease read can land between them.

```
Command: git show HEAD~1:bin/handout >| bin/handout   # the pre-fix CLI, races widened
         SHARE_TEST_PORT_BASE=44000 SHARE_TEST_ONLY='members: (tenant T1 to T2|revoke and reconcile)' bash tests/share.sh
Exit:    1
Output:  lease:      took over from (unreadable) (? ?, step 0) (stale since ...)
         handout: another admin verb took lock/admin over while this one held it (stale past 900 s); nothing more was changed
           FAIL  mm CC-14 (add-first): ... expected '0 0 2 1 0', got '0 1 2 1 0'
           FAIL  mm CK-02, TASK-2b: ... expected '1 0', got '0 0'
         2/78 FAILED
Verdict: RED as expected. Both CI signatures appear exactly, so the checks catch each race.

Command: git checkout -- bin/handout   # the fix restored, races still widened
         (same command)
Exit:    0
Output:    ok    mm CC-14 (add-first): ...
           ok    mm CK-02, TASK-2b: ...
         78 checks, PASS
Verdict: PASS (mutate -> RED -> restore -> GREEN)
```

## Not proven

- CI itself: no push, so neither shard has run the fix on the hosted macOS or Ubuntu runners.
- The installed-service path: launchd and systemd reap the process group on stop anyway. This proof covers the service-less `start` and `stop` only.
- A TERM still orphans a single external command already in flight inside the pass (one `curl` or `cp`). It finishes its one call; no new call starts after the trap.
- A dry GET still reads the body and the etag in two steps, so it can pair the old body with the new etag. That can no longer make a lease look stale, because every body it reads is complete. It is not otherwise proven harmless.
- `lease_live` treats an unreadable holder as stale at once, but its comment says "judged by its age alone". This is untouched here; the R2 GET is atomic, so it matters only for a forged body.
- The full suite was not run, as asked.
