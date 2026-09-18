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
   share serve (pid in ~/share/serve.pid)          │
     ├─ cloudflared tunnel run  ────────────────────┘   (TUNNEL_TOKEN from Keychain / file / token_cmd)
     ├─ caddy on 127.0.0.1:<port>  ── serves ~/share/pub only
     │     headers: Cache-Control no-store, X-Robots-Tag noindex
     │     no directory listing; folder index = index.html, then README.html
     │     JSON access log → ~/share/access.log
     └─ prune loop: every hour, unpublish expired shares
```

`share start` runs `share serve` under `nohup` and returns. `share stop` sends it SIGTERM, and its exit trap stops caddy, cloudflared, and the prune loop together.

## Files on disk

```
~/share/                    SHARE_ROOT
├── pub/                    the only tree the tunnel can reach
│   ├── 62cb50/guide/...    one directory per share id
│   └── 84cbfe/note.txt
├── index.tsv               id, name, source path, added date, expiry epoch (0 = never)
├── Caddyfile               regenerated on every serve
├── access.log              caddy JSON log, read by `share hits`
├── serve.pid  serve.log  caddy.log
└── md-links.lua            pandoc filter that rewrites .md links to .html

~/.config/share/            SHARE_CONFIG_DIR
├── config                  key=value, written by setup
└── tunnel-token            Linux only, mode 600 (macOS uses the Keychain)
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
  mv stage → pub/<id>               an atomic swap, so a refresh never serves half a copy
  append the row to index.tsv
  print + pbcopy the link, warn if the source repo is private on GitHub
  share start if nothing is serving and this host is in `hosts`
```

`share refresh <id>` runs the same copy from the recorded source path and swaps it in under the same id. `share rm <id>` moves `pub/<id>` to the Trash (or `~/share/trash` without a `trash` command) and drops the row.

## Why each choice

| Choice | Reason |
|---|---|
| Copy, not serve the source in place | A share must outlive its source. The first version served folders in place; its links broke when a git worktree was removed. |
| Random id in every link | "Anyone with the link" should not mean "anyone who guesses `preview.html`". |
| No directory listing | Nobody can browse from the root to other shares. |
| `Cache-Control: no-store` | Tested live without it: Cloudflare cached an image (`cf-cache-status: HIT`) and kept serving it with 200 after the server had stopped. With the header, every request shows `BYPASS`, and `rm` returns 404 at once. |
| `X-Robots-Tag: noindex, nofollow` | A link pasted somewhere public should not end up in search results. |
| Copy only regular files | A symlink inside a shared folder could point at `~/.ssh`. The copy uses `find -type f` rather than rsync: macOS ships openrsync, which accepts `--safe-links` but copies outside-pointing links anyway. |
| One serving host (`hosts`) | Cloudflare load-balances between every connector on a tunnel. Two machines with different `~/share` folders would give random 404s. |
| Remotely managed tunnel via the API | Setup needs only an API token, not `cloudflared tunnel login` and its account-wide `cert.pem`. The ingress rule lives in Cloudflare, so a new machine needs only the run token. |
| DNS check before creating the tunnel | A taken hostname stops setup with nothing created, so a failed run leaves no orphan tunnel. |
| API token through `-H @file`, run token through stdin | Neither token appears in `ps` output while share runs. |
| caddy, not `python -m http.server` | caddy sets headers, disables listings, writes a JSON access log, and ships as one static binary for CI. |
| Bash | The tool is glue around caddy, cloudflared, and the Cloudflare API. A single binary in Go becomes the better choice if share needs Windows or a distribution without a git checkout. |

## Testing

| Layer | How | Where |
|---|---|---|
| Lint | `shellcheck` | CI and local |
| Behavior | `tests/share.sh` runs a local server (`SHARE_TUNNEL=0`, port 18787) and covers add, auto-start, headers, dotfile and symlink exclusion, markdown, a deleted source, refresh, hits, expiry, rm, and stop. It ends with a negative control: a host outside `hosts` must not serve. | CI (markdown checks skipped, no pandoc) and local |
| Cloudflare | By hand against a throwaway hostname: `setup` on a taken hostname must refuse and create no tunnel; a fresh `setup` must pass its live check; a second `setup` must reuse the tunnel and the record; `add` must fetch publicly; `teardown` must leave zero tunnels, zero records, and no Keychain item. | Local, with a real zone and token |
