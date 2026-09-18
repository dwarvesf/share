# Setup, teardown, and troubleshooting

## 1. Create the Cloudflare API token

Setup talks to the Cloudflare API with a token you create once. In the Cloudflare dashboard, open **My Profile → API Tokens → Create Token → Create Custom Token**, then add:

| Scope | Resource | Permission | Why |
|---|---|---|---|
| Account | Cloudflare Tunnel | Edit | Create, configure, and delete the tunnel; read its run token. |
| Zone | DNS | Edit | Create and delete the CNAME for your hostname. |
| Zone | Zone | Read | Find which zone owns the hostname. |

Limit **Account Resources** to the account that holds your domain and **Zone Resources** to that domain. Setup and teardown use the token; `share add` and serving never do.

Pass it through the environment, or let setup prompt for it (the prompt does not echo):

```sh
CLOUDFLARE_API_TOKEN=... share setup s.example.com
```

## 2. What setup does

```
share setup s.example.com
   │
   ├─ 1 verify the API token
   ├─ 2 find the zone that owns s.example.com (tries s.example.com, then example.com)
   ├─ check the hostname: an existing record that is not this tunnel's CNAME stops setup here,
   │  before anything is created (override with --force)
   ├─ 3 reuse the tunnel named share-s-example-com, or create it (remotely managed)
   ├─ 4 route s.example.com -> http://127.0.0.1:8787, everything else -> 404
   ├─ 5 create the proxied CNAME s.example.com -> <tunnel-id>.cfargotunnel.com
   ├─ 6 fetch the tunnel run token and store it (Keychain on macOS, mode-600 file elsewhere)
   ├─ write ~/.config/share/config (hostname, tunnel, hosts=this machine, port)
   └─ live check: publish a probe file, fetch it over the public internet, remove it
```

| Created in Cloudflare | Name |
|---|---|
| Tunnel (remotely managed, config lives in Cloudflare) | `share-<hostname with dots as dashes>`, or `--tunnel-name` |
| Tunnel ingress rule | `<hostname>` → `http://127.0.0.1:<port>` |
| DNS record | proxied `CNAME <hostname>` → `<tunnel-id>.cfargotunnel.com`, comment `share tunnel <name>` |

| Created on this machine | Where |
|---|---|
| Tunnel run token | Keychain item `share-tunnel:<hostname>` (account `share`), or `~/.config/share/tunnel-token` |
| Config | `~/.config/share/config` |

The TLS certificate comes from Cloudflare's universal certificate for your zone. That certificate covers `*.example.com`, so the hostname does not appear in public certificate transparency logs.

Setup is idempotent. Run it again to repair a changed route, a deleted DNS record, or a lost token.

| Flag | Effect |
|---|---|
| `--tunnel-name NAME` | Reuse or create a tunnel with this name instead of the default. Use it to adopt a tunnel you created by hand. |
| `--force` | Replace an existing DNS record for the hostname. Without it, setup refuses and changes nothing. |

## 3. Keep the token in 1Password instead

Add a `token_cmd` line to `~/.config/share/config`. share runs it and uses its output as the tunnel token. It takes precedence over the Keychain and the token file.

```
token_cmd=op read "op://Private/share tunnel token/credential"
```

When `token_cmd` is set, setup does not store the token. Save the token in 1Password yourself (the dashboard shows it under the tunnel's install command), then rerun setup to verify.

## 4. Serve from a different machine

Only machines listed in `hosts` serve. Two machines on one tunnel would split requests between two different `~/share` folders, so links would fail at random.

To move serving to another machine: install share there, run `share setup <same hostname>` (it reuses the tunnel and stores the token locally), then run `share stop` on the old machine. Shares do not move with it; add them again on the new machine.

To let two machines take turns, list both in `hosts` and run `share start` on one at a time.

## 5. Teardown

```sh
CLOUDFLARE_API_TOKEN=... share teardown          # asks for confirmation
CLOUDFLARE_API_TOKEN=... share teardown --yes
```

Teardown stops the server, deletes the DNS record (only when it still points at this tunnel), deletes the tunnel, removes the stored token, and moves the config to the Trash. Shares in `~/share` stay on disk. To publish again, run setup.

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Cloudflare error 530 / 1033 | No connector is running: the machine sleeps, or `share` is stopped. | `share start` |
| 404 on a link | The share was removed or expired, or the link has a typo. | `share ls` |
| `setup`: "already has a … record" | The hostname is taken by another record. | Pick another hostname, or `--force` to replace it. |
| `setup`: "no Cloudflare zone" | The token cannot see the zone, or the domain is not on Cloudflare. | Check the token's Zone Resources. |
| `setup`: live check failed | DNS or the tunnel is not ready yet, or caddy failed to start. | Read `~/share/serve.log` and `~/share/caddy.log`, then rerun setup. |
| "not in hosts" | This machine is not allowed to serve. | Add its short name (`uname -n` up to the first dot) to `hosts`. |
| "no tunnel token" | The Keychain item or token file is missing. | Rerun `share setup <hostname>`. |
| "caddy failed to start" | Another process uses the port. | Free the port, or change `port` and rerun setup so the route follows. |
| Markdown served as raw text | pandoc is not installed. | `brew install pandoc`, then `share refresh <id>`. |
