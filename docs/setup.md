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
   ├─ authorize (browser login, or the API token)
   ├─ find the zone that owns s.example.com
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
| Log | `~/share/serve.log` | `~/share/serve.log` |

`share stop` stops it until the next login; `share start` brings it back now. `share service uninstall` removes it, and `share service install` adds it again. On Linux, the service runs only while you are logged in unless you enable lingering (`loginctl enable-linger`).

## 4. Keep the tunnel token in 1Password

Add a `token_cmd` line to `~/.config/share/config`. share runs it and uses its output as the tunnel token. It takes precedence over the Keychain and the token file.

```
token_cmd=op read "op://Private/share tunnel token/credential"
```

When `token_cmd` is set, setup does not store the token. Save it in 1Password yourself (the dashboard shows it in the tunnel's install command), then rerun setup to verify.

## 5. Serve from a different machine

Only machines listed in `hosts` serve. Two machines on one tunnel would split requests between two different `~/share` folders, so links would fail at random.

To move serving: install share on the new machine, run `share setup <same hostname>` there (it reuses the tunnel and stores the token locally), then run `share service uninstall` on the old machine. Shares do not move with it; add them again on the new machine.

## 6. Teardown

```sh
share teardown          # asks for confirmation
share teardown --yes
```

Teardown removes the service, stops serving, deletes the tunnel, removes the stored token and the login certificate, and moves the config to the Trash. Shares in `~/share` stay on disk.

The DNS record depends on the path. With `CLOUDFLARE_API_TOKEN` set, teardown deletes it (only when it still points at this tunnel). The browser-login token cannot delete DNS records, so teardown tells you to remove the CNAME in the dashboard. Until you do, the hostname returns a Cloudflare error.

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Cloudflare error 530 / 1033 | Nothing is serving: the machine sleeps, or share is stopped. | `share start` |
| 404 on a link | The share was removed or expired, or the link has a typo. | `share ls` |
| `setup`: "already has a … record" / "already resolves" | The hostname is taken. | Pick another hostname, or `--force` to replace it. |
| `setup`: "DNS route failed (did you pick … in the browser?)" | The browser login picked a different domain. | Rerun setup and pick the domain it names. |
| `setup`: "no Cloudflare zone" / "cannot find the DNS zone" | The domain is not on Cloudflare, or the API token cannot see it. | Check the domain's nameservers, or the token's Zone Resources. |
| `setup`: live check failed | DNS or the tunnel is not ready yet, or caddy failed to start. | Read `~/share/serve.log` and `~/share/caddy.log`, then rerun setup. |
| "not in hosts" | This machine is not allowed to serve. | Add its short name (`uname -n` up to the first dot) to `hosts`. |
| "no tunnel token" | The Keychain item or token file is missing. | Rerun `share setup <hostname>`. |
| "caddy failed to start" | Another process uses the port. | Free the port, or change `port` and rerun setup so the route follows. |
| Markdown served as raw text | pandoc is not installed. | `brew install pandoc`, then `share refresh <id>`. |
