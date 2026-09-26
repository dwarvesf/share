# Stack Report: share + Share Bar menu app

## Languages
- **Bash 3.2** (macOS compatible; source: bin/share, tests/*.sh)
- **Swift 5.5+** (macOS menu app under mac/; source: DECISION-BRIEF-menu-bar.md)

## Frameworks & runtime deps

### CLI (bash)
- **caddy 2.11.4**: local HTTP server, runs on 127.0.0.1:8787
- **cloudflared**: Cloudflare Tunnel agent (login service foundation.d.share)
- **jq**: JSON parsing for API responses
- **curl**: HTTP client for Cloudflare API
- **pandoc**: optional; renders .md to HTML in Spacedown theme

### Menu app (Swift/AppKit)
- **AppKit** (NSStatusItem, NSMenu, NSWindow): status bar icon, menus, drag-drop
- **SwiftUI**: setup window hosted in NSWindow
- **Foundation**: JSON decoding via Decodable, process spawning
- **macOS 12+**: deployment target (typical for AppKit menu apps)

## Key dependencies

| Package | Role |
|---------|------|
| caddy | Serves ~/share/pub/ on localhost; file security (no-store, noindex headers) |
| cloudflared | Outbound tunnel; login service manages lifecycle |
| jq | Extracts fields from Cloudflare API JSON responses |
| curl | Cloudflare API client (token auth, DNS/tunnel ops) |
| pandoc | Markdown -> HTML rendering (optional) |
| AppKit | macOS status bar + menus, file drop targets |

## Infrastructure

- **Config**: ~/.config/share/config (KV plaintext: hostname, port, mode, hosts)
- **State**: ~/share/index.tsv (tab-delimited: id, name, source, added, expiry, opts)
- **Serving**: local caddy on port 8787, tunnel metrics on 8788
- **Service**: launchd login agent foundation.d.share
- **Cloud**: Cloudflare (tunnel, DNS, edge caching)
- **Logs**: caddy access log in JSON (polled by app for hit counts)

## App interface: share status --json

Menu app reads state only via CLI; no file parsing. Schema v1 includes: schema, state (serving|stopped|not_setup), shares array with id, name, url, kind, source, added, expires fields.

CLI verbs: add, rm, refresh, hits, start, stop, setup (spawned from Swift).

## Build & deploy

| Task | Command |
|------|---------|
| Test (bash CLI) | bash tests/share.sh (local only, SHARE_TUNNEL=0) |
| Lint | shellcheck bin/share install.sh tests/*.sh demo/*.sh |
| Release | bin/release (semver from conventional commits; tags trigger GH release) |
| Homebrew | Formula at dwarvesf/homebrew-tools/Formula/share.rb (v0.4.0+); cask for app pending |
| macOS app build | mac/build.sh (sign + notarize; identity from env; TBD) |
| CI | GitHub Actions (ubuntu-latest + macos-latest); caddy 2.11.4 pre-installed |

## macOS app constraints

1. **Bash 3.2 compatibility**: CLI must run on /bin/bash; no empty arrays under set -u, no heredoc inside $( )
2. **AppKit-first** (not SwiftUI MenuBarExtra): needs menuNeedsUpdate for state refresh, per-share submenus, drag-drop
3. **Process lifecycle**: EXIT trap cannot read locals; background loops must redirect stdout; pkill -P before killing subshells
4. **Signing + notarization**: dwarvesf signing identity required (Developer ID + ASC key in 1Password)
5. **Bundle ID**: foundation.d.share.bar; launchd agent for login-item
6. **No file parsing**: app reads only through share status --json (schema versioning protects against drift)

## Release pipeline

- Conventional commits on main (feat/fix/docs)
- bin/release tags v-semver and pushes; .github/workflows/release.yml creates GH release
- Homebrew formula auto-bumped by release script
- App notarization: manual step in CI (TBD; identity env var + keychain)
