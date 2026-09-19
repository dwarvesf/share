# Decision brief: live shares and own hostnames

## Problem

`share add` copies files and caddy serves the copy. Three things a user reaches for do not work:

| Case | Today |
|---|---|
| A dev server on `localhost:3000` (the ngrok case) | Cannot be shared at all. |
| A folder with no `index.html` and no `README.md` | The folder link is a 404 (no listing by design), so the visitor has to guess a file name. |
| A built single-page app (`dist/`) with client-side routes | Only `/` works; deep links 404. |

## Context

- One tunnel, one hostname (`s.example.com`), one caddy on `127.0.0.1:8787`. The tunnel's ingress is a single rule for that hostname (`cmd_setup`, the `cfd_tunnel/<id>/configurations` PUT).
- Caddy runs with `admin off`, so today its config cannot change while serving.
- `index.tsv` rows are `id name src date exp`; `cmd_ls`, `cmd_prune`, `row`, `cmd_hits` parse it by column.
- Setup keeps a Cloudflare credential only in login mode (`~/.config/share/cert.pem`). API-token setup keeps nothing; the token came from the environment.
- Universal SSL covers the zone apex and ONE label (`*.example.com`). A second-level wildcard (`*.s.example.com`) needs Advanced Certificate Manager (paid). So random `<id>.s.example.com` hostnames are out.

## Solution

```
 share add 3000                       share add 3000 --host dev.example.com     share add ./dist --host app.example.com
 https://s.example.com/<id>/          https://dev.example.com                   https://app.example.com
        │                                     │                                          │
 tunnel ingress s.example.com         tunnel ingress dev.example.com             tunnel ingress app.example.com
        │                             + CNAME dev -> tunnel (created at add)     + CNAME app -> tunnel (created at add)
        ▼                                     ▼                                          ▼
 caddy :8787                          caddy :8787, host match                    caddy :8787, host match
   handle_path /<id>/*                  reverse_proxy 127.0.0.1:3000               root pub/<id>; try_files {path} /index.html
     reverse_proxy 127.0.0.1:3000                                                  file_server
```

Three additions, one verb:

1. **Live shares.** `share add <port | localhost:port | http://localhost:port>` records a live share and proxies `https://<host>/<id>/` to it. `handle_path` strips the `/<id>` prefix. This is the cheap path and works for APIs, webhooks, and servers that use relative asset paths. Apps that emit absolute asset paths (`/static/app.js`) break under a prefix; `add` prints that caveat and points at `--host`.
2. **Own hostname.** `--host <fqdn>` on any `add` (live or snapshot) gives the share its own hostname under the zone: one CNAME to the tunnel, one ingress rule, one caddy host block. A snapshot share with an `index.html` at its root gets `try_files {path} /index.html`, so a built SPA works. `share rm` (and prune, and teardown) delete the DNS record and the ingress rule.
3. **Folder index.** A snapshot folder with neither `index.html` nor `README.md` at its root gets a generated `index.html` listing every file (relative links, same stylesheet as the markdown render). Only at the share root; nested folders stay unlisted, and the site root `/` stays a 404.

Mechanics:

- `index.tsv` grows a sixth column `opts`, empty for existing rows. Values: `live` (src is a URL), `host=<fqdn>`. Readers use `read -r id name src date exp opts` and awk by column, so old rows parse unchanged.
- Caddy admin moves from `off` to a unix socket in `$root` (`admin unix//$root/admin.sock`). `write_caddyfile` renders live and host blocks from `index.tsv`; `add`, `rm`, `refresh`, and `prune` call `caddy reload` when a server is running. Nothing listens on a new TCP port.
- `--host` needs a Cloudflare credential at `add` time: `CLOUDFLARE_API_TOKEN` in the environment, else the login `cert.pem`. Neither present: `add` dies before writing anything and says which to provide. The hostname must be a first-level name in the setup zone (`dev.example.com`, not `dev.s.example.com`), or `add` refuses with the Universal SSL reason.
- The tunnel ingress is a whole-config PUT. `add --host` and `rm` read the current config, add or drop the one rule, and PUT it back, keeping the primary hostname rule first and the `http_status:404` catch-all last.
- Proxied responses keep `Cache-Control: no-store` and `X-Robots-Tag`. `hits` filters by `request.host` for a host share and by URI prefix otherwise.
- `ls` shows `live -> http://127.0.0.1:3000` instead of a size for live rows, and the own hostname when set. `refresh` on a live row is a no-op with a message.
- `teardown` removes every host share's DNS record and ingress rule before the tunnel.

## Rejected

| Option | Why not |
|---|---|
| Random `<id>.s.example.com` per share via a wildcard | Second-level wildcard is outside Universal SSL; browsers would see a certificate error unless the account pays for ACM. |
| Wildcard `*.example.com` CNAME to the tunnel | Hijacks every undefined name in the zone to this machine. |
| Path-prefix proxy only | Breaks most SPAs and any server with absolute asset paths; users would blame the tool. Kept as the zero-credential default, with the caveat printed. |
| `--spa` flag on prefix shares | Same absolute-path defect class as the live prefix. Own hostname covers SPAs without a flag. |
| Restart caddy on every change | Drops in-flight requests; reload over the admin socket is the supported path. |

## Done =

`tests/share.sh` (local, no tunnel) proves: a live share proxies to a local python http.server and strips the prefix; a folder without an index gets a generated listing; a host-block snapshot serves `index.html` for a deep link when the Host header matches; `rm` of a live share reloads caddy and the prefix 404s; old five-column rows still list. `tests/e2e.sh` (real zone, by hand) proves: `add 3000 --host dev.<zone>` answers through the public hostname, `rm` deletes the DNS record and the ingress rule, and teardown leaves no record behind.
