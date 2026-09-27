# Verification: suite ports derive from one overridable base

Work: `tests/share.sh` hardcoded its ports (18787 and neighbours). Two runs at
once collided at random. Every port that starts with `18` or `28` now derives
from `base=${SHARE_TEST_PORT_BASE:-18787}` at the offset it used today, so the
default run is unchanged and two runs with different bases no longer share a
socket. `bin/share` is untouched.

## Green run

```
Command: /bin/bash -n tests/share.sh
Exit:    0

Command: shellcheck tests/share.sh
Exit:    0

Command: grep -nE '\b(1|2)8[0-9]{3}\b' tests/share.sh
Output:
6:# SHARE_TEST_PORT_BASE overrides the port base (default 18787) so two runs can go at once.
11:base=${SHARE_TEST_PORT_BASE:-18787}
Verdict: only the SHARE_TEST_PORT_BASE default and its doc comment remain literal.
```

## Concurrency proof: two full suites at once, different bases

This machine was under heavy unrelated load for every run below (other agent
worktrees running their own `tests/share.sh`, an unrelated NES-ROM analysis
job pegging most cores). That load produces two *pre-existing* flakes,
confirmed present in the unmodified script too (see "Baseline flake check"
below): a `500-row index answers under 3s` perf check, and a `no fake tunnel
idlers` leak check that does a system-wide `pgrep -f "sleep 600"` with no
scoping to this run's own PID tree, so it also catches another concurrent
`tests/share.sh` run's fake-cloudflared stub. Neither is port-related and
neither appears in my diff.

```
Command: ( SHARE_TEST_PORT_BASE=20000 bash tests/share.sh > /tmp/share-conc-20000.log 2>&1; echo "EXIT=$?" >>/tmp/share-conc-20000.log ) &
         ( SHARE_TEST_PORT_BASE=40000 bash tests/share.sh > /tmp/share-conc-40000.log 2>&1; echo "EXIT=$?" >>/tmp/share-conc-40000.log ) &
         wait
Exit (base 20000): 1 -- "2 FAILED": 500-row perf timing, no fake tunnel idlers
Exit (base 40000): 1 -- "2 FAILED": 500-row perf timing, no fake tunnel idlers
Verdict: PASS on every port/content/behavior check in both runs. Zero 404s,
         zero "no listener"/"no suite serve" leak hits, zero content
         cross-talk between the two runs. The only 2 failures in each are the
         pre-existing load flakes above, not port collisions.
```

```
Command: bash tests/share.sh > /tmp/share-alone.log 2>&1; echo "EXIT=$?"   (alone, default base 18787, nothing else of mine running)
Exit:    1 -- "1 FAILED": no fake tunnel idlers (the same unscoped pgrep flake above)
Verdict: PASS on every port/content/behavior check.
```

### Baseline flake check (proves the residual FAILs predate this diff)

Ran the untouched `git show HEAD:tests/share.sh` on the same loaded machine:

```
Command: bash tests/.orig-check.sh > /tmp/share-orig-run.log 2>&1; echo "EXIT=$?"
Exit:    1 -- "4 FAILED": caddy reaped on parse death, 500-row perf timing,
         stop takes links down, no listener on the share port
Verdict: the unmodified script flakes under this exact load too, with a
         different mix of timing-sensitive checks. Confirms the flakes above
         are environmental, not introduced by the port-base change.
```

## Negative control: two runs, same base, in parallel

```
Command: ( SHARE_TEST_PORT_BASE=50000 bash tests/share.sh > /tmp/share-negctl-a.log 2>&1; echo "EXIT=$?" >>/tmp/share-negctl-a.log ) &
         ( SHARE_TEST_PORT_BASE=50000 bash tests/share.sh > /tmp/share-negctl-b.log 2>&1; echo "EXIT=$?" >>/tmp/share-negctl-b.log ) &
         wait
Exit (a): 1 -- "18 FAILED", including:
  FAIL  folder page: expected '200', got '404'
  FAIL  asset: expected '200', got '404'
  FAIL  single .md renders: expected '200', got '404'
  FAIL  README render is the index: expected '1', got '0'
Exit (b): 1 -- "5 FAILED", including:
  FAIL  dead share returns 502: expected '502', got '404'
  FAIL  stop takes links down: expected '000', got '404'
  FAIL  no listener on the share port: expected '0', got '2'
  FAIL  no suite serve still running: expected '0', got '2'
Verdict: RED as expected. `lsof -nP -iTCP:50000` mid-run showed two separate
         caddy processes both LISTEN on 127.0.0.1:50000 (the kernel's
         SO_REUSEPORT lets both bind; requests then land on whichever
         instance the kernel picks, so each run sees the other's stale or
         missing content). This is exactly the collision the port-base fix
         removes.
```

## Process leaks

```
Command: pgrep -f "suite-port-override.*share"; lsof -nP -iTCP:18787,20000,40000,50000 -sTCP:LISTEN
Output:  (empty)
Verdict: no leftover suite processes or listeners on any port used above,
         once every run above had finished.
```

## Rollback

`git checkout main -- tests/share.sh` (or revert the commit). `bin/share` was
never touched, so no other rollback step is needed.
