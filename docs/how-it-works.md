# How share works

## Architecture

```
                   ┌──────────────────────── Cloudflare ────────────────────────┐
 visitor ─HTTPS──▶ │ s.example.com (proxied CNAME) ─▶ tunnel ingress rule         │
                   │   universal cert *.example.com      s.example.com → :8787   │
                   └───────────────────────────────▲─────────────────────────────┘
                                                   │ outbound QUIC/HTTP2, started by the machine
 your machine ─────────────────────────────────────┼─────────────────────────────────────────
                                                   │
   launchd agent / systemd user unit (foundation.d.share), or `nohup` without the service
     │
   share serve (pid in ~/share/serve.pid)          │
     ├─ cloudflared tunnel run  ────────────────────┘   (TUNNEL_TOKEN from Keychain / file / token_cmd)
     ├─ caddy on 127.0.0.1:<port>
     │     default site: handle_path /<id>/* → reverse_proxy 127.0.0.1:<live port>  (live shares)
     │                   handle /healthz → respond "ok" 200                         (health probe)
     │                   handle → file_server over ~/share/pub                      (snapshots)
     │     per --host share: site block on <fqdn>:<port> → reverse_proxy or file_server
     │                   + a tunnel ingress rule pinning httpHostHeader to <fqdn>
     │                   + a CNAME <fqdn> → <tunnel>.cfargotunnel.com
     │     headers: Cache-Control no-store, X-Robots-Tag noindex
     │     no directory listing; folder index = index.html, then README.html,
     │     else a generated listing (unless --no-index); site root still 404s,
     │     so probes use /healthz
     │     admin API on unix socket ~/share/admin.sock (owner-only); Caddyfile is
     │     re-rendered from index.tsv and caddy reload runs on add / rm / refresh / prune
     │     JSON access log → ~/share/access.log
     └─ prune loop: every hour, unpublish expired shares
```

`share setup --quick` writes `mode=quick` instead of a hostname and tunnel id. In that mode `share serve` runs `cloudflared tunnel --url http://127.0.0.1:<port>` (no token, no DNS, no account) and scrapes the random `https://<x>.trycloudflare.com` URL out of `cloudflared.log` into `quick.url`; links and `status` read the hostname from there. The URL is new on every serve start, so `--host` is refused and old links die. Caddy, `index.tsv`, live shares, and the folder index behave identically.

With the service installed, launchd (macOS) or systemd (Linux) starts `share serve` at login and restarts it after a crash. `share start` and `share stop` load and unload the service. Without it, `share start` runs `share serve` under `nohup`, and `share stop` sends it SIGTERM. Either way, the exit trap stops caddy, cloudflared, and the prune loop together.

The launchd agent's first program argument is the `share` script itself, so the macOS Login Items list shows "share" rather than a generic shell. Its `PATH` holds the directories of caddy, cloudflared, and the other tools, because launchd starts agents with a minimal `PATH`.

## Files on disk

```
~/share/                    SHARE_ROOT
├── pub/                    the only tree the tunnel can reach
│   ├── 62cb50/guide/...    one directory per share id
│   └── 84cbfe/note.txt
├── index.tsv               id, name, source path, added date, expiry epoch (0 = never), opts
│                           opts is a space-separated list: `live`, `host=<fqdn>`, `noindex`
├── Caddyfile               re-rendered from index.tsv at serve start and on add / rm / refresh / prune
├── admin.sock              caddy admin API, unix socket inside the 0700 share root
├── .lock-host/             mkdir mutex serializing Cloudflare ingress edits
├── access.log              caddy JSON log, read by `share hits`
├── serve.pid  serve.log  caddy.log  cloudflared.log
├── quick.url               quick mode only: the trycloudflare fqdn cloudflared printed last start
├── md-links.lua            pandoc filter that rewrites .md links to .html
└── md-style.html           the reading stylesheet, shared by renders and generated indexes

~/.config/share/            SHARE_CONFIG_DIR
├── config                  key=value, written by setup
├── tunnel-token            Linux only, mode 600 (macOS uses the Keychain)
├── cert.pem                browser-login path only, mode 600
└── cert.zone               the zone that cert.pem was issued for
```

## Lifecycle of a share

```
share add ./guide
  realpath ./guide                  resolve a symlinked argument to its real path
  id = 6 random hex chars           from /dev/urandom
  stage = ~/share/.stage.XXXXXX
  find guide -name '.*' -prune -o -type f -print  →  cp -p each file into stage
                                    only regular files: dotfiles and symlinks never ship
  pandoc every *.md → sibling .html (skipped when pandoc is absent or the .html exists)
                                    an inline reading stylesheet (light and dark); KaTeX from the CDN only for pages with $ math
  mv stage → pub/<id>               an atomic swap, so a refresh never serves half a copy
  append the row to index.tsv
  print + pbcopy the link, warn if the source repo is private on GitHub
  share start if nothing is serving and this host is in `hosts`; caddy reload if it is
```

