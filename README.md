# share

Publish a snapshot of a local file or folder at a short link on your own domain, like ngrok, but with a stable hostname and no account on a third-party tunnel service. Anyone with the link can open it while your machine is awake.

```
$ share add ./record-your-sharing
https://s.example.com/62cb50/record-your-sharing/
  (link copied)
  serving in the background (pid 48211); share stop to end
```

```
 teammate's browser                                your machine
 ──────────────────                                ─────────────────────────────────────────
 https://s.example.com/62cb50/guide/               ~/share/pub/62cb50/guide/  (a snapshot copy)
        │                                                        ▲
        ▼                                                        │ files
 Cloudflare edge  ── Cloudflare Tunnel (outbound) ──▶ cloudflared ─▶ caddy on 127.0.0.1:8787
 (TLS, DNS, no-store)                                            no listing, no-store, noindex
```

## What you get

| Behavior | Detail |
|---|---|
| Short, stable link | `https://<your-host>/<id>/<name>`. The random 6-hex `id` keeps links unguessable. |
| Snapshot, not a live mount | `share add` copies the file or folder. The link keeps working after the source is deleted, for example a removed git worktree. `share refresh <id>` updates the copy under the same link. |
| Safe copy | Dotfiles (`.git`, `.env`) and symlinks are never copied, so a shared folder cannot leak secrets or point at `~/.ssh`. |
| Markdown | With pandoc installed, every `.md` also gets an `.html` render; links between `.md` files point at the renders. |
| Expiry | Shares expire after 30 days by default (`--ttl 12h`, `--ttl 7d`, `--ttl never`). |
| No caching, no indexing | Every response carries `Cache-Control: no-store` and `X-Robots-Tag: noindex, nofollow`. `share rm` takes effect at once. |
| Visitor count | `share hits <id>` counts requests and unique visitor IPs. |
| One serving machine | Only hosts listed in the config serve, so two machines never split one tunnel. |

Links are live only while `share` runs and the machine is awake. When the machine sleeps, visitors get Cloudflare error 530.

## Install

Requirements: macOS or Linux, a domain on Cloudflare, and `caddy`, `cloudflared`, `jq`, `curl`. Optional: `pandoc` (markdown rendering), `gh` (private-repo warning).

```sh
git clone git@github.com:dwarvesf/share.git ~/workspace/dwarvesf/share
cd ~/workspace/dwarvesf/share
./install.sh                 # or ./install.sh --with-extras for pandoc and gh
```

`install.sh` installs missing dependencies with Homebrew when it is present, then symlinks `bin/share` into `~/.local/bin` (`PREFIX=... ./install.sh` to change). The symlink points into the checkout, so `git pull` updates `share`.

## Set up Cloudflare (once per machine)

Create a Cloudflare API token with these permissions (details in [docs/setup.md](docs/setup.md)):

| Scope | Permission |
|---|---|
| Account | Cloudflare Tunnel: Edit |
| Zone | DNS: Edit |
| Zone | Zone: Read |

Then run setup with the hostname you want:

```sh
CLOUDFLARE_API_TOKEN=... share setup s.example.com
```

```
1/6 token:  active
2/6 zone:   found (account 1d2a860f...)
3/6 tunnel: created share-s-example-com (76b8f957)
4/6 route:  s.example.com -> 127.0.0.1:8787
5/6 dns:    created CNAME s.example.com
6/6 token:  stored in keychain (service share-tunnel:s.example.com)
config:     ~/.config/share/config
verified:   https://s.example.com/ answers through the tunnel. Next: share add <file|dir>
```

Setup creates the tunnel, its route, and the DNS record, stores the tunnel token, and proves the link answers from the public internet. It does not store the API token. Rerunning setup is safe: it reuses what exists. `share teardown` removes all of it again.

## Use

| Command | What it does |
|---|---|
| `share add [--ttl 7d] <file\|dir>` | Copy it in, print the link, copy the link to the clipboard, start serving if needed. |
| `share ls` | List shares with link, size, source, and expiry. Flags shares whose source is gone. |
| `share refresh <id>` | Re-copy from the source path. The link stays the same. |
| `share rm <id>` | Unpublish now. The copy goes to the Trash. |
| `share hits <id>` | Requests and unique visitors for one share. |
| `share prune` | Unpublish every expired share now. It also runs every hour while serving, and before `ls` and `status`. |
| `share start` / `share stop` | Serve in the background / stop serving (every link goes down). |
| `share` | Server state plus the share list. |
| `share serve` | Serve in the foreground until Ctrl-C. |
| `share setup <hostname>` | Create or repair the Cloudflare side. See [docs/setup.md](docs/setup.md). |
| `share teardown [--yes]` | Delete the tunnel, DNS record, stored token, and config. Shares on disk stay. |

A share from a private GitHub repo prints a warning, because the content is now public to anyone with the link.

## Configuration

Setup writes `~/.config/share/config` (`$XDG_CONFIG_HOME/share/config`). It is plain `key=value`, read without being executed.

| Key | Meaning |
|---|---|
| `hostname` | Public hostname, for example `s.example.com`. |
| `tunnel_id`, `tunnel_name` | The Cloudflare Tunnel that setup created or reused. |
| `hosts` | Space-separated short hostnames allowed to serve (`uname -n` up to the first dot). Setup writes the current machine. |
| `port` | Local port caddy listens on. The tunnel route points at it. Default `8787`. |
| `ttl` | Default expiry for `share add`. Default `30d`. |
| `token_cmd` | Optional command that prints the tunnel token, for example a 1Password read. It overrides the Keychain and the token file. |

Environment variables override the file: `SHARE_HOSTNAME`, `SHARE_HOSTS`, `SHARE_PORT`, `SHARE_TTL`, `SHARE_ROOT` (default `~/share`), `SHARE_CONFIG_DIR`, `SHARE_CLIPBOARD=0`, `SHARE_TUNNEL=0` (serve locally without the tunnel).

## Security model

- A link is public: anyone who has it can open it. Treat `share add` as publishing.
- Links contain a random id and the root has no listing, so nobody can browse or guess other shares.
- Only regular files are copied. Dotfiles and symlinks are skipped.
- Nothing outside `~/share/pub` is reachable. The index, logs, and config sit outside it.
- The tunnel token lives in the macOS Keychain, or in a mode-600 file on Linux, or behind your own `token_cmd`. The Cloudflare API token is used during setup and teardown only, sent through a header file (never in `argv`), and never stored.
- caddy listens on `127.0.0.1` only. The tunnel connects outbound, so no inbound port opens.

## Development

```sh
bash tests/share.sh      # local self-test: every behavior except the tunnel, no credentials needed
shellcheck bin/share install.sh tests/share.sh
```

CI runs both on the self-hosted `pr-shared` pool. The pool has no pandoc, so the markdown checks run on dev machines only. The Cloudflare side (`setup`, `teardown`) needs a real zone and token, so it is tested by hand; [docs/how-it-works.md](docs/how-it-works.md) records that procedure.

## Docs

- [docs/setup.md](docs/setup.md): the API token, what setup creates, 1Password, moving machines, teardown, troubleshooting.
- [docs/how-it-works.md](docs/how-it-works.md): architecture, files on disk, and the reason for each design choice.
