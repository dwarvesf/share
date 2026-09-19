# Proof of done: live-shares

Date: 2026-09-19
Branch: feat/live-shares

## Green run

```
Command: shellcheck bin/share tests/share.sh tests/e2e.sh && bash tests/share.sh
Exit:    0
Checks:  90 ok, 0 FAIL (PASS)
Tail:    === NEGATIVE CONTROL: a host outside hosts must not serve ===
           ok    start refused on another host
         PASS
Verdict: PASS
```

Covers: opts column and five-column compat, live proxy through `handle_path` (a second caddy as the origin), refused ports (80, caddy's own, metrics, >65535), live `refresh`/`rm`/`hits`, generated folder index + `--no-index` + refresh, `--host` under `SHARE_HOST_DRY=1` with call-order asserts, tampered-ingress refusal, held-lock timeout, serve-restart render, reload-failure survival.

`tests/e2e.sh` gained a `--host` leg (live backend, record + rule create/delete, teardown sweep). Not run: needs a real zone and token; run by hand before release.

## Negative control

```
Command: sed 's/tport -ge 1024/tport -ge 1/' bin/share; share add 80
Result:  RED — a live share for port 80 was published:
           https://s.example.test/31ac31/
         (the refusal is load-bearing, not a no-op)
Command: restore; share add 80
Result:  GREEN — "share: 80 is below 1024; a share of a system service is never a dev server", exit 1
Verdict: PASS (revert -> RED -> restore)
```

Plus the suite's own standing negative control, last in every run: a host outside `hosts` must not serve.

## Test plan coverage

Map from the spec's `## Test plan` matrix to the run above (check labels from `tests/share.sh` output):

| Row | Covered by |
|---|---|
| 1 | `live row in ls` (mixed rows in one index), `rm by link unpublishes` |
| 2 | `backend fixture answers`, `live proxies, prefix stripped` |
| 3 | `live link ends /<id>/`, `live warning on stderr`, `absolute-paths caveat` |
| 4 | `add 80 refused` .. `refused adds left no rows` (80, caddy port, metrics port, 99999, each with reason named) |
| 5 | `refresh live exits 0`, `nothing to refresh` |
| 6 | `rm reloads caddy, prefix 404s` |
| 7 | `hits counts live share` |
| 8 | `folder without index gets a listing`, `txt linked by name`, `.md listed by its render` |
| 9 | `--no-index keeps the 404` (same fixture shape as row 8) |
| 10 | `README render is the index`, `no generated list under a README` |
| 11 | `refresh keeps the listing` |
| 12 | `nested file listed by path`, `no subfolder entry` |
| 13 | `host link is the fqdn`, `deep link serves index.html`, `ingress PUT before CNAME POST` |
| 14 | `DELETE CNAME before ingress PUT`, `host share 404 after rm` |
| 15 | `two-label host refused`, `foreign zone refused`, `one-label message` x2 |
| 16 | `no credential refused`, `no row for refused host` |
| 17 | `tampered ingress refused`, `dashboard hint`, `no PUT logged` |
| 18 | `held lock refuses`, `lock message` (under SHARE_HOST_LOCK_TIMEOUT=1) |
| 19 | `dead backend still adds`, `warns nothing answers`, `dead share returns 502` |
| 20 | `Caddyfile has handle_path`, `Caddyfile has the host block`, `no admin off`, `fresh host answers after restart` |
| 21 | `add still exits 0`, `reload error names caddy.log`, `row survives reload failure` |
| 22 | `start refused on another host` (last check in the suite) |
| 23 | SKIP-local: leg added to `tests/e2e.sh`, run by hand with a real zone + token before release |
