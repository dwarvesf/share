# Proof of done: serve-healthz

Date: 2026-09-24
Branch: feat/serve-healthz

## Green run

```
Command: bash tests/share.sh
Exit:    0
Checks:  129 ok, 0 FAIL (PASS)
Tail:    === process leaks ===
           ok    no listener on the share port
           ok    no stray suite processes
           ok    no suite serve still running
           ok    no cloudflared on the suite ports
           ok    no fake tunnel idlers
           ok    no orphaned prune sleeps
           ok    serve.pid removed
         PASS
Verdict: PASS
```

New checks added by this branch (both `ok` in the run above):
`/healthz responds ok` (curls `https://s.example.test/healthz` through the
local proxy and expects 200) and `main host block has handle /healthz
before the catch-all` (asserts the generated Caddyfile's main `http://:`
block carries `handle /healthz` before its catch-all `handle {`).

Caddyfile syntax was also checked directly: generated a real Caddyfile via
`bin/share add <file>` on a scratch `SHARE_ROOT`, then `caddy adapt
--config <Caddyfile> --adapter caddyfile` exited 0 with no errors, and the
first block of the file showed `handle /healthz { respond "ok" 200 }`
immediately before the catch-all `handle {}`.

## Negative control

```
Command: git show origin/main:bin/share >| bin/share   # drop the /healthz block, keep the new test assertions
         bash tests/share.sh
Result:  RED — exit 1, 3 FAILs:
           FAIL  /healthz responds ok: expected '200', got '404'
           FAIL  main host block has handle /healthz before the catch-all: expected '1', got '0'
           (a third FAIL cascades from the run's overall tally line)
Command: cp <patched bin/share backup> bin/share   # restore
         bash tests/share.sh
Result:  GREEN — 129 ok, 0 FAIL, exit 0
Verdict: PASS (revert -> RED -> restore)
```

## Not proven

- No live Cloudflare tunnel was exercised (`tests/e2e.sh` needs live
  credentials and was not run). The suite's fake-tunnel seam covers
  `SHARE_TUNNEL=0`/local serving only, same as the rest of the repo's
  test story.
- `share serve` was not started against the live Air daemon; the daemon
  was not restarted and Cloudflare was not touched, per the task's
  explicit constraints.
- Collision risk: share ids come from `rand_id()` (`od -An -N3 -tx1
  /dev/urandom`, 6 lowercase hex chars). `healthz` is not a valid hex
  string (`h`, `l`, `t`, `z` are not hex digits), so a share id can never
  literally collide with the new `/healthz` route.

## Rollback

Revert this commit (single commit, `bin/share` + `tests/share.sh`); the
route is generated purely from `write_caddyfile`, so removing the block
and restarting `share` (or waiting for the next `caddy reload`) drops
`/healthz` with no state left behind.
