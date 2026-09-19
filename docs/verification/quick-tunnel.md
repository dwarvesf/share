# Proof of done: quick-tunnel

Date: 2026-09-19
Branch: feat/quick-tunnel

## Green run

```
Command: bash tests/share.sh
Exit:    0
Checks:  120 ok, 0 FAIL (PASS)
Tail:    === NEGATIVE CONTROL: a host outside hosts must not serve ===
           ok    start refused on another host
         PASS
Verdict: PASS
```

Covers: `setup --quick` (mode/hosts/port, no token/cert/DNS), named<->quick
setup refusal both directions, `--quick` + hostname usage error, URL parsed
from the fake cloudflared banner into `quick.url`, status + `share add`
links on the trycloudflare host, snapshot and live shares served locally,
`--host` refused naming teardown, restart yields the new URL and links move
to it, `rm` by pasted quick link, no-URL and died-before-URL serve deaths
(caddy + prune loop reaped, verified by `wait_code 000` and no orphan
listeners on the port), `SHARE_TUNNEL=0` local-only unchanged, quick
teardown leaves shares and makes no Cloudflare calls.

Process-lifecycle findings folded into the same diff (they are what the
suite exposed): the prune loop now redirects to `serve.log` so an orphaned
`sleep 3600` cannot hold a caller's `$( )` pipe open for an hour; the EXIT
trap `pkill -P`s the loop's current sleep before killing the subshell; the
pid vars are global, not `local`, because bash unbinds locals before the
EXIT trap runs on a normal function return, which left `kill` with no args
and orphaned caddy + the loop whenever cloudflared died mid-session.

## Negative control

```
Command: sed 's/head -1 || true)/head -1)/' bin/share; bash tests/share.sh
Result:  RED — exit 1, 8 FAILs:
           FAIL  quick.url parsed from the log
           FAIL  status shows the quick URL
           FAIL  quick link is on the trycloudflare host
           FAIL  quick live link
           FAIL  no URL dies            (rc 2: set -e aborts on the first
           FAIL  die names cloudflared.log   empty poll, before the fake
           FAIL  caddy reaped on parse death  flushes its banner)
           FAIL  stop takes links down
         (the poll's `|| true` is load-bearing under set -e, not noise)
Command: restore; bash tests/share.sh
Result:  GREEN — 120 ok, 0 FAIL, exit 0
Verdict: PASS (revert -> RED -> restore)
```

Plus the suite's own standing negative control, last in every run: a host
outside `hosts` must not serve.

## Test plan coverage

Map from SPEC-002's `## Test plan` matrix to the run above (check labels
from `tests/share.sh` output):

| Row | Covered by |
|---|---|
| 1 | `config has mode=quick`, `no tunnel_id written`, `no cert or token` |
| 2 | `quick setup refuses over a named config`, `names teardown` |
| 3 | `named setup refuses over a quick config`, `names teardown again` |
| 4 | `setup --quick <host> is a usage error` |
| 5 | `quick.url parsed from the log`, `status shows the quick URL` |
| 6 | `quick link is on the trycloudflare host`, `quick file answers locally` |
| 7 | `quick live link`, `quick live proxies` |
| 8 | `--host refused in quick mode`, `--host message names teardown`, `no host row written` |
| 9 | `restart yields the new URL`, `links move to the new host` |
| 10 | `no URL dies`, `die names cloudflared.log`, `caddy reaped on parse death` |
| 11 | `quick teardown exits 0`, `config trashed`, `quick.url gone` |
| 12 | `rm accepts a pasted quick link` |
| 13 | `tunnel=0 still serves locally` |

Not covered locally: a real `cloudflared tunnel --url` against the live
Cloudflare edge (the suite uses the documented fake seam). Verify by hand
before release: `share setup --quick && share start` on a real install.
