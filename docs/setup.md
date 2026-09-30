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

## 4f. R2 backend: admin setup

An r2 profile serves snapshots from a private R2 bucket through a Worker on your hostname, so links answer while every publisher's machine is off. One person, the admin, sets up the hostname once with an account-level token. Everyone else joins with a token scoped to the bucket (section 4g).

The admin token is read from `CLOUDFLARE_API_TOKEN` only, never from a stored token, and share never stores it. Create it at **My Profile → API Tokens → Create Token → Create Custom Token**:

| Scope | Resource | Permission | Why |
|---|---|---|---|
| Account | Workers Scripts | Edit | Deploy the Worker, turn off its `workers.dev` route, attach the custom domain, read the deployed version. |
| Account | Workers R2 Storage | Edit | Create the bucket, read its public-route settings, write `share.json`. |
| Zone | Zone | Read | Find the zone and account that own the hostname. |
| Zone | DNS | Read | Refuse a hostname whose DNS record is not this Worker's custom domain. |
| Account | Access: Organizations, Identity Providers, and Groups | Read | Optional: sets the Worker's Access team. Without it at the first setup, `add --access` is refused on this profile; a later rerun without it keeps the team already deployed. `teardown --purge` also needs it for its pass over Access apps by name. |
| Account | Access: Apps and Policies | Edit | Only for `teardown --purge` while gated shares exist. |

DNS: Edit and Workers Routes: Edit are not needed: attaching a Worker custom domain creates its DNS record.

```sh
CLOUDFLARE_API_TOKEN=... share --profile df setup f.example.com --backend r2 --bucket share-f
```

```
share --profile df setup f.example.com --backend r2 --bucket share-f
   │
   ├─ reads only; every refusal happens here, so a refused run creates nothing:
   │    the zone and account that own f.example.com, and the token's own id
   │    Worker share-f-example-com: absent or share's own -> "deploying as admin";
   │      401 or 403 -> "joining as publisher" (section 4g)
   │      bindings for another hostname or bucket: refused
   │      a deployed version newer than this share: refused unless --force
   │    bucket: public r2.dev URL on, or a custom domain: refused
   │      objects but no share.json: refused; share.json naming another hostname: refused
   │    DNS: a record that is not this Worker's custom domain: refused unless --force
   │      the custom domain of another Worker: refused, even with --force
   │    Access organization: its team domain becomes the Worker's Access team (optional)
   ├─ create the bucket if absent; write share.json {"v":1,"host":"f.example.com"}
   ├─ deploy the Worker when absent, or when its version, source hash, or Access team differs
   ├─ turn off workers.dev and previews, then read it back: anything but false,false dies
   │  before the custom domain exists, so nothing is exposed
   ├─ attach f.example.com as the Worker's custom domain
   ├─ wait for https://f.example.com/healthz: "200 ok" with this share's Worker version,
   │  three times in a row, up to SHARE_R2_WAIT (300 s; a new name waits for its certificate)
   └─ write the profile config: backend, hostname, zone, bucket, port=r2, r2_endpoint
```

| Created in Cloudflare | Name |
|---|---|
| R2 bucket (private: no r2.dev URL, no custom domain) | `--bucket`: 3 to 63 characters of `a-z 0-9 -`, no leading or trailing `-` |
| Bucket marker | object `share.json`, naming the hostname |
| Worker | `share-<hostname with dots as dashes>`, `workers.dev` and previews off |
| Worker custom domain | `<hostname>` |
| Analytics Engine dataset | `share_<hostname with dots and dashes as underscores>`, filled by the Worker for `share hits` |

On this machine setup writes only the config. There is no tunnel, no login service, and no Keychain tunnel item. `port=r2` in the config is a sentinel: a share release older than the r2 backend dies at load on it, so it can never write to an r2 profile.

`--backend r2` refuses `--quick`, `--tunnel-name`, `--login`, and `--no-service` (`usage: share setup <hostname> --backend r2 --bucket <name> [--force]`). A profile has one backend; to switch, run `share teardown` first. `--force` replaces an existing DNS record at the hostname, or downgrades a Worker that a newer share deployed.