A live share skips the copy entirely:

```
share add 3000
  parse_target: a bare port / localhost:port / http://localhost:port is a live target
  port must be 1024..65535 and not caddy's or cloudflared's own ports
  opts = "live", src = http://127.0.0.1:3000
  append the row, render handle_path /<id>/* → reverse_proxy, reload
  print https://<host>/<id>/ plus the warning: the link reaches that port while the machine is awake
```

`--host dev.example.com` wraps either kind in its own hostname. Order of writes: tunnel ingress rule (inserted before the catch-all, carrying `httpHostHeader`), then the CNAME, then the index row; `share rm` deletes the CNAME, then the ingress rule, then the row. Every Cloudflare-side edit runs under the `.lock-host` mutex and refuses a tunnel config whose invariants were changed outside share. The name must be a single label under the setup zone because Universal SSL stops at one level.

`share refresh <id>` runs the same copy from the recorded source path and swaps it in under the same id (a live share is a no-op). `share rm <id>` moves `pub/<id>` to the Trash (or `~/share/trash` without a `trash` command) and drops the row. An own-host share (`--host`) refuses to be removed without a Cloudflare credential (`CLOUDFLARE_API_TOKEN` or a `share setup --login` cert), so its DNS record and ingress rule are never orphaned. `prune` still removes an expired one and warns that they stay behind.

## `share state`

The menu bar app never reads share's files. It runs `share state`, a read-only verb
that prints a snapshot and exits 0 in every state: not set up, stopped, or serving.
The app changes anything only by running share's normal verbs (`add`, `rm`, `refresh`,
`start`, `stop`, `setup`); why that split exists: [ADR-0003](decisions/ADR-0003-menu-bar-reads-through-cli.md).

```json
{
  "schema": 1,
  "state": "serving",
  "ready": true,
  "mode": "named",
  "host": "s.han.ws",
  "hosts": "hans-air-m4",
  "serves_here": true,
  "service": true,
  "shares": [
    {"id": "3d324a", "name": "theme-check.md",
     "url": "https://s.han.ws/3d324a/theme-check.html",
     "kind": "snapshot", "own_host": null, "expires": 1759000000}
  ]
}
```

| Field | Values |
|---|---|
| `schema` | integer, `1` |
| `state` | `serving` (pid alive), `stopped` (set up, not running), `not_setup` (no hostname and not quick mode) |
| `ready` | whether a live check succeeded for the current mode and state; `false` whenever not serving |
| `mode` | `named` or `quick` |
| `host` | named mode: the configured hostname. quick mode: the live `trycloudflare.com` URL while serving, else `null` |
| `hosts` | the `hosts=` config value, `""` when unset |
| `serves_here` | whether this machine is in `hosts` |
| `service` | whether the login service is installed |
| `shares[]` | ordered newest first, same rows `share ls` prints |
| `shares[].kind` | `live` for a live proxy, else `snapshot` |
| `shares[].own_host` | the share's own `--host` value, else `null` |
| `shares[].expires` | epoch seconds; `0` means never |
| `shares[].url` | exactly what `share ls` prints for that row |
| `skipped` | count of malformed index rows; present only when greater than zero |

Invariants: `state` never prunes, never writes or creates a file, never needs a TTY,
and never touches the clipboard. Removing or renaming a field bumps `schema`; adding a
field does not, so an older app can still read a newer CLI. An index row with exactly 5
tab fields (the shape share wrote before this version) reads with empty opts; a row is
skipped, and counted in `skipped` instead of breaking the read, when it has fewer than 5
or more than 6 fields, when its id is not exactly 6 lowercase hex characters, or when its
`host=` opt is the main hostname or not a valid hostname.

## Why each choice

