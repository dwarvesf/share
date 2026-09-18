# Spec: live shares, own hostnames, folder index
Generated: 2026-09-19
Status: VALIDATED
Lane: full
References: `bin/share` `cmd_setup` (the ingress PUT shape and the DNS collision guard to reuse for `--host`); `bin/share` `cf()` (the only way a Cloudflare token may travel: header file, never argv); `tests/share.sh` (the local harness every new behavior lands in: `SHARE_TUNNEL=0`, spare port, throwaway root).

## Problem

See `docs/briefs/DECISION-BRIEF-live-shares.md`. A running dev server cannot be shared, a folder without an index is a dead link, and a built SPA loses its deep links.

## Solution

### Approaches considered

| Approach | Tradeoff |
|---|---|
| A. Path-prefix proxy only (`https://s.example.com/<id>/` -> `127.0.0.1:<port>`) | Zero credentials at add time. Breaks any app that emits absolute asset paths, which is most SPA dev servers. |
| B. Random subdomain per share (`<id>.s.example.com`) via wildcard DNS + ingress | Clean URLs. Second-level wildcard is outside Universal SSL: certificate error unless the account pays for ACM. Rejected. |
| C. Named first-level hostname per share (`dev.example.com`) on `--host`, one CNAME + one ingress rule each | Works for every app. Needs a Cloudflare credential at add time and per-share cleanup. |

### Chosen approach + why

A as the default for live shares, C as the opt-in upgrade for live and snapshot shares. B rejected on the TLS constraint; a zone-wide wildcard CNAME rejected because it would route every undefined name in the zone to this machine. See ADR-0001.

### Extensibility & boundaries

- Growth dimension: number of shares. Each live or host share is one caddy block and, for host shares, one ingress rule and one DNS record. The Caddyfile is regenerated from `index.tsv` on every routing change, so N shares cost N blocks, no per-share state elsewhere.
- Units: `parse_target` (argument -> kind), `write_caddyfile` (index.tsv -> Caddyfile), `caddy_reload`, `host_add` / `host_rm` (Cloudflare side, one hostname), `gen_index` (stage dir -> index.html). Each testable on its own with the local harness, except `host_add` / `host_rm`, which the real-zone `tests/e2e.sh` covers.

## Picture

```
 share add 3000                      share add 3000 --host dev.example.com      share add ./dist --host app.example.com
 https://s.example.com/<id>/         https://dev.example.com                    https://app.example.com
        │                                    │                                           │
 ingress: s.example.com              ingress: dev.example.com                    ingress: app.example.com
   (unchanged)                         httpHostHeader dev.example.com              httpHostHeader app.example.com
        │                            + CNAME dev -> <tunnel>.cfargotunnel.com    + CNAME app -> <tunnel>.cfargotunnel.com
        ▼                                    ▼                                           ▼
 caddy http://:8787                  caddy http://dev.example.com:8787            caddy http://app.example.com:8787
   handle_path /<id>/*                 reverse_proxy 127.0.0.1:3000                 root pub/<id>
     reverse_proxy 127.0.0.1:3000                                                   try_files {path} /index.html
   handle { file_server }                                                           file_server
        ▲
        │ caddy reload over unix//$root/admin.sock, after add / rm / refresh / prune
```

## Design

### Approaches considered + chosen

See `## Solution`.

### Diagram

Lifecycle of a host share (sequence):

```
 user            share add --host           Cloudflare API                 caddy
  │  add 3000 --host dev.example.com │                              │
  │ ───────────────────────────────▶ │  GET dns_records?name=dev    │
  │                                  │ ───────────────────────────▶ │   (collision guard: refuse unless absent
  │                                  │  GET cfd_tunnel/<id>/configurations   or already this tunnel)
  │                                  │  PUT configurations (+1 rule, catch-all still last)
  │                                  │  POST dns_records (CNAME dev -> tunnel)
  │                                  │  append row, write_caddyfile ─────────────────▶ reload
  │  https://dev.example.com         │                              │
  │ ◀─────────────────────────────── │                              │
  │  rm <id>                         │  DELETE dns_records/<rid>    │
  │ ───────────────────────────────▶ │  PUT configurations (-1 rule)│
  │                                  │  drop row, write_caddyfile ──────────────────▶ reload
```