Rerun the same command after a share release that changes the Worker. Publishers see a line when the deployed Worker differs from their share, in `setup` and `status`: `the Worker at <host> runs <v> <sha>; this share ships <v> <sha>; whoever holds the admin token reruns '...'`. A rerun is safe: it redeploys only when the version, source hash, or Access team differs, and prints `already deployed` otherwise.

To publish yourself, store a publisher token as a teammate does (section 4g, steps 1 and 3). `share api-token` refuses the admin token.

For an external monitor (vps-mon or any uptime checker), watch `https://<hostname>/healthz`: it answers `200 ok` with an `X-Share-Worker: <version> <sha>` header while the Worker serves. `share status` prints the same probe (`worker: up (...)` or `worker: DOWN: <code>`) and `gated: on` or `gated: off`.

## 4g. R2 backend: a teammate joins

Every publisher gets their own token, scoped to the share bucket, with an expiry. Never hand out an account-wide R2 token: it reaches every bucket on the account. `share api-token` refuses one.

1. **The admin creates the teammate's token** in the Cloudflare dashboard as a custom API token, with an expiry (TTL):

   | Permission | Resource | Needed for |
   |---|---|---|
   | Workers R2 Storage Bucket Item Write | the share bucket only | every `add`, `ls`, `rm`, `refresh`, `prune` (read, write, list, and delete objects) |
   | Zone: Read | the hostname's zone | joining: setup finds the account through the zone |
   | Account Analytics: Read | the account | optional: `share hits`. It reads every Analytics Engine dataset on the account. |
   | Access: Apps and Policies: Edit; Access: Organizations, Identity Providers, and Groups: Read | the account | only for a named gated publisher: `add --access` and removing gated shares. Apps and Policies Edit is account-wide, so give it to few people. |

   One token per teammate: revoking a leaver is deleting their token, and nobody else is affected.

2. **The teammate joins** with that token in the environment:

   ```sh
   CLOUDFLARE_API_TOKEN=<their token> share --profile df setup f.example.com --backend r2 --bucket share-f
   ```

   Setup prints `joining as publisher`. A publisher token cannot read the bucket's public-route settings, so it also prints `public-route check skipped (publisher token)`; the admin's setup runs that check. Join checks that the bucket holds `share.json` for this hostname (none: run the admin setup first) and waits for three `200 ok` answers from `/healthz`. It accepts any Worker version and prints the mismatch line when it differs. It writes nothing on Cloudflare and does not store the token; it writes only the local config.

3. **The teammate stores the token**, once per profile:

   ```sh
   share --profile df api-token --cmd 'op read "op://<vault>/<item>/credential"'   # share runs the command on every use
   op read "op://<vault>/<item>/credential" | share --profile df api-token          # or store it once, from stdin
   ```

   `share --profile df api-token` with no argument in a terminal also works: it prints and opens a prefilled user-token form named `share publisher (<profile>)`, with Zone: Read and the profile's account, then reads the token at a hidden prompt. A Cloudflare template link cannot preset a bucket-scoped permission, so in the form add Workers R2 Storage Bucket Item Write with the share bucket as its only resource, and set an expiry. A teammate who also needs Access scopes adds them in the same form (section 4e lists them).

   Before storing, share refuses two kinds of token and stores nothing:

   | Refusal | Cause |
   |---|---|
   | `that token can edit Worker share-...: it is an admin token` | the token reads the Worker's settings |
   | `that token reaches other buckets (...): an account-wide R2 token` | the token lists a bucket besides the share bucket |

   On success it prints `a publisher token for bucket <bucket>: not an admin token, no other bucket in reach`, then the Access preflight lines for information. A bucket-only token shows the Access scopes as `MISSING` and still exits 0: ungated adds work. `share --profile df api-token --check` reruns the same checks.

4. **Publish**: `share --profile df add ./report.pdf`. `share --profile df ls` shows every publisher's shares, each with `by=<machine>`.

