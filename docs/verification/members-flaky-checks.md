# Proof of done: members-flaky-checks

Date: 2026-11-20
Branch: fix/members-flaky-checks (base 9c2179c; fix at 118804d, the bash 3.2 trap form at 1cc5f0a)

## Root cause

| Check | CI signature | Race |
|---|---|---|
| `mm CK-02, TASK-2b` (members-a, macOS) | expected `1 0`, got `0 0` | The step before starts a member serve (`SHARE_PRUNE_EVERY=1`) and stops it as soon as `LOOP` is logged, which is mid-pass. serve's EXIT trap `pkill -P $loop_pid` reaches the `prune --loop` bash but not its `( r2_prune loop; r2_reconcile )` subshell, so the pass ran on after `stop` returned. Its row 5 deleted the next step's own-origin tombstone `t/ee0020` (reproduced: the member's `r2-calls.log` held `GET t/ee0020`, `DELETE t/ee0020`). **Product bug**: on a member machine, a service-less `start` then `stop` leaves a bucket writer alive. |
| `mm CC-14 (add-first)` (members-a, Ubuntu) | expected `0 0 2 1 0`, got `0 1 2 1 0` | The dry bucket's PUT wrote objects in place (`cp src f`). The setup's 0.2 s lease poll read a torn `lock/admin`, judged the holder unreadable and so stale, and took it over with an If-Match on the etag of the finished write. The add's next `lease_renew` got 412: `lease_lost`. The CI log shows `lease: took over from (unreadable) (? ?, step 0)`. **Test seam only**: an R2 PUT is atomic. |

## Fix

- `cmd_serve`: the prune loop runs its sleep and its prune as jobs and waits on them under a TERM trap that kills and reaps the current one.
- `prune_loop_member`: the bucket pass runs as a job, waited on under a TERM/INT trap that kills and reaps it. On a member machine, `stop` now returns only after the pass is gone.
- Both traps run `set +u` before they read `$!`: macOS bash 3.2 calls an unset `$!` unbound under `set -u`, even as `${!:-}`.
- `r2_dry` PUT: writes a dot-named temp beside the key, then renames it. LIST already skips dot names.

## Green run

```
Command: SHARE_TEST_PORT_BASE=44000 SHARE_TEST_ONLY='members: (tenant T1 to T2|revoke and reconcile)' bash tests/share.sh
         x10 at 1cc5f0a, each under 4 `yes >/dev/null` load processes (14-core Mac), no other suite running
Exit:    0 on all 10 runs
Output:  run 1..10 (each): 78 checks, PASS (filtered by SHARE_TEST_ONLY: 2 sections ran, the rest skipped)
         every run:  ok  mm CC-14 (setup-first) ...;  ok  mm CC-14 (add-first) ...;  ok  mm CK-02, TASK-2b ...
         CC-14 add-first 10/10 ok, CK-02 10/10 ok, 0 FAIL in any run
Verdict: PASS
```

Also green:

- The same 10x loop at 118804d (the `${!:-}` trap form): 10/10 exit 0, each `78 checks, PASS`.
- At 1cc5f0a with the CLI on macOS `/bin/bash` 3.2 (a `bash -> /bin/bash` symlink first on `PATH`): `78 checks, PASS`, CC-14 and CK-02 ok. The widened negative control below is also green on 3.2.
- `/bin/bash -n bin/handout` and `shellcheck bin/handout install.sh tests/members.sh` are clean.
- A wider filtered run at 118804d: 57 sections (of 93 in the suite), serve, r2, tenant and members included: `1407 checks, PASS`.

Before the fix, the same CK-02 section went red in 1 of 6 runs under the same load (`expected '1 0', got '0 0'`, with the member log showing `DELETE t/ee0020`).

## Negative control

The natural races are rare, so a temporary test edit widens both on purpose. It is not committed:

- CK-02: the TASK-2c serve starts with `SHARE_R2_DRY_PAUSE="LIST t/"`, so its pass is held at its t/ list. Once the tombstones are built, `.resume` releases any pass that outlived `stop`, and the test waits up to 10 s for its `DELETE t/ee0020`.
- CC-14 add-first: the add runs with a `cp` stub first on `PATH`. The stub writes a `*/lock/*` destination in two halves 0.6 s apart, so a lease read can land between them.

```diff
-    ( mxo_env=(SHARE_R2_DRY_PAUSE='API PUT /accounts/acct-dry/workers/scripts/share-mx-example-test'); SHARE_TEST_MEMBER_IDS=m-an-aaaaaaa1 mxo add an --port $((base + 372)) >"$MX/cc14b.out" 2>&1 ) & pb=$!
+    mkdir -p "$MX/slowcp"; printf '#!/bin/bash\ncase ${2:-} in */lock/*) head -c 20 "$1" >"$2"; sleep 0.6; tail -c +21 "$1" >>"$2" ;; *) exec /bin/cp "$@" ;; esac\n' >"$MX/slowcp/cp"; chmod +x "$MX/slowcp/cp"
+    ( PATH="$MX/slowcp:$PATH"; mxo_env=(SHARE_R2_DRY_PAUSE='API PUT /accounts/acct-dry/workers/scripts/share-mx-example-test'); SHARE_TEST_MEMBER_IDS=m-an-aaaaaaa1 mxo add an --port $((base + 372)) >"$MX/cc14b.out" 2>&1 ) & pb=$!
-mxm_env=(SHARE_PRUNE_EVERY=1 CLOUDFLARE_API_TOKEN=admintoken); mxm start >/dev/null 2>&1; mxm_env=()
+mxm_env=(SHARE_PRUNE_EVERY=1 CLOUDFLARE_API_TOKEN=admintoken SHARE_R2_DRY_PAUSE="LIST t/"); mxm start >/dev/null 2>&1; mxm_env=()
 rx_tomb ee0021; mx_aged 2700000 "$MX_DRY/t/ee0021"
+: >"$MX_DRY/.resume"; for _ in $(seq 1 40); do grep -q '^DELETE t/ee0020' "$MXM_LOG" && break; sleep 0.25; done; rm -f "$MX_DRY/.resume" "$MX_DRY/.paused"
```

```
Command: git show 9c2179c:bin/handout >| bin/handout   # the pre-fix CLI, races widened
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

- CI itself: nothing is pushed, so neither shard has run the fix on the hosted macOS or Ubuntu runners.
- The origin's hourly bare `prune` (`cmd_prune`, the `r2on` branch) got the same job-and-trap form in a follow-up commit on this branch. `SHARE_TEST_ONLY='tenant|r2|prune'` passed (1326 checks, 53 sections). No check stops an origin mid-pass, so that fix has no negative control.
- No permanent deterministic test covers the stop fix. The widened control above is the only deterministic check, and it is not committed.
- The installed-service path: launchd and systemd reap the process group on stop anyway. This proof covers the service-less `start` and `stop` only.
- A TERM still orphans one external command already in flight inside the pass (one `curl` or `cp`). It finishes that call; no new call starts after the trap.
- A dry GET still reads the body and the etag in two steps, so it can pair the old body with the new etag. That can no longer make a lease look stale, because every body it reads is complete. It is not otherwise proven harmless.
- `lease_live` treats an unreadable holder as stale at once, but its comment says "judged by its age alone". This is untouched here. R2 GETs are atomic, so it matters only for a forged body.
- The full suite was not run, as asked. The widest run covered 57 of 93 sections.
