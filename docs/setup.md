# Setup, service, teardown, and troubleshooting

## 1. Authorize: browser login or API token

`share setup <hostname>` picks the path by itself.

| Path | When | What you do |
|---|---|---|
| Browser login (default) | `CLOUDFLARE_API_TOKEN` is not set | Pick the domain in the browser tab and click **Authorize**. |
| API token | `CLOUDFLARE_API_TOKEN` is set (servers, CI, no browser) | Create the token once (below). |

`--login` forces the browser path even when the variable is set.

**Browser login** runs `cloudflared tunnel login`. Cloudflare returns a certificate (`cert.pem`) holding a token scoped to the domain you picked. share keeps it at `~/.config/share/cert.pem` (mode 600) for later setup and teardown runs. That token may manage tunnels but not DNS records, so share creates the DNS record through `cloudflared tunnel route dns`. It checks whether the hostname is already taken through public DNS (Cloudflare's resolver), before it creates anything.

**API token**: in the Cloudflare dashboard, open **My Profile → API Tokens → Create Token → Create Custom Token**, then add:

| Scope | Resource | Permission | Why |
|---|---|---|---|
| Account | Cloudflare Tunnel | Edit | Create, configure, and delete the tunnel; read its run token. |
| Zone | DNS | Edit | Create and delete the CNAME for your hostname. |
| Zone | Zone | Read | Find which zone owns the hostname. |

Limit **Account Resources** and **Zone Resources** to your domain. share uses the token for setup and teardown only and never stores it. It sends the token through a header file, so the token never appears in `ps` output.

```sh
CLOUDFLARE_API_TOKEN=... share setup s.example.com
```

## 2. What setup does

```
share setup s.example.com
   │
   ├─ find the zone that owns s.example.com, and authorize:
   │    browser path: public DNS finds the zone, then the login picks it
   │    API-token path: the token is checked, then the API finds the zone
   ├─ check the hostname: a record that is not this tunnel's stops setup here,
   │  before anything is created (override with --force)
   ├─ reuse the tunnel named share-s-example-com, or create it (remotely managed)
   ├─ route s.example.com -> http://127.0.0.1:8787, everything else -> 404
   ├─ create the proxied CNAME s.example.com -> <tunnel-id>.cfargotunnel.com
   ├─ fetch the tunnel run token and store it (Keychain on macOS, mode-600 file elsewhere)
   ├─ write ~/.config/share/config (hostname, tunnel, auth, hosts=this machine, port)
   ├─ install the login service (launchd or systemd), unless --no-service
   └─ live check: publish a probe file, fetch it over the public internet, remove it
```

| Created in Cloudflare | Name |
|---|---|
| Tunnel (remotely managed; its route lives in Cloudflare) | `share-<hostname with dots as dashes>`, or `--tunnel-name` |
| Tunnel route | `<hostname>` → `http://127.0.0.1:<port>` |
| DNS record | proxied `CNAME <hostname>` → `<tunnel-id>.cfargotunnel.com` |

| Created on this machine | Where |
|---|---|
| Tunnel run token | Keychain item `share-tunnel:<hostname>` (account `share`), or `~/.config/share/tunnel-token` |
| Login certificate (browser path only) | `~/.config/share/cert.pem` |
| Config | `~/.config/share/config` |
| Login service | `~/Library/LaunchAgents/foundation.d.share.plist`, or `~/.config/systemd/user/foundation.d.share.service` |

The TLS certificate comes from Cloudflare's universal certificate for your zone. That certificate covers `*.example.com`, so the hostname does not appear in public certificate transparency logs.

| Flag | Effect |
|---|---|
| `--tunnel-name NAME` | Reuse or create a tunnel with this name instead of the default. Use it to adopt a tunnel you created by hand. |
| `--force` | Replace an existing DNS record for the hostname. Without it, setup refuses and changes nothing. |
| `--no-service` | Skip the login service. Serve with `share start` instead. |
| `--login` | Use the browser path even when `CLOUDFLARE_API_TOKEN` is set. |

## 3. The login service

Setup installs a per-user service that runs `share serve`, so links come back by themselves after a restart or a login.

| | macOS | Linux |
|---|---|---|
| Kind | launchd agent `foundation.d.share` | systemd user unit `foundation.d.share.service` |
| Restarts | after a crash (30 s throttle) | after a failure (30 s) |
| Log | `~/share/serve.log` | the user journal: `journalctl --user -u foundation.d.share` |

`share stop` stops it until the next login; `share start` brings it back now. `share service uninstall` removes it, and `share service install` adds it again. On Linux, the service runs only while you are logged in unless you enable lingering (`loginctl enable-linger`).

## 4. Keep the tunnel token in 1Password

Add a `token_cmd` line to `~/.config/share/config`. share runs it and uses its output as the tunnel token. It takes precedence over the Keychain and the token file.

```
token_cmd=op read "op://Private/share tunnel token/credential"
```

When `token_cmd` is set, setup does not store the token. Save it in 1Password yourself (the dashboard shows it in the tunnel's install command), then rerun setup to verify.

## 4b. Own hostnames with `share add --host`

`share add <target> --host dev.example.com` publishes that share at `https://dev.example.com`. The name must be a single label under the zone the setup hostname belongs to (`dev.example.com` yes, `dev.s.example.com` no): Universal SSL stops at one level.

Each `--host` share creates one CNAME and one tunnel ingress rule; `share rm` deletes both. This needs a credential that can edit DNS records. The browser-login certificate cannot, so on that path the DNS write fails, share puts the ingress back, and the error says to export `CLOUDFLARE_API_TOKEN` or rerun `share setup` with the token. With `CLOUDFLARE_API_TOKEN` set, both live shares (`share add 3000 --host ...`) and snapshots (`share add ./dist --host ...`) work; a snapshot on its own hostname also serves deep links from `index.html`, which is what a SPA build needs.

## 4c. No domain: `share setup --quick`

```sh
share setup --quick
```

Quick mode uses Cloudflare's TryCloudflare tunnels: no domain, no login, no API token, no DNS. Setup writes only `mode=quick`, `hosts`, and `port` to the config; `share start` runs `cloudflared tunnel --url http://127.0.0.1:<port>` and reads the random `https://<x>.trycloudflare.com` URL out of the log. `share status` and every `share add` link use that hostname.

The trade-offs are real:

- **The URL changes on every start.** A link handed out dies at the next `share start`, restart, or reboot (the login service starts a new tunnel too). Quick mode is for "show someone this right now", not for links that must live.
- **No `--host` shares.** TryCloudflare cannot route a name you pick; `share add ... --host` refuses and points at named setup.
- **Switching modes is a teardown.** `share teardown --yes` (keeps `~/share`), then `share setup <hostname>` for a stable domain, or `--quick` to go back. Each refuses to overwrite the other's config.

## 4d. A second setup on the same machine: profiles

```sh
CLOUDFLARE_API_TOKEN=... share --profile work setup s.work.example   # another account or hostname
share --profile work add ./guide                                     # https://s.work.example/<id>/guide/
share add ./notes.pdf                                                # the default setup, unchanged
share profiles                                                       # default and work, each with state and host
```

A profile is a second, independent share: its own config dir (`~/.config/share/profiles/work`), root (`~/share/profiles/work`), login service (`foundation.d.share.work`), Keychain item (`share-tunnel.work:<hostname>`), and port (picked at the first setup, then kept in its config). `SHARE_PROFILE=work` selects it from the environment; the flag goes before the verb. The default setup never moves, so an existing install needs nothing. A named profile needs its own credential at setup: an API token for that account, or the browser login (each profile keeps its own `cert.pem`). `share --profile work teardown` removes only that profile. Share Bar shows the default profile only; to watch a named profile, watch its launchd label. Detail: [how-it-works.md](how-it-works.md#profiles).

## 4e. Private links: the API token for `--access`

`share add ... --access <rule>` puts a Cloudflare Access application on one link. It needs a named setup on an account with Zero Trust enabled (the free plan is enough), and an API token share reads only at command time, never from the login service.

| Scope (as the dashboard names it) | Needed for |
|---|---|
| Access: Apps and Policies: Edit | every `--access` create, read-back, delete |
| Access: Organizations, Identity Providers, and Groups: Read | the `group:` lookup, and the sweep's proof of Access read before it trusts an app list |
| Zone: Zone: Read | the zone to account lookup |
| Cloudflare Tunnel: Edit, DNS: Edit | only with `--host` (as today) |

Three ways to hand it over, first hit wins, per profile:

| Source | How |
|---|---|
| `api_token_cmd=<command>` in the profile's config | `share api-token --cmd 'op read "op://<vault>/<item>/credential"'`; share runs the command and uses its output. Any existing token with the scopes above works. |
| Keychain item `share-api[.<profile>]:<hostname>` (Linux: `<config dir>/api-token`, mode 600) | `share api-token` with no argument opens the prefilled token form (`https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=...&name=share access (<profile>)`), prompts for a hidden paste, and stores it through stdin. Over ssh or with no display it prints the URL instead of opening it. |
| `CLOUDFLARE_API_TOKEN` in the environment | used only when the profile stores nothing, so a broad shell token never silently replaces the profile's own |

Every form ends with a read-only preflight (`share api-token --check` reruns it): one line per scope, `ok` or `MISSING` with the scope's dashboard name, and a fix line with the token page. The Apps Edit check sends an invalid body (`{}`), which the API refuses with code 12130 without creating anything.

A rule group for `group:<name>`: Zero Trust > Access controls > Policies > Rule groups tab > Add a group; Name as you will pass it; Include > Selector: Emails > one entry per address; Save. share never creates or edits groups.

| Symptom | Cause | Fix |
|---|---|---|
| `--access needs a Cloudflare API token ... none is set` | no token source for this profile | the block names both `share api-token` forms and the form link |
| `MISSING  Access: ...` in the preflight | the token lacks that scope | add it on the token page the line names, then `share api-token --check` |
| `Cloudflare Access is not enabled on the account` | code 9999 | enable Zero Trust for the account in the dashboard |
| `no Access group named '<name>'` | no rule group of that exact name on the account that owns the zone | create it (above) and rerun the same add |
| `did not enforce on <host>/<id> within 900s; nothing was published` | the edge took longer than `SHARE_ACCESS_WAIT` | rerun the same add; a new app can take several minutes |
| `<n> Access app(s) await deletion` in `ls` or `status` | gated shares expired under the login service or a `status` run, neither of which consults a token | `share prune` (the stored token is used; none stored: `share api-token` first, or export `CLOUDFLARE_API_TOKEN`) |
| `skipping the Access check` on `ls` | the exported `CLOUDFLARE_API_TOKEN` belongs to another account or zone | unset it, or store the right token with `share api-token` |
| `Access app for <id> is gone; the link is PUBLIC` (`ls` with `CLOUDFLARE_API_TOKEN` exported) | the app was deleted in the dashboard | `share rm <id>` |

## 5. Serve from a different machine

Only machines listed in `hosts` serve. Two machines on one tunnel would split requests between two different `~/share` folders, so links would fail at random.

To move serving: install share on the new machine, run `share setup <same hostname>` there (it reuses the tunnel and stores the token locally), then run `share service uninstall` on the old machine. Shares do not move with it; add them again on the new machine.

## 6. Teardown

```sh
share teardown          # asks for confirmation
share teardown --yes
```

Teardown removes the service, stops serving, deletes the tunnel, removes the stored tokens (tunnel and API) and the login certificate, and moves the config to the Trash. Shares in `~/share` stay on disk, except gated ones (`--access`): those are unpublished first, with their Access apps deleted, and teardown refuses without an API token while any exists, so a later setup never serves them ungated.

The DNS record depends on the path. With `CLOUDFLARE_API_TOKEN` set, teardown deletes it (only when it still points at this tunnel). The browser-login token cannot delete DNS records, so teardown tells you to remove the CNAME in the dashboard. Until you do, the hostname returns a Cloudflare error.

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Cloudflare error 530 / 1033 | Nothing is serving: the machine sleeps, or share is stopped. | `share start` |
| 404 on the site root | Expected: the root has no page, even while serving. | `curl https://<hostname>/healthz`: `ok` means serving, 530 means not. |
| 404 on a link | The share was removed or expired, or the link has a typo. | `share ls` |
| `setup`: "already has a … record" / "already resolves" | The hostname is taken. | Pick another hostname, or `--force` to replace it. |
| `setup`: "DNS route failed (did you pick … in the browser?)" | The browser login picked a different domain. | Rerun setup and pick the domain it names. |
| `setup`: "no Cloudflare zone" / "cannot find the DNS zone" | The domain is not on Cloudflare, or the API token cannot see it. | Check the domain's nameservers, or the token's Zone Resources. |
| `setup`: live check failed | DNS or the tunnel is not ready yet, or caddy failed to start. | Read `~/share/serve.log` and `~/share/caddy.log`, then rerun setup. |
| "not in hosts" | This machine is not allowed to serve. | Add its short name (`uname -n` up to the first dot) to `hosts`. |
| "no tunnel token" | The Keychain item or token file is missing. | Rerun `share setup <hostname>`. |
| "caddy failed to start" | Another process uses the port. | Free the port, or change `port` and rerun setup so the route follows. |
| "127.0.0.1:<port> is already in use" | Another share profile, or another process, listens on this profile's port or metrics port. | `share profiles` to find it; change `port=` in the config it names and rerun setup so the route follows. |
| Markdown served as raw text | pandoc is not installed. | `brew install pandoc`, then `share refresh <id>`. |