Create order is ingress, then DNS, then row. Delete order is DNS, then ingress, then row. A failure after the ingress PUT on create reverts the PUT before dying. Delete tolerates a missing record or rule (already gone counts as done), so a half-created share can always be removed.

### ADR link(s)

`docs/decisions/ADR-0001-own-hostname-per-share.md`.

### Boundaries & failure modes

Out of bounds: wildcard DNS of any kind; proxying to any host other than `127.0.0.1`; changing what `/` (site root) serves; auth in front of a share. Failure table in `## Failure modes`.

## Technical Design

### Interfaces (I/O contract)

**`share add [--ttl T] [--host FQDN] [--no-index] <file | dir | port | localhost:port | 127.0.0.1:port | http://localhost:port | http://127.0.0.1:port>`**

`parse_target <arg>` returns one of:

| Input shape | kind | `name` column | `src` column |
|---|---|---|---|
| existing path | `snapshot` | `basename` | `realpath` |
| `^[0-9]{2,5}$` | `live` | `localhost:<port>` | `http://127.0.0.1:<port>` |
| `^(localhost\|127\.0\.0\.1):[0-9]+$` | `live` | same | same |
| `^http://(localhost\|127\.0\.0\.1):[0-9]+/?$` | `live` | same | same |
| anything else | error | | `usage:` line |

Live-target rules, checked before any write: port is in `1024..65535`, is not `$port` (caddy) and not `$metrics_port` (cloudflared), else `die` naming the reason. Below 1024 is refused outright (no override flag): a share of CUPS or SSH is never a dev server. `add` prints one warning line for a live share: `share: live share: anyone with the link reaches 127.0.0.1:<port> while this machine is awake`, and for a prefix live share one caveat line: `share: apps that use absolute asset paths (/static/...) break under a path prefix; use --host <name>.<zone>`.

**`index.tsv`**: `id \t name \t src \t date \t exp \t opts`. `opts` is a space-separated list, empty for old rows. Tokens: `live`, `host=<fqdn>`, `noindex`. Every reader uses `read -r id name src date exp opts` or awk `$6`. `row()` unchanged.

**Link**: `share_url` prints `https://<fqdn>/` for a host share, `https://<host>/<id>/` for a prefix live share, and the existing `https://<host>/<id>/<name>` for a snapshot.

**`--host FQDN`**: must match `^[a-z0-9]([a-z0-9-]*[a-z0-9])?\.<zone>$` where `<zone>` is the setup zone name (`cfg zone`, added to config by this spec; for configs without it, resolve the zone as `cmd_setup` does and write it back). One label only: `dev.example.com` yes, `dev.s.example.com` no, with the message `one label under example.com (Universal SSL stops at one level)`. Credential: `CLOUDFLARE_API_TOKEN`, else `cert.pem` via the existing `cf_auth` path; neither: `die "--host needs CLOUDFLARE_API_TOKEN or a browser login (share setup --login)"` before any write. Collision guard as in `cmd_setup`: an existing record is accepted only if it is a CNAME to this tunnel; anything else refuses (no `--force` on add). DNS record create/delete goes through `cf()` in both modes (the `cert.pem` apiToken carries the zone it was authorized for; if the API answers an auth error, `die "the login cert cannot edit DNS records directly: export CLOUDFLARE_API_TOKEN with DNS Edit, or run share setup with the token"`).

**Ingress edit** (`host_add` / `host_rm`): under a `mkdir "$root/.lock-host"` mutex (removed on exit, stale after 60 s), GET the current config, assert the last rule is `http_status:404` and the first rule's hostname is the primary `hostname`, else `die "tunnel ingress was edited outside share; fix it in the dashboard or rerun share setup --force"`. Insert the new rule `{hostname, service: http://127.0.0.1:$port, originRequest: {httpHostHeader: <fqdn>}}` before the catch-all, or drop the one matching rule, PUT. All calls through `cf()`; no new place the token appears.

