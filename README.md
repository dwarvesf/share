# share

[![CI](https://github.com/dwarvesf/share/actions/workflows/ci.yml/badge.svg)](https://github.com/dwarvesf/share/actions/workflows/ci.yml)
[![Cloudflare Tunnel](https://img.shields.io/badge/tunnel-Cloudflare-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
[![built by webuild](https://raw.githubusercontent.com/webuild-community/badge/master/svg/love.svg)](https://webuild.community)

Publish a local file, folder, or running dev server at a link on your own domain. Like ngrok, but the hostname is yours and stays the same.

```sh
brew install dwarvesf/tools/share
share setup s.example.com       # browser opens for Cloudflare login; share does the rest
share add ./team-guide          # https://s.example.com/62cb50/team-guide/  (copied to clipboard)
```

![Share a folder, then check who opened it](demo/use.gif)

## Features

| | |
|---|---|
| **Stable links** | `https://<your-host>/<id>/<name>`; the random id keeps links unguessable |
| **Snapshots** | `share add <file\|dir>` copies it; the link survives deleting the source. `share refresh` updates under the same link |
| **Live dev servers** | `share add 3000` proxies `127.0.0.1:3000` while it runs |
| **Own hostname per share** | `--host dev.example.com` for apps that emit absolute paths |
| **Folder index** | folders without `index.html` list their files (`--no-index` to refuse) |
| **Markdown rendering** | with pandoc, `.md` gets a styled HTML render (light/dark, KaTeX math) |
| **Safe copy** | dotfiles (`.env`, `.git`) and symlinks are never copied |
| **Expiry** | 30 days by default; `--ttl 12h\|7d\|never` |
| **Visitor counts** | `share hits <id>`: requests and unique IPs |
| **No domain needed** | `share setup --quick` serves at a random `trycloudflare.com` URL |
| **Agent-native** | `share skill --install` drops a SKILL.md for Claude Code and friends |
| **Always on** | a login service (launchd/systemd) brings links back after reboot |

Links are live only while the machine is awake; visitors get Cloudflare 530 when it sleeps.

## How it works

```
visitor                                              your machine
───────                                              ────────────────────────────
https://s.example.com/62cb50/guide/                  ~/share/pub/62cb50/guide/
       │                                                          ▲ files
       ▼                                                          │
Cloudflare edge ──── outbound Tunnel ────▶ cloudflared ──▶ caddy on 127.0.0.1:8787
TLS, DNS                                 login service    no-store, noindex
```

`share add` copies into `~/share/pub`, caddy serves it on localhost, and an outbound Cloudflare Tunnel publishes it at your hostname. Nothing outside `~/share/pub` is reachable, no inbound port opens, and the tunnel token lives in the Keychain (or a mode-600 file on Linux). Detail: [docs/how-it-works.md](docs/how-it-works.md).

## Install

```sh
brew install dwarvesf/tools/share    # macOS and Linux; pulls caddy, cloudflared, jq
```

Optional extras: `brew install pandoc gh` (markdown rendering, private-repo warning).

No Homebrew:

```sh
curl -fsSL https://raw.githubusercontent.com/dwarvesf/share/main/install.sh | bash
```

From a clone: `git clone https://github.com/dwarvesf/share.git && cd share && ./install.sh` (symlinks `bin/share`, so `git pull` updates it).

## Commands

```sh
share setup s.example.com   # one-time: tunnel, DNS, login service (or --quick for no domain)
share add <file|dir|port>   # publish, print + copy the link
share ls                    # shares with link, size, source, expiry
share refresh <id|link>     # re-copy from source under the same link
share rm <id|link>          # unpublish (copy goes to Trash)
share hits <id|link>        # request and visitor counts
share stop | start          # take all links down / bring them back
share teardown              # remove tunnel, service, and config
```

A share from a private GitHub repo prints a warning; the content is public to anyone with the link.

## Docs

- [docs/setup.md](docs/setup.md): API token setup (no browser), moving machines, troubleshooting
- [docs/how-it-works.md](docs/how-it-works.md): architecture, config keys, security model, testing

## License

MIT