The token lives where `share api-token` puts it for any profile: `api_token_cmd` in the config, else the Keychain item `share-api.<profile>:<hostname>` (Linux: `<config dir>/api-token`, mode 600), else `CLOUDFLARE_API_TOKEN`. share derives the R2 access key from it (the key id is the token's id, the secret its SHA-256) and never writes either.

When a teammate leaves, delete their token in the dashboard. Their shares keep serving until they expire or someone runs `share rm <id>`; any publisher can remove any share. Only the install that added a share can `refresh` it, so a leaver's shares can be removed and added again, not refreshed.

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

On an r2 profile, teardown has two forms:

```sh
share --profile df teardown [--yes]                                   # this install only
CLOUDFLARE_API_TOKEN=<admin token> share --profile df teardown --yes --purge   # everything, for everyone
```

| | `teardown` | `teardown --yes --purge` |
|---|---|---|
| Stored API token, `r2-own`, config | removed (config and `r2-own` to the Trash) | removed |
| Every share on the hostname | stays for the other publishers | deleted, gated ones first with their Access apps |
| Worker, custom domain, `share.json` | stay | deleted |
| Bucket | stays | deleted when empty; otherwise kept, with the count of keys share did not write |
| Analytics Engine dataset | stays | stays: it cannot be deleted and ages out |

`--purge` reads the admin token from `CLOUDFLARE_API_TOKEN` only. Before the first delete it checks that the Worker's bindings name this hostname and bucket (a publisher token gets 403 there and is refused), that `share.json` names this hostname, that no other Worker holds the hostname, and, when any gated share or waiting Access app exists, that the token has Access: Apps and Policies Edit. Any failed check changes nothing. After the shares it deletes every Access app named for this hostname, which catches apps parked in teammates' local `access-pending` files (it skips that pass with a line when the token cannot read Access apps), then every leftover `m/` and `o/` key, including records no share release could read. The local form prints how many Access apps stay in this install's `access-pending`.

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

R2 backend:

| Symptom | Cause | Fix |
|---|---|---|
| `setup --backend r2 reads its token from CLOUDFLARE_API_TOKEN only; none is set` | No token in the environment. | Export the admin token (4f) or the teammate's token (4g); the message lists both scope sets. |
| `setup`: `bucket <b> has no share.json` / `does not exist; whoever holds the admin token runs ...` | A teammate joined before the admin setup ran. | The admin runs setup first. |
| `setup`: `did not answer 200 ok three times in a row within 300s` | A new hostname waits for its certificate, or the Worker is down. | Rerun setup; raise `SHARE_R2_WAIT` for a slow certificate. The config is written only after this check. |
| `that token can edit Worker ...: it is an admin token` | `api-token` got the admin token. | Store a bucket-scoped token (4g, step 1). |
| `that token reaches other buckets (...): an account-wide R2 token` | The token is not limited to the share bucket. | Create a token with Workers R2 Storage Bucket Item Write on the share bucket only. |
| `this r2 profile needs a publisher token for <host>; none resolved` | No token stored for this profile. | `share --profile <p> api-token` (4g, step 3). |
| `live shares and --host need a tunnel profile; this profile serves from R2` | `add <port>` or `--host` on an r2 profile. | Use a tunnel profile for those; both kinds run side by side. |
| `an r2 profile serves from Cloudflare; nothing runs on this machine` | `start`, `stop`, `serve`, or `service` on an r2 profile. | Nothing to run. `share rm <id>` unpublishes a link. |
| `<id> was added from another install; refresh it there` | `refresh` of a teammate's share. | Refresh from that install, or `rm` and add again. |
| `the Worker at <host> has no Access team, so a gated link would never open` | The admin token lacked Access: Organizations Read at setup (`status` shows `gated: off`). | The admin reruns setup with that scope. |
| `the Worker at <host> runs <v> <sha>; this share ships <v> <sha>` | The Worker and your share are different releases. | The admin reruns setup with the newer share. |
| `expired gated share <id> waits for a publisher with the Access token` | `ls` or `prune` without Access: Apps and Policies Edit. The Worker already answers 404 for it. | A gated publisher runs `share prune`. |
| `orphan sweep skipped: m/<id> is unreadable or newer than this share` (`status`: `orphan sweep blocked by m/<id>`) | A record this share cannot read: a newer release wrote it, or it is corrupt. | Upgrade share. A corrupt record goes only through `teardown --purge` or a delete in the dashboard. |
| `hits needs an API token with Account Analytics: Read` / `the Analytics Engine query answered HTTP 403` | The stored token lacks the optional analytics scope. | Add Account Analytics: Read to the token. |