**Test seams:** `SHARE_HOST_DRY=1` skips every Cloudflare call, reads and writes included: `host_add`/`host_rm` get the "current" ingress config from a canned fixture under `$root/host-fixture.json` when present, else the minimal `{primary rule, catch-all}` shape, and append each intended call (`PUT ingress +1`, `POST CNAME`, `DELETE CNAME`, `PUT ingress -1`) to `$root/host-calls.log`, one per line. `SHARE_HOST_LOCK_TIMEOUT=<secs>` overrides the 60 s mutex wait so tests stay fast.

**Caddyfile** (`write_caddyfile`, rendered from `index.tsv`):

```
{
	admin unix//$root/admin.sock
	auto_https off
}
http://:$port {
	bind 127.0.0.1
	header Cache-Control "no-store"
	header X-Robots-Tag "noindex, nofollow"
	log { ... }
	handle_path /<id>/* {            # one per prefix live share
		reverse_proxy 127.0.0.1:<port>
	}
	handle {
		root * "$pub"
		file_server { index index.html README.html }
	}
}
http://<fqdn>:$port {                # one per host share
	bind 127.0.0.1
	header Cache-Control "no-store"
	header X-Robots-Tag "noindex, nofollow"
	log { ... same file }
	reverse_proxy 127.0.0.1:<port>   # live
	# or, snapshot:
	root * "$pub/<id>"
	try_files {path} /index.html     # only when pub/<id>/index.html exists
	file_server { index index.html README.html }
}
```