| Choice | Reason |
|---|---|
| Copy, not serve the source in place | A share must outlive its source. The first version served folders in place; its links broke when a git worktree was removed. |
| Random id in every link | "Anyone with the link" should not mean "anyone who guesses `preview.html`". |
| No directory listing | Nobody can browse from the root to other shares. A shared folder without an index gets a generated listing of its own files; the site root `/` never gets one, and `--no-index` keeps the old 404. |
| Path prefix for live shares, not a random subdomain | `<id>.s.example.com` needs a second-level wildcard cert, which Universal SSL does not issue. `handle_path /<id>/*` costs no DNS; `--host <label>.<zone>` covers apps that need the root. |
| `httpHostHeader` pinned per ingress rule | Caddy routes by Host; a visitor-supplied Host of another share must not reach it, so cloudflared sets the origin Host to the share's own hostname. |
| Ports below 1024 and share's own ports refused | `share add 80` or `add $metrics_port` would publish a system service, not a dev server. There is no override flag. |
| Admin API on a unix socket | `caddy reload` applies add/rm without a restart, and a socket inside the 0700 share root listens on no TCP port. |
| `Cache-Control: no-store` | Tested live without it: Cloudflare cached an image (`cf-cache-status: HIT`) and kept serving it with 200 after the server had stopped. With the header, every request shows `BYPASS`, and `rm` returns 404 at once. |
| `X-Robots-Tag: noindex, nofollow` | A link pasted somewhere public should not end up in search results. |
| Copy only regular files | A symlink inside a shared folder could point at `~/.ssh`. The copy uses `find -type f` rather than rsync: macOS ships openrsync, which accepts `--safe-links` but copies outside-pointing links anyway. |
| One serving host (`hosts`) | Cloudflare load-balances between every connector on a tunnel. Two machines with different `~/share` folders would give random 404s. |
| Remotely managed tunnel | The route lives in Cloudflare, so a machine needs only the tunnel's run token to serve. |
| Quick mode reuses the same caddy and index | TryCloudflare cannot route hostnames, so quick links keep the `/<id>/` path shape and every command works unchanged. The price is a new random hostname per start; stable names stay behind `share setup <hostname>`. |
| Browser login by default | Nobody has to create an API token by hand. The login certificate's token may manage tunnels (tested: create, configure, read the token, delete) but gets an authorization error on DNS records, so DNS goes through `cloudflared tunnel route dns` and the hostname check goes through public DNS. The trade-off: teardown cannot delete the DNS record on this path. |
| Login service | Links should be live whenever the machine is awake, with no command to remember after a restart. |
| `start` waits for a public fetch | cloudflared reports ready before caddy may listen, and the Cloudflare edge keeps routing to the old connection for a few seconds after a restart. Measured: links answered 502 right after `start` returned on cloudflared's readiness alone. `start` now places a probe file and returns once it answers 200 through the public hostname (2 to 3 seconds). |
| Wait for launchd to unload | `launchctl bootout` returns before the job has stopped, so an immediate `bootstrap` fails with "Bootstrap failed: 5". Reproduced with a dummy agent that takes 2 seconds to exit. |
| DNS check before creating the tunnel | A taken hostname stops setup with nothing created, so a failed run leaves no orphan tunnel. |
| API token through `-H @file`; run token stored through stdin and passed as `TUNNEL_TOKEN` | Neither token appears in a process's arguments, so `ps` output never shows one. |
| caddy, not `python -m http.server` | caddy sets headers, disables listings, writes a JSON access log, and ships as one static binary for CI. |
| Bash | The tool is glue around caddy, cloudflared, and the Cloudflare API. A single binary in Go becomes the better choice if share needs Windows or a distribution without a git checkout. |

## Testing

| Layer | How | Where |
|---|---|---|
| Lint | `shellcheck` | CI and local |
| Behavior | `tests/share.sh` runs a local server (`SHARE_TUNNEL=0`, port 18787) and covers add, auto-start, headers, dotfile and symlink exclusion, markdown, a deleted source, refresh, hits, expiry, rm, stop, live shares (a second caddy as the origin), the generated folder index, and `--host` under `SHARE_HOST_DRY=1`, which records the Cloudflare calls instead of making them. It ends with a negative control: a host outside `hosts` must not serve. | CI (Ubuntu and macOS, with pandoc) and local |
| Cloudflare and service | `tests/e2e.sh` against a throwaway hostname (API-token or `--login` setup): setup must pass its live check; a rerun must reuse the tunnel; a published folder must answer, show the snapshot, hide `.env`, and send `no-store`; links must answer right after `start` and after a service reinstall; `rm` must return 404; teardown must leave no DNS record, a deleted tunnel, and no service. Found and fixed with it: a 530 right after a service reinstall, because one 200 does not mean the edge has dropped the old connection. | Local, with a real zone and token; run before a release that touches setup or serving |

## Releasing

`bin/release` on a clean, synced `main` cuts a release in one step: it computes the next semver from the conventional-commit subjects since the last tag (`feat` -> minor, everything else -> patch, `!`/`BREAKING` -> major), regenerates `CHANGELOG.md` via `bin/changelog` and lands it on `main` before tagging, pushes the tag, and bumps the tap formula (`Formula/share.rb` url + sha256) through a merged PR in `dwarvesf/homebrew-tools`. The tag push runs `release.yml`, which publishes the GitHub release with generated notes. Releases are cut when a feature lands, not per commit. `bin/changelog` is idempotent: run it any time to rebuild `CHANGELOG.md` from tag history.