`$root` is created `mkdir -p -m 700`, so the admin socket is reachable by the owner only. `caddy_reload` runs `caddy reload --config "$root/Caddyfile" --adapter caddyfile` when `running`, else nothing (the admin address comes from the config's global block). Bash is 3.2-compatible: `case` patterns over `=~`, no arrays, `${var:+...}` for optional flags, no `mapfile`/`read -a`/`local -n`. Called at the end of `cmd_add`, `cmd_rm`, `cmd_refresh` (a refresh can add or remove `index.html`, which flips `try_files`), and once after `cmd_prune` removed anything.

**Folder index** (`gen_index <stage>`), inside `copy()` after `render_md` and before the `mv`: when the stage root has neither `index.html` nor `README.html`, and `opts` lacks `noindex`, write `index.html` with the same `<style>` block as the markdown render and a `<ul>` of every regular file under the stage (relative href, percent-encoded, sorted, `.md` listed by its `.html` render when one exists). Nested folders are not listed separately; the site root `/` still 404s. Because it runs inside `copy()`, `refresh` keeps the listing.

**`ls`**: snapshot rows unchanged. Live rows print `live -> http://127.0.0.1:<port>` instead of `size=`. Host rows print the own hostname as the link. **`refresh`** on a live row: `echo "live share, nothing to refresh"`, exit 0, before any `-e` test. **`hits`**: for a host row filter `.request.host == <fqdn>`, otherwise the existing URI-prefix filter. **`rm` / `prune`**: for a host row call `host_rm` first (DNS then ingress, both idempotent); then drop the row; then `caddy_reload`. **`teardown`**: iterate host rows through `host_rm` before deleting the tunnel. **`status`**: unchanged shape, gains the live/host rows through `ls`.

### Data model changes

`index.tsv` sixth column `opts`; config gains `zone=<name>` on the first `--host` add (or at setup, going forward).

### API changes

Cloudflare: per host share, one `dns_records` CNAME and one ingress rule with `originRequest.httpHostHeader`. Nothing else.

### UI changes

CLI output lines above; help text gains the new `add` shapes and `--host` / `--no-index`.

### Infrastructure changes

Caddy admin on a unix socket under `$root` (0700 dir). No new TCP listener.

## Task Breakdown

### Phase 1: Foundation
- [ ] TASK-1: `opts` column. Every `index.tsv` reader takes the sixth field; `share_url` branches on kind; `cmd_ls` shows live/host rows. AC: old five-column rows list unchanged (test fixture writes one by hand).
- [ ] TASK-2: Caddy admin socket + `caddy_reload` + `write_caddyfile` rendered from `index.tsv` with `handle_path` / `handle` split and host site blocks. AC: existing test suite passes unchanged; a reload after a row change is observable (a new `handle_path` answers without restart).

### Phase 2: Core
- [ ] TASK-3: `parse_target` + live shares (prefix). Port rules, warnings, `refresh` no-op, `hits` unchanged for prefix. AC: a live share to a local `python3 -m http.server` answers through `/<id>/` with the prefix stripped; `add 8787` (caddy port), `add 8788` (metrics), `add 80` refused; `rm` makes the prefix 404 without restart.
- [ ] TASK-4: folder index in `copy()`. AC: a folder without `index.html`/`README.html` lists its files at the share root; `--no-index` keeps the 404; a folder with `README.md` keeps the render as index; `refresh` keeps the listing.
- [ ] TASK-5: `--host` for live and snapshot shares: `host_add` / `host_rm`, collision guard, mutex, ingress invariant, create/delete order, `zone` in config, `hits` by host, `rm` / `prune` / `teardown` cleanup. AC (local): with `SHARE_TUNNEL=0` and `SHARE_HOST_DRY=1` (skips the Cloudflare calls, records the intended calls to `$root/host-calls.log`), a snapshot host share serves `index.html` for `/deep/link` when the request carries `Host: app.example.test`, and `rm` logs DNS-before-ingress. AC (e2e, by hand): `tests/e2e.sh` gains a `--host` leg: `add <port> --host dev.<zone>` answers through the public hostname, `rm` leaves no record and no rule, teardown finds nothing.

### Phase 3: Polish
- [ ] TASK-6: docs. README "What you get" rows for live shares, own hostnames, folder index; the `add` synopsis; `docs/how-it-works.md` diagram, file list (`admin.sock`, `.lock-host`), lifecycle, and the `index.tsv` layout; `docs/setup.md` on the credential `--host` needs; help text in `bin/share`. AC: `docs/how-it-works.md` mentions no `admin off`.

## After state

- [ ] `share add 3000` prints `https://s.example.com/<id>/` and a visitor reaches the dev server. (Today: `usage:` error.)
- [ ] `share add 3000 --host dev.example.com` prints `https://dev.example.com` and a Vite/Next dev server works there unmodified. (Today: impossible.)
- [ ] `share add ./notes` where `notes/` has only `.md` and `.pdf` files shows a file list at the link. (Today: 404.)
- [ ] `share add ./dist --host app.example.com` serves `/settings` from `index.html`. (Today: 404 on deep links.)
- [ ] `share rm <id>` of a host share deletes its CNAME and ingress rule; `share teardown` leaves none. Checkable with `tests/e2e.sh`.
- [ ] `share add 80` and `share add 8787` refuse. (Today: n/a.)
- [ ] `bash tests/share.sh` PASS on macOS bash 3.2 and Ubuntu; `shellcheck` clean.

## Acceptance Criteria (global)

1. Every bullet in `## After state`.
2. No new place the Cloudflare token or the tunnel token is visible in argv, logs, or output.
3. Old `index.tsv` rows (five columns) keep listing, serving, refreshing, and removing.
4. `admin off` no longer appears in `bin/share` or the docs; nothing new listens on TCP.
5. `docs/how-it-works.md` diagram and file list match the code (a docs-versus-code read by the reviewer).

## Failure modes

| Failure | Behavior |
|---|---|
| `add <port>` with nothing listening | Row and link are created (the server may start later); visitor gets 502 from caddy until it answers. `add` prints `nothing answers on 127.0.0.1:<port> yet` when a `curl -s -o /dev/null` probe fails. |
| `--host` without a credential | `die` before any write. |
| `--host` name already has a foreign record | `die`, no write. |
| Ingress catch-all missing or primary rule not first | `die` with the dashboard hint, no PUT. |
| Crash between ingress PUT and DNS POST | Ingress reverted by the trap; nothing in `index.tsv`. |
| Crash between DNS POST and row append | DNS record and rule exist with no row. `share add --host <same>` next time accepts the CNAME (it points at this tunnel) and re-PUTs the rule idempotently. `teardown` sweeps by tunnel target, not by rows: every CNAME in the zone pointing at this tunnel goes. |
| `caddy reload` fails | `add` prints the caddy error and `see $root/caddy.log`; the row stays (the next `share start` renders it). |
| Two `add --host` at once | Second waits on the mutex up to 60 s, then `die "another share command holds the host lock"`. |
| Live share expires | `prune` removes it like a snapshot, including the host cleanup. |

## Test plan

Coverage matrix, one row per case; the local harness is `tests/share.sh` unless marked e2e. Conventions the writer must follow: stderr is captured separately (`out=$(... 2>&1 1>/dev/null)`) for every row whose Assert names a message; hit counts anchor at `^`; call-order asserts compare line numbers in `host-calls.log`, not independent greps; the live-share fixture is a second `caddy file_server` on a spare port (already installed for the suite, no `python3` dependency) with a `wait_for_port` helper and a cleanup trap; rows 6 and 7 use different live shares so a removal never eats the hits fixture; the host share used by row 20 is a fresh one created after row 14's `rm`.

| # | Category | Case | Assert |
|---|---|---|---|
| 1 | compat | five-column row written by hand | `ls` shows it, `rm` removes it |
| 2 | live | `add <fixture port>` | `GET /<id>/hello.txt` returns the fixture file body (prefix stripped) |
| 3 | live | `add <fixture port>` output | link ends in `/<id>/`; stderr carries the live warning and the absolute-paths caveat |
| 4 | live-refuse | `add 80`, `add $SHARE_PORT`, `add $((SHARE_PORT+1))`, `add 99999` | exit 1, stderr names the reason, no row |
| 5 | live | `refresh <live id>` | exit 0, "nothing to refresh" on stderr |
| 6 | live | `rm <live id>` while serving | `GET /<id>/` is 404 without a restart |
| 7 | live | `hits <live id>` after two GETs | matches `^2 hits, [0-9]+ visitors?$` |
| 8 | index | folder of `.txt` + `.md`, no index | root 200; `href="other.html"` present; the `.txt` file linked by name |
| 9 | index | same fixture with `--no-index` | root 404 |
| 10 | index | folder with `README.md` | root is the render (`max-width:42em` marker), no `<ul` |
| 11 | index | `refresh` of the listed folder | listing still there |
| 12 | index | folder with a nested subfolder | root listing names the subfolder's files only via their paths; no separate subfolder entry |
| 13 | host (dry) | `add ./dist --host app.example.test` with `SHARE_HOST_DRY=1` | `curl -H 'Host: app.example.test' /deep/link` returns `index.html`; in `host-calls.log` the `PUT ingress` line precedes `POST CNAME` (compare line numbers) |
| 14 | host (dry) | `rm` of that share | `DELETE CNAME` precedes `PUT ingress -1`; the same curl now 404s |
| 15 | host-refuse | `--host dev.s.example.test` (two labels), `--host other.zone` | exit 1, stderr has the one-label message |
| 16 | host-refuse | `env -u CLOUDFLARE_API_TOKEN`, `SHARE_HOST_DRY` unset, no cert | exit 1, no row |
| 17 | host-fail (dry) | ingress fixture with the catch-all NOT last | exit 1, dashboard-hint message, `host-calls.log` has no `PUT` |
| 18 | host-fail (dry) | pre-create `$root/.lock-host`, `SHARE_HOST_LOCK_TIMEOUT=1` | second `add --host` dies "another share command holds the host lock" |
| 19 | live-fail | `add <port>` with nothing listening | exit 0, row created, stderr has `nothing answers on 127.0.0.1:<port> yet`; `GET /<id>/` is 502 |
| 20 | serve | restart `serve` with a live row and a fresh host row present | Caddyfile carries `handle_path` and the hostname site block; no `admin off` |
| 21 | serve-fail | `caddy` off `PATH`, then `add` a live share | stderr surfaces the reload error and names `$root/caddy.log`; the row stays in `index.tsv` |
| 22 | negative | machine-allowlist control (existing end-of-suite check) | still last, still refuses |
| 23 | e2e | `tests/e2e.sh` `--host` leg | public hostname answers, `rm` deletes record + rule, teardown clean |

## Verification

```
shellcheck bin/share tests/share.sh tests/e2e.sh && /bin/bash tests/share.sh
```

Then by hand before release: `SHARE_E2E_HOST=... CLOUDFLARE_API_TOKEN=... tests/e2e.sh`.
